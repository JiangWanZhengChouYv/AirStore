# AirBox

[English](#english) · [中文](#中文)

Part of [AirStore](https://github.com/JiangWanZhengChouYv/AirStore). This document is about AirBox only.

---

## English

AirBox is AirStore's container: apps run inside AirBox, so they use none of a free Apple ID's three active
App IDs, and no Home Screen icon is added.

AirBox itself is a re-skin of [LiveContainer](https://github.com/LiveContainer/LiveContainer) -- the UI,
install and signing are upstream's; AirStore only hands it the ipa and the certificate.

### What it does

- Import an ipa from AirStore and pick **Run in AirBox**; AirBox signs and installs it itself.
- Launch guests from AirBox's app list; the higher memory limit applies.
- AirStore's My Apps has an **Apps in AirBox** section to see and manage them.
- JIT is opt-in per app, with AirStore (shown as StikDebug) as the default enabler.

### Enabling JIT

Prerequisite: **PairingFile_RemoteRP** is set as Preferred (Settings > Advanced > Pairing File Management >
long-press the card > Set as Preferred).

1. AirBox > Settings > **JIT** > **JIT Enabler** > **StikDebug** (already the default).
2. Open the target app's settings and turn on **Launch with JIT**.
3. Tap the app: AirStore opens and runs the JIT flow (the first time downloads and mounts a developer disk
   image), then the guest comes back with JIT.

Opening the app from AirStore's "Apps in AirBox" uses the same flow. If JIT fails, turn "Launch with JIT"
off for that app; a normal launch is unaffected.

### Installing

- **Recommended:** Container Mode in AirStore's onboarding installs it; or Settings > Advanced >
  Container > AirBox > Install.
- **Manual:** download `AirBox-<version>.ipa` from
  [develop-latest](https://github.com/JiangWanZhengChouYv/AirStore/releases/tag/develop-latest) and install
  it through AirStore's "+ > Choose from Files". That is what makes AirStore recognise it and deliver into it.
- With a manual iLoader install of AirStore, generate the pairing file with `idevice_pair`; see
  [the pairing section in the README](README.md#pairing-file-manual-installs).

### Limits and notes

- Experimental; not a Stable selling point.
- Delete the old AirBox with the old bundle id (`com.SideStore.SideStore.AirBox`): two `airbox://` handlers
  would conflict.
- Guests are signed with your own certificate; the certificate and pairing file live in AirBox's App Group
  and are lost on a bundle-id change or a reinstall.
- Tweaks, multitasking and the rest of the UI are LiveContainer's.

---

## 中文

AirBox 是 AirStore 的容器：App 跑在 AirBox 里面，不占免费 Apple ID 的 3 个活跃 App 名额，也不在桌面留图标。

AirBox 本体是 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 的换皮——界面、安装、签名都用上游那套，AirStore 只负责把 ipa 和证书投递进去。

### 能做什么

- 从 AirStore 导入 ipa，选 **Run in AirBox**，AirBox 自己签名并安装。
- 在 AirBox 的 App 列表里启动 guest；高内存权限可用。
- AirStore →「我的 App」里有 **Apps in AirBox** 分区，可以看到和管理里面的 App。
- JIT 可选：给某个 App 打开「带JIT启动」，启用器默认是 AirStore（界面里显示为 StikDebug）。

### 开 JIT

前提：配对文件里的 **PairingFile_RemoteRP** 已设为 Preferred（设置 → 高级 → Pairing File Management → 长按卡片 → Set as Preferred）。

1. AirBox → 设置 → **JIT** 分组 →「JIT启用工具」选 **StikDebug**（默认已经是）。
2. 目标 App → 它的设置 → 打开 **「带JIT启动」**。
3. 点这个 App：会跳到 AirStore 做 JIT（第一次要下载/挂载开发者镜像，慢一点），回来 guest 就带 JIT 跑。

从 AirStore 的「Apps in AirBox」里点「打开」也走同一条流程。JIT 失败时先把那个 App 的「带JIT启动」关掉，普通启动不受影响。

### 安装

- **推荐**：AirStore 新手引导里的「容器模式」一步会自动装；或 设置 → 高级 → Container → AirBox → 安装。
- **手动**：从 [develop-latest](https://github.com/JiangWanZhengChouYv/AirStore/releases/tag/develop-latest) 下载 `AirBox-<版本>.ipa`，用 AirStore 的「+ → Choose from Files」安装——这样商店才认得它，才能往里投递 App。
- 手动用 iLoader 装 AirStore 的：配对文件用 `idevice_pair` 生成，见 [README 的配对文件一节](README_zh.md#配对文件手动安装)。

### 限制与注意

- 实验性功能，不作为 Stable 的卖点。
- 旧 bundle id 的 AirBox（`com.SideStore.SideStore.AirBox`）要删掉：两个 `airbox://` 会抢。
- guest 由你自己的证书签名；证书和配对文件放在 AirBox 的 App Group 里，换 bundle id 或卸载重装会丢。
- Tweaks、多任务等页面沿用 LiveContainer 上游。

---

## Links / 链接

- AirStore repository / 仓库：<https://github.com/JiangWanZhengChouYv/AirStore>
- Downloads / 下载：<https://github.com/JiangWanZhengChouYv/AirStore/releases>
- Develop builds / develop 构建：<https://github.com/JiangWanZhengChouYv/AirStore/releases/tag/develop-latest>
- Upstream LiveContainer / 上游 LiveContainer：<https://github.com/LiveContainer/LiveContainer>
- Pairing file docs / 配对文件说明：<https://docs.sidestore.io/docs/advanced/pairing-file>
