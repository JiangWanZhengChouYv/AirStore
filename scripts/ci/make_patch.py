#!/usr/bin/env python3
"""Build and apply AirStore's delta patch ("ASDP2"): a copy/insert instruction stream.

Why this shape. A fixed-block delta was written and measured first, against two real packages: 1838 of
1838 blocks differed, so the patch came out at 99.82% of the full ipa. An .ipa is a zip, and when the
main executable grows by a few kilobytes everything after it shifts -- block matching is blind to
shifts. "Copy N bytes from offset X of the base you already have" is not, so a shifted region costs one
instruction instead of the whole file.

Why not bsdiff: it needs bzip2, which would mean a third-party C library vendored into a target whose
dependencies are local Swift packages. The matcher here is about 60 lines, and the device never
searches -- it only applies instructions.

Why no new feed or CoreData field: an AppVersion attribute would need a new model version plus a
migration policy, the most dangerous path in this repository. The patch is instead self-describing and
published under a fixed asset name beside the ipa, so the client needs nothing it does not already get.

Safety does not depend on the matcher being right. The header carries the SHA-256 of both sides; the
client checks its base first and recomputes the whole-file SHA-256 after rebuilding, and either
mismatch falls back to the full download rather than installing a bad ipa.

    make_patch.py create --base old.ipa --target new.ipa --out AirStore.patch
    make_patch.py apply  --base old.ipa --patch AirStore.patch --out rebuilt.ipa
    make_patch.py info   --patch AirStore.patch
"""
import argparse
import hashlib
import json
import os
import struct
import zlib

MAGIC = b"ASDP"
VERSION = 2
# bodyLen is the deflated size; rawBodyLen is what the device needs to size its decode buffer, because
# compression_decode_buffer() will not grow one on its own.
HEADER = struct.Struct("<4sB32s32sQQQ")   # magic version baseSHA targetSHA targetLen deflatedLen rawBodyLen
OP_COPY, OP_INSERT = 0, 1

ASBU_MAGIC = b"ASBU"
ASBU_VERSION = 1
ENTRY = struct.Struct("<BHHQ")

MIN_MATCH = 24        # shorter matches cost more in instructions than in literals
FINGERPRINT = 16      # bytes of the base indexed for lookup
CANDIDATES = 4        # offsets tried per fingerprint
CHUNK = 1 << 16       # comparison granularity while extending a match


def sha256(data):
    return hashlib.sha256(data).digest()


def index_base(base, stride):
    index = {}
    for i in range(0, max(0, len(base) - FINGERPRINT + 1), stride):
        index.setdefault(base[i:i + FINGERPRINT], []).append(i)
    return index


def extend(base, target, j, i, limit):
    """Length of the identical run starting at base[j] and target[i]."""
    matched = 0
    while matched < limit:
        step = min(CHUNK, limit - matched)
        a = base[j + matched:j + matched + step]
        b = target[i + matched:i + matched + step]
        if a != b:
            for k in range(len(a)):
                if a[k] != b[k]:
                    return matched + k
        matched += step
    return matched


def match(target, base, index):
    """One pass over the target: (op, a, b) records plus the literal bytes they insert."""
    records = []
    pending = bytearray()   # the literal run being accumulated
    blob = bytearray()      # every literal byte, in instruction order, handed to serialize()
    i, n = 0, len(target)

    def flush():
        if pending:
            records.append((OP_INSERT, len(pending), 0))
            blob.extend(pending)   # += would rebind blob as a local of flush()
            pending.clear()

    while i < n:
        key = target[i:i + FINGERPRINT]
        candidates = index.get(key) if len(key) == FINGERPRINT else None
        best_run, best_from = 0, 0
        if candidates:
            limit = n - i
            for j in candidates[-CANDIDATES:]:
                run = extend(base, target, j, i, limit)
                if run > best_run:
                    best_run, best_from = run, j
        if best_run >= MIN_MATCH:
            flush()
            records.append((OP_COPY, best_from, best_run))
            i += best_run
        else:
            pending += target[i:i + 1]
            i += 1
    flush()
    return records, bytes(blob)


