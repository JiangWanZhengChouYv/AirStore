# AirStore

中文说明（与 [README.md](README.md) 同步维护，两份内容有出入时以英文为准）。

**AirStore 是 SideStore 的 fork，不需要 AltServer。本仓库唯一的目标，是把 iOS 26.4 及以上那个 `-80045` 登录错误解决掉。**

## ⚠️ 维护说明

> **单人维护**：这个项目是我业余时间一个人在做。关键问题（尤其 `-80045`）我尽力修，但不保证每条 Issue 都及时回、每个 PR 都来得及 review。
>
> **提 Issue 之前**：
> 1. 先搜一下已有 Issue，别开重复的。
> 2. 带上详细日志（Settings > Error Log > Export Log 导出）和复现步骤。没有日志的「登不上」基本没法查。
>
> 本项目没有 Discord 之类的聊天群，反馈只走本仓库 Issues。

## 为什么要用 AirStore

苹果从 2026 年 10 月开始收紧 GrandSlam / Anisette 限制：请求里声明的客户端身份，必须和真正生成 `X-Apple-I-MD` 这组头的 ADI 同源。手机端的 AnisetteKit 跑的是安卓的 `libCoreADI.so`，却按 MacBook 的身份去声明，于是苹果直接拒绝，登录卡在 `-80045`，后来干脆回 503。大量公共 Anisette 服务器也属于这一类，已经不能用。

AirStore 的修法是：先读 v3 服务器自己的 `/v3/client_info`，用**服务器那对**身份和 UA 去做机器注册和登录，认证链路上每个需要一次性口令的地方都重新取一份头，并把默认服务器换成背后是真 Windows ADI 的那台，同时关掉「失败就换下一台服务器」的轮替（轮替会在 21 台里走到一台还能回头但身份是假的服务器，把真实错误盖掉）。

## 现在的验证状态（说清楚，别当成已完工）

- **已验证**：iPhone，iOS 27.2，免费个人 Apple ID。登录走完 2FA 和取 Team，Settings 里能看到账号。
- **未验证**：登录成功之后，安装和刷新第三方 App 的完整链路。这条验证过了我会把 0.8.0 的发布说明里那句「Not verified」改掉。
- **单点依赖**：登录要经过第三方服务器 `win.ani.sidestore.io`。它挂了或者换成安卓 ADI，登录会再次坏掉，本地没有替代方案（手机本地那套就是被苹果拒的那套）。设置里可以换服务器，同源候选见下面。

## 安装

直接用 [0.8.0 pre-release](https://github.com/JiangWanZhengChouYv/AirStore/releases/tag/0.8.0) 里的 `SideStore-0.8.0.ipa`，装法和平时装 SideStore 一样（iloader，或 App 内的 Remote Pairing 流程）。AirStore 故意保留 SideStore 的 bundle id，所以它是**覆盖**你已有的 SideStore，而不是并排放一个新手屏图标。主屏名字显示为 AirStore。

从 SideStore 或旧版 AirStore 升级过的，两个设置必须自己确认（新的默认值只在全新安装时生效，老安装里你存过的值优先）：

1. Settings > Advanced > User Customizations：**On-Device Anisette 关掉**。本地那套跑的是苹果不认的安卓 ADI。
2. Anisette 服务器页：**你钉住的那台服务器优先级高于新默认值**。请选 **SideStore (Windows ADI)**，也就是 `https://win.ani.sidestore.io`；**Enable Auto Rotation 保持关闭**。症状区分：服务器不对时报的是苹果 503（App 里显示成 unparseable format），不是 `-80045`。

## 更新

SideStore 社区源里 SideStore 自己也是一条可更新条目，它的 `downloadURL` 指向上游构建。AirStore 沿用同一个 bundle id，所以点那条更新会把上游 SideStore 装回来盖掉 AirStore，`-80045` 的修复当场没了。请改加这个源（Settings > Sources > Add Source）：

```
https://raw.githubusercontent.com/JiangWanZhengChouYv/AirStore/develop/source/airstore-source.json
```

它只发 AirStore 的版本。已经加了 SideStore 社区的，别的 App 照常用，SideStore 那一行的更新提示忽略掉。

## 自己查服务器能不能用

不用凭据就能看个大概，判据是它声明的身份：

```sh
curl -s https://<服务器地址>/v3/client_info
```

- 报 `<PC> <Windows;6.2(0,0);9200>`（真 Windows ADI）：`win.ani.sidestore.io`、`ani.jkcoxson.com`、`ani2.stikstore.app`
- 报 `<MacBookPro13,3> <Mac OS X;10.12.6>`（老 Mac ADI）：`new.ani.sidestore.io`、`mac-ani.jkcoxson.com`、`ani3.stikstore.app`
- 报 `<MacBookPro13,2> <macOS;13.1;22C65>`：这就是 AnisetteKit 的默认声明串。2026-10-19 探测的 21 台里有 12 台是这一串（官方列表 19 台里占 12 台），苹果拒的就是这类，别把登录机会浪费在它们身上。

## 从源码构建

需要 macOS 和 Xcode 15+。**本项目没有 CocoaPods**，不要 `pod install`，也没有 `.xcworkspace`。

```sh
git clone https://github.com/JiangWanZhengChouYv/AirStore.git --recurse-submodules
cd AirStore
make build fakesign ipa        # 产出 SideStore.ipa
```

`fakesign` 表示产物里不带开发者证书，这正是想要的：App 在首次登录时用你自己的 Apple ID 拿到身份。CI 也是同一套流程，任意提交的 Actions 运行里都能拿到打包产物。

## 关于名字

主屏名字、权限弹窗、注册到苹果设备列表里的机器名都已经是 AirStore，但 bundle id（`com.SideStore.SideStore`）、App Group 和产物文件名 `SideStore.ipa` 故意没动：改这些会换签名标识，牵动 App Group、iCloud 容器和能用的描述文件，还会让已有安装变成孤儿。

## 参与贡献

欢迎 PR。规则写在 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [AGENTS.md](AGENTS.md) 里，两条最关键：

- **AI 参与必须声明**：说明 AI 在查找、实现或测试哪一步帮过忙。提交人自己得能讲清这个改动做了什么、为什么要做。
- **不允许自动化往 GitHub 上发东西**：PR、Issue、Discussion、评论都必须由人提交。草案可以生成，按钮人来按。

## 致谢与许可

- 基于 [SideStore](https://github.com/SideStore/SideStore)
- 基于 [AltStore](https://github.com/altstoreio/AltStore)
- 许可与上游一致
