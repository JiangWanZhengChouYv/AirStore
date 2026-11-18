// AirStore's own copy of the develop feed, on a domain we control.
//
// The app used to read the feed and its assets from raw.githubusercontent.com, with jsDelivr and two
// public GitHub proxies as fallbacks. Those hosts are blocked or crawling on a lot of the networks the
// app is used on, and jsDelivr served a two-build-old feed even after a purge that answered
// "finished". This Worker is the first route instead: it fetches from GitHub at request time and
// answers with no-store, so whatever it returns is what the repository holds right now.
//
// Routes:
//   /source/airstore-source.json   the develop feed (the path the app already recognises as ours)
//   /airstore-source.json          alias for manual checks
//   /gh/OWNER/REPO@REF/PATH...     a file on a branch, e.g. the feed's icons and screenshots
//   /raw/OWNER/REPO/REF/PATH...    the same with slash-separated parts
//   /dl/OWNER/REPO/TAG/FILE        a release asset, streamed (the IPA is ~30 MB)
//   /health                        what this deployment is serving
//
// Only JiangWanZhengChouYv/AirStore is proxied. An open proxy would be abused within a day, and the
// app never asks this host for anything else.

const OWNER = "JiangWanZhengChouYv";
const REPO = "AirStore";
const BRANCH = "develop-source";
const FEED_URL = `https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}/source/airstore-source.json`;

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, HEAD, OPTIONS",
  "access-control-allow-headers": "*",
};

// Nothing here may be cached: the whole point of moving off jsDelivr is that a build published a
// minute ago is visible a minute later.
const NO_CACHE = {
  "cache-control": "no-store, max-age=0",
  "cdn-cache-control": "no-store",
  "cloudflare-cdn-cache-control": "no-store",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...CORS, ...NO_CACHE },
  });
}

function isOurs(owner, repo) {
  return owner.toLowerCase() === OWNER.toLowerCase() && repo.toLowerCase() === REPO.toLowerCase();
}

async function mirror(request, upstream, fallbackType) {
  // Forward Range: the app resumes interrupted downloads, and a 30 MB IPA that restarts from zero
  // every time is the difference between a retry and a failure. Everything else is our own.
  const upstreamHeaders = new Headers();
  const range = request.headers.get("range");
  if (range) upstreamHeaders.set("range", range);
  upstreamHeaders.set("user-agent", "AirStore-feed-worker");

  const response = await fetch(upstream, {
    method: request.method,
    redirect: "follow",
    headers: upstreamHeaders,
    cf: { cacheEverything: false, cacheTtl: 0 },
  });

  const headers = new Headers(response.headers);
  headers.delete("cache-control");
  headers.delete("expires");
  headers.delete("etag");
  headers.delete("last-modified");
  headers.delete("content-encoding");
  headers.delete("content-length");
  headers.delete("cdn-cache-control");
  headers.delete("cloudflare-cdn-cache-control");
  for (const [key, value] of Object.entries(CORS)) headers.set(key, value);
  for (const [key, value] of Object.entries(NO_CACHE)) headers.set(key, value);
  headers.set("x-airstore-mirror", "1");

  if (!headers.has("content-type") && fallbackType) headers.set("content-type", fallbackType);

  return new Response(request.method === "HEAD" ? null : response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export default {
  async fetch(request) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: { ...CORS, ...NO_CACHE } });
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return json({ error: "method not allowed" }, 405);
    }

    const url = new URL(request.url);
    const path = decodeURIComponent(url.pathname);

    if (path === "/" || path === "") {
      return json({
        name: "AirStore feed mirror",
        feed: `${url.origin}/source/airstore-source.json`,
        upstream: FEED_URL,
        cache: "none",
      });
    }

    if (path === "/health") {
      return json({ ok: true, upstream: FEED_URL, time: new Date().toISOString() });
    }

    if (path === "/source/airstore-source.json" || path === "/airstore-source.json") {
      return mirror(request, FEED_URL, "application/json; charset=utf-8");
    }

    // /gh/OWNER/REPO@REF/PATH... -- the shape jsDelivr used, so a jsDelivr URL can be rewritten by
    // swapping the host and keeping everything after it.
    const gh = path.match(/^\/gh\/([^/]+)\/([^/@]+)@([^/]+)\/(.+)$/);
    if (gh) {
      const [, owner, repo, ref, rest] = gh;
      if (!isOurs(owner, repo)) return json({ error: "repository not mirrored" }, 403);
      return mirror(request, `https://raw.githubusercontent.com/${owner}/${repo}/${ref}/${rest}`);
    }

    const raw = path.match(/^\/raw\/([^/]+)\/([^/]+)\/([^/]+)\/(.+)$/);
    if (raw) {
      const [, owner, repo, ref, rest] = raw;
      if (!isOurs(owner, repo)) return json({ error: "repository not mirrored" }, 403);
      return mirror(request, `https://raw.githubusercontent.com/${owner}/${repo}/${ref}/${rest}`);
    }

    const dl = path.match(/^\/dl\/([^/]+)\/([^/]+)\/([^/]+)\/(.+)$/);
    if (dl) {
      const [, owner, repo, tag, file] = dl;
      if (!isOurs(owner, repo)) return json({ error: "repository not mirrored" }, 403);
      return mirror(request, `https://github.com/${owner}/${repo}/releases/download/${tag}/${file}`);
    }

    return json(
      {
        error: "not found",
        paths: [
          "/source/airstore-source.json",
          "/gh/{owner}/{repo}@{ref}/{path}",
          "/raw/{owner}/{repo}/{ref}/{path}",
          "/dl/{owner}/{repo}/{tag}/{file}",
          "/health",
        ],
      },
      404,
    );
  },
};