def serialize(records, literals, base_sha, target_sha, target_len):
    table = bytearray(struct.pack("<Q", len(records)))
    for op, a, b in records:
        table += struct.pack("<BQQ", op, a, b) if op == OP_COPY else struct.pack("<BQ", op, a)
    body = bytes(table) + literals
    compressor = zlib.compressobj(6, zlib.DEFLATED, -15)      # raw deflate == COMPRESSION_ZLIB
    deflated = compressor.compress(body) + compressor.flush(zlib.Z_FINISH)
    header = HEADER.pack(MAGIC, VERSION, base_sha, target_sha, target_len, len(deflated), len(body))
    return header + deflated, body


def parse(data):
    magic, version, base_sha, target_sha, target_len, deflated_len, raw_len = HEADER.unpack_from(data, 0)
    if magic != MAGIC or version != VERSION:
        raise SystemExit(f"unsupported patch format {magic!r} version {version}")
    start = HEADER.size
    if len(data) < start + deflated_len:
        raise SystemExit("patch is truncated")
    body = zlib.decompressobj(-15).decompress(data[start:start + deflated_len], raw_len)
    if len(body) != raw_len:
        raise SystemExit(f"patch body decompressed to {len(body)}, expected {raw_len}")
    count = struct.unpack_from("<Q", body, 0)[0]
    off = 8
    records = []
    for _ in range(count):
        op = body[off]
        off += 1
        if op == OP_COPY:
            a, b = struct.unpack_from("<QQ", body, off)
            off += 16
            records.append((OP_COPY, a, b))
        elif op == OP_INSERT:
            (a,) = struct.unpack_from("<Q", body, off)
            off += 8
            records.append((OP_INSERT, a, 0))
        else:
            raise SystemExit(f"bad instruction opcode {op}")
    return base_sha, target_sha, target_len, records, body[off:]


def pack_bundle(app_dir):
    """ASBU -- a deterministic serialization of an .app bundle, so the delta can be computed over
    bundle bytes that the device can reproduce from what it already installed. No timestamps, no zip
    metadata, fixed ordering: the only thing that may differ between two packs is content.

    magic(4) version(1) entryCount(u64), then per entry sorted by relative path bytes:
    flags u8 (0 dir / 1 file / 2 symlink) pathLen u16 path mode u16 contentLen u64 [content]
    """
    root = app_dir.rstrip("/")
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        for name in list(dirnames) + filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).encode()
            if os.path.islink(full):
                entries.append((2, rel, os.stat(full, follow_symlinks=False).st_mode & 0o7777,
                                os.readlink(full).encode()))
            elif os.path.isdir(full):
                entries.append((0, rel, os.stat(full).st_mode & 0o7777, b""))
            else:
                entries.append((1, rel, os.stat(full).st_mode & 0o7777, open(full, "rb").read()))
    entries.sort(key=lambda e: e[1])
    out = bytearray(struct.pack("<4sBQ", ASBU_MAGIC, ASBU_VERSION, len(entries)))
    for flags, rel, mode, content in entries:
        out += ENTRY.pack(flags, len(rel), mode, len(content))
        out += rel + content
    return bytes(out)


def unpack_bundle(stream, out_dir):
    magic, version, count = struct.unpack_from("<4sBQ", stream, 0)
    if magic != ASBU_MAGIC or version != ASBU_VERSION:
        raise SystemExit(f"not an ASBU stream ({magic!r} v{version})")
    os.makedirs(out_dir, exist_ok=True)
    off = struct.calcsize("<4sBQ")
    for _ in range(count):
        flags, path_len, mode, content_len = struct.unpack_from("<BHHQ", stream, off)
        off += ENTRY.size
        rel = stream[off:off + path_len].decode()
        off += path_len
        content = stream[off:off + content_len]
        off += content_len
        full = os.path.join(out_dir, rel)
        if flags == 0:
            os.makedirs(full, exist_ok=True)
        elif flags == 2:
            os.makedirs(os.path.dirname(full), exist_ok=True)
            os.symlink(content.decode(), full)
        else:
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as fh:
                fh.write(content)
            os.chmod(full, mode)
    return count


def cmd_pack(args):
    stream = pack_bundle(args.app)
    with open(args.out, "wb") as fh:
        fh.write(stream)
    print(json.dumps({"app": args.app, "asbuBytes": len(stream), "asbuSHA256": sha256(stream).hex()}, indent=2))


def cmd_unpack(args):
    count = unpack_bundle(open(args.infile, "rb").read(), args.out)
    print(f"unpacked {count} entries -> {args.out}")


def cmd_create(args):
    base = open(args.base, "rb").read()
    target = open(args.target, "rb").read()
    stride = max(FINGERPRINT, len(base) // 400_000)
    records, literals = match(target, base, index_base(base, stride))
    blob, body = serialize(records, literals, sha256(base), sha256(target), len(target))
    with open(args.out, "wb") as fh:
        fh.write(blob)
    print(json.dumps({
        "baseBytes": len(base), "targetBytes": len(target),
        "baseSHA256": sha256(base).hex(), "targetSHA256": sha256(target).hex(),
        "instructions": len(records),
        "copiedFromBase": sum(r[2] for r in records if r[0] == OP_COPY),
        "insertedLiterals": len(literals),
        "uncompressedBodyBytes": len(body), "patchBytes": len(blob),
        "percentOfFull": round(100.0 * len(blob) / max(1, len(target)), 2),
    }, indent=2))


def cmd_apply(args):
    base_sha, target_sha, target_len, records, literals = parse(open(args.patch, "rb").read())
    base = open(args.base, "rb").read()
    if sha256(base) != base_sha:
        raise SystemExit("base file does not match the patch's baseSHA256 -- use the full download")
    out = bytearray()
    lit = 0
    for op, a, b in records:
        if op == OP_COPY:
            if a + b > len(base):
                raise SystemExit("patch asks for bytes the base does not have")
            out += base[a:a + b]
        else:
            out += literals[lit:lit + a]
            lit += a
    if len(out) != target_len or sha256(bytes(out)) != target_sha:
        raise SystemExit("reassembled file does not match the patch's targetSHA256")
    with open(args.out, "wb") as fh:
        fh.write(out)
    print(f"applied -> {args.out} ({len(out):,} bytes, SHA-256 verified)")


def cmd_info(args):
    base_sha, target_sha, target_len, records, literals = parse(open(args.patch, "rb").read())
    print(json.dumps({
        "format": MAGIC.decode() + str(VERSION), "baseSHA256": base_sha.hex(),
        "targetSHA256": target_sha.hex(), "targetBytes": target_len,
        "instructions": len(records), "copies": sum(1 for r in records if r[0] == OP_COPY),
        "inserts": sum(1 for r in records if r[0] == OP_INSERT),
        "insertedLiterals": len(literals), "patchBytes": os.path.getsize(args.patch),
    }, indent=2))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("--base", required=True)
    c.add_argument("--target", required=True)
    c.add_argument("--out", required=True)
    c.set_defaults(fn=cmd_create)
    a = sub.add_parser("apply")
    a.add_argument("--base", required=True)
    a.add_argument("--patch", required=True)
    a.add_argument("--out", required=True)
    a.set_defaults(fn=cmd_apply)
    i = sub.add_parser("info")
    i.add_argument("--patch", required=True)
    i.set_defaults(fn=cmd_info)
    pk = sub.add_parser("pack")
    pk.add_argument("--app", required=True)
    pk.add_argument("--out", required=True)
    pk.set_defaults(fn=cmd_pack)
    uk = sub.add_parser("unpack")
    uk.add_argument("--in", dest="infile", required=True)
    uk.add_argument("--out", required=True)
    uk.set_defaults(fn=cmd_unpack)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
