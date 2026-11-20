// The page at https://as.mz0520.de5.net/ -- the front door for AirStore.
//
// Kept as a template string rather than a static asset binding on purpose: the Worker is a single
// file deploy today, and a page with no build step is one fewer thing that can drift from the feed
// it advertises. Every version, size and note on it is fetched from /source/airstore-source.json at
// load time, so the page can never claim a build the feed does not serve.

export const homeHTML = String.raw`<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#05060a">
<meta name="description" content="AirStore：用你自己的 Apple ID，在 iPhone 上侧载和续签 App，不需要电脑。">
<meta property="og:title" content="AirStore">
<meta property="og:description" content="用你自己的 Apple ID，在 iPhone 上侧载和续签 App，不需要电脑。">
<meta property="og:image" content="https://as.mz0520.de5.net/gh/JiangWanZhengChouYv/AirStore@develop/assets/airstore-header-1280x640.png">
<title>AirStore · 在自己手机上侧载和续签</title>
<link rel="icon" href="/gh/JiangWanZhengChouYv/AirStore@develop/AltStore/Resources/Icons.xcassets/AppIcon.appiconset/1024.png">
<style>
  :root {
    --accent: #3b82f6;
    --accent-2: #8b5cf6;
    --ink: #f5f7ff;
    --muted: rgba(245,247,255,.62);
    --faint: rgba(245,247,255,.38);
    --glass: rgba(255,255,255,.06);
    --glass-2: rgba(255,255,255,.045);
    --line: rgba(255,255,255,.12);
    --radius: 26px;
    --max: 780px;
  }

  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  html, body { margin: 0; min-height: 100%; }

  body {
    font: 16px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC",
          "Helvetica Neue", Arial, sans-serif;
    color: var(--ink);
    background: #05060a;
    -webkit-font-smoothing: antialiased;
    overflow-x: hidden;
  }

  /* ---------- background ---------- */

  /* Aurora: four blobs drifting on different periods so the pattern never visibly repeats. */
  .aurora { position: fixed; inset: -20vmax; z-index: 0; filter: blur(60px) saturate(1.3); pointer-events: none; }
  .aurora span {
    position: absolute; width: 45vmax; height: 45vmax; border-radius: 50%;
    opacity: .5; mix-blend-mode: screen; will-change: transform;
  }
  .aurora span:nth-child(1) { background: radial-gradient(circle at 30% 30%, #2563eb, transparent 62%); animation: drift1 26s ease-in-out infinite; }
  .aurora span:nth-child(2) { background: radial-gradient(circle at 70% 60%, #7c3aed, transparent 62%); animation: drift2 32s ease-in-out infinite; }
  .aurora span:nth-child(3) { background: radial-gradient(circle at 40% 70%, #0ea5e9, transparent 62%); animation: drift3 38s ease-in-out infinite; }
  .aurora span:nth-child(4) { background: radial-gradient(circle at 60% 40%, #ec4899, transparent 62%); opacity: .32; animation: drift4 44s ease-in-out infinite; }

  @keyframes drift1 { 0%,100% { transform: translate3d(-8%, -4%, 0) scale(1); }   50% { transform: translate3d(14%, 8%, 0) scale(1.18); } }
  @keyframes drift2 { 0%,100% { transform: translate3d(10%, 6%, 0) scale(1.1); }  50% { transform: translate3d(-12%, -8%, 0) scale(.9); } }
  @keyframes drift3 { 0%,100% { transform: translate3d(0%, 12%, 0) scale(.95); }  50% { transform: translate3d(10%, -10%, 0) scale(1.15); } }
  @keyframes drift4 { 0%,100% { transform: translate3d(-14%, 8%, 0) scale(1.05); } 50% { transform: translate3d(6%, -12%, 0) scale(.88); } }

  /* A grain layer stops the large gradients from banding on OLED screens. */
  .grain {
    position: fixed; inset: 0; z-index: 1; pointer-events: none; opacity: .035;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
  }

  main { position: relative; z-index: 2; max-width: var(--max); margin: 0 auto; padding: clamp(26px, 6vh, 64px) 22px 84px; }

  /* ---------- nav ---------- */

  nav {
    position: sticky; top: 0; z-index: 20;
    display: flex; align-items: center; gap: 12px;
    margin: -8px -22px 26px; padding: 10px 22px;
    background: rgba(5,6,10,.55);
    backdrop-filter: blur(20px) saturate(1.6);
    -webkit-backdrop-filter: blur(20px) saturate(1.6);
    border-bottom: 1px solid rgba(255,255,255,.07);
  }
  nav .brand { display: flex; align-items: center; gap: 9px; font-weight: 650; font-size: 15px; letter-spacing: -.01em; }
  nav .brand img { width: 24px; height: 24px; border-radius: 6px; }
  nav .links { margin-left: auto; display: flex; gap: 4px; }
  nav a {
    color: var(--muted); text-decoration: none; font-size: 13.5px;
    padding: 6px 11px; border-radius: 9px; transition: color .2s, background .2s;
  }
  nav a:hover { color: var(--ink); background: rgba(255,255,255,.07); }
  @media (max-width: 520px) { nav .links a:not(:last-child) { display: none; } }

  /* ---------- hero ---------- */

  .hero { display: flex; align-items: flex-start; gap: 18px; margin-bottom: 26px; }
  .icon {
    width: 92px; height: 92px; border-radius: 23px; flex: none;
    box-shadow: 0 18px 44px -14px rgba(59,130,246,.7), 0 0 0 1px rgba(255,255,255,.1) inset;
    animation: float 7s ease-in-out infinite;
  }
  @keyframes float {
    0%,100% { transform: translateY(0) rotate(0deg); }
    50%     { transform: translateY(-7px) rotate(-1.2deg); }
  }

  h1 {
    font-size: clamp(30px, 7.4vw, 44px); line-height: 1.1; margin: 0 0 6px; letter-spacing: -.025em;
    background: linear-gradient(100deg, #fff 20%, #b9d2ff 50%, #fff 80%);
    background-size: 200% auto;
    -webkit-background-clip: text; background-clip: text; color: transparent;
    animation: shimmer 6s linear infinite;
  }
  @keyframes shimmer { to { background-position: 200% center; } }

  .tagline { color: var(--muted); margin: 0 0 12px; font-size: 15.5px; }
  .status { display: inline-flex; align-items: center; gap: 7px; font-size: 13px; color: var(--muted); }
  .dot { width: 7px; height: 7px; border-radius: 50%; background: #64748b; transition: background .3s; }
  .dot.ok { background: #22c55e; box-shadow: 0 0 0 0 rgba(34,197,94,.7); animation: pulse 2.4s ease-out infinite; }
  .dot.bad { background: #ef4444; }
  @keyframes pulse {
    0%   { box-shadow: 0 0 0 0 rgba(34,197,94,.6); }
    70%  { box-shadow: 0 0 0 9px rgba(34,197,94,0); }
    100% { box-shadow: 0 0 0 0 rgba(34,197,94,0); }
  }

  .cta { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 4px; }

  .btn {
    display: inline-flex; align-items: center; gap: 8px;
    padding: 12px 22px; border-radius: 999px;
    font-size: 15px; font-weight: 620; text-decoration: none; color: #fff;
    background: linear-gradient(135deg, var(--accent), var(--accent-2));
    border: 0; cursor: pointer; font-family: inherit;
    box-shadow: 0 14px 32px -14px rgba(99,102,241,.95);
    transition: transform .2s cubic-bezier(.22,1,.36,1), filter .25s, box-shadow .25s;
  }
  .btn:hover { filter: brightness(1.1); transform: translateY(-1px); }
  .btn:active { transform: scale(.97); }
  .btn.ghost {
    background: rgba(255,255,255,.07); color: var(--ink);
    border: 1px solid var(--line); box-shadow: none; font-weight: 520;
  }
  .btn.ghost:hover { background: rgba(255,255,255,.12); }
  .btn svg { width: 16px; height: 16px; }

  /* ---------- cards / sections ---------- */

  .card {
    margin-top: 18px; padding: 22px;
    border-radius: var(--radius);
    background: var(--glass); border: 1px solid var(--line);
    backdrop-filter: blur(24px) saturate(1.5);
    -webkit-backdrop-filter: blur(24px) saturate(1.5);
    box-shadow: 0 24px 60px -30px rgba(0,0,0,.9);
    transition: border-color .35s, background .35s;
  }
  .card:hover { border-color: rgba(255,255,255,.2); }

  h2 {
    font-size: 20px; line-height: 1.3; margin: 0 0 14px; letter-spacing: -.01em; font-weight: 700;
  }
  h2 .small { display: block; font-size: 12.5px; font-weight: 500; color: var(--faint); letter-spacing: .04em; text-transform: uppercase; margin-bottom: 5px; }

  /* ---------- tracks ---------- */

  .tracks { display: grid; gap: 10px; }
  .track {
    display: flex; align-items: center; gap: 12px;
    padding: 12px 14px; border-radius: 16px;
    background: var(--glass-2); border: 1px solid rgba(255,255,255,.07);
    font-variant-numeric: tabular-nums;
    transition: background .25s, transform .25s;
  }
  .track:hover { background: rgba(255,255,255,.08); transform: translateX(2px); }
  .badge {
    font-size: 11px; font-weight: 700; letter-spacing: .04em;
    padding: 3px 9px; border-radius: 999px;
    background: rgba(255,255,255,.1); color: #dbeafe; flex: none;
  }
  .badge.develop { background: rgba(59,130,246,.22); color: #bfdbfe; }
  .badge.stable  { background: rgba(34,197,94,.2);  color: #bbf7d0; }
  .badge.nightly { background: rgba(139,92,246,.22); color: #ddd6fe; }
  .ver { font-size: 13px; color: #e8edff; word-break: break-all; flex: 1; min-width: 0; }
  .size { font-size: 12px; color: var(--muted); flex: none; }
  .track a { color: #bfdbfe; text-decoration: none; font-size: 12.5px; flex: none; }
  .track a:hover { text-decoration: underline; }

  /* ---------- features ---------- */

  .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
  @media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }

  .feat {
    padding: 16px; border-radius: 18px;
    background: var(--glass-2); border: 1px solid rgba(255,255,255,.07);
    transition: transform .3s cubic-bezier(.22,1,.36,1), border-color .3s, background .3s;
  }
  .feat:hover { transform: translateY(-3px); border-color: rgba(255,255,255,.18); background: rgba(255,255,255,.07); }
  .feat .ico {
    width: 34px; height: 34px; border-radius: 10px; display: grid; place-items: center;
    margin-bottom: 10px;
    background: linear-gradient(135deg, rgba(59,130,246,.3), rgba(139,92,246,.3));
    border: 1px solid rgba(255,255,255,.12);
  }
  .feat .ico svg { width: 17px; height: 17px; stroke: #cfe0ff; fill: none; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }
  .feat h3 { font-size: 14.5px; margin: 0 0 4px; font-weight: 650; letter-spacing: -.005em; }
  .feat p { margin: 0; font-size: 13px; line-height: 1.6; color: var(--muted); }

  /* ---------- screenshots ---------- */

  .shots { display: flex; gap: 14px; overflow-x: auto; padding: 4px 4px 12px; scroll-snap-type: x mandatory; }
  .shots figure { margin: 0; flex: none; scroll-snap-align: center; }
  .shots img {
    width: 232px; border-radius: 22px; display: block;
    border: 1px solid rgba(255,255,255,.12);
    box-shadow: 0 22px 50px -24px #000;
    transition: transform .35s cubic-bezier(.22,1,.36,1);
  }
  .shots img:hover { transform: scale(1.03) translateY(-2px); }
  .shots figcaption { font-size: 12px; color: var(--faint); text-align: center; margin-top: 8px; }
  .shots::-webkit-scrollbar { height: 6px; }
  .shots::-webkit-scrollbar-thumb { background: rgba(255,255,255,.16); border-radius: 999px; }

  /* ---------- steps ---------- */

  .steps { counter-reset: s; display: grid; gap: 14px; margin: 0; padding: 0; list-style: none; }
  .steps li { counter-increment: s; position: relative; padding-left: 40px; font-size: 14px; color: var(--muted); }
  .steps li::before {
    content: counter(s);
    position: absolute; left: 0; top: -1px;
    width: 26px; height: 26px; border-radius: 9px;
    display: grid; place-items: center;
    font-size: 12.5px; font-weight: 700; color: #dbeafe;
    background: linear-gradient(135deg, rgba(59,130,246,.32), rgba(139,92,246,.32));
    border: 1px solid rgba(255,255,255,.14);
  }
  .steps strong { color: var(--ink); font-weight: 600; }

  /* ---------- changelog ---------- */

  .log { display: grid; gap: 6px; }
  .log details {
    border-radius: 16px; background: var(--glass-2);
    border: 1px solid rgba(255,255,255,.07); overflow: hidden;
  }
  .log details[open] { background: rgba(255,255,255,.06); }
  .log summary {
    cursor: pointer; padding: 13px 16px; font-size: 13.5px; font-weight: 600;
    display: flex; align-items: center; gap: 10px; list-style: none;
  }
  .log summary::-webkit-details-marker { display: none; }
  .log summary::after {
    content: "›"; margin-left: auto; color: var(--faint); font-size: 17px;
    transition: transform .25s;
  }
  .log details[open] summary::after { transform: rotate(90deg); }
  .log .when { font-size: 12px; color: var(--faint); font-weight: 400; margin-left: auto; }
  .log details[open] .when { margin-left: 0; }
  .log .body { padding: 0 16px 15px; font-size: 13.5px; color: var(--muted); }
  .log .body p { margin: 0; }

  /* ---------- news ---------- */

  .news { display: grid; gap: 10px; }
  .item {
    padding: 15px 16px; border-radius: 16px;
    background: var(--glass-2); border: 1px solid rgba(255,255,255,.07);
    border-left: 3px solid var(--accent);
    transition: background .25s, transform .25s;
  }
  .item:hover { background: rgba(255,255,255,.075); transform: translateX(2px); }
  .item h3 { margin: 0 0 5px; font-size: 14px; font-weight: 650; }
  .item p { margin: 0; font-size: 13px; color: var(--muted); }
  .item time { font-size: 11.5px; color: var(--faint); display: block; margin-bottom: 5px; }

  /* ---------- faq ---------- */

  .faq { display: grid; gap: 6px; }
  .faq details { border-radius: 14px; background: var(--glass-2); border: 1px solid rgba(255,255,255,.07); }
  .faq summary { cursor: pointer; padding: 13px 16px; font-size: 13.5px; font-weight: 600; list-style: none; display: flex; gap: 10px; align-items: center; }
  .faq summary::-webkit-details-marker { display: none; }
  .faq summary::after { content: "+"; margin-left: auto; color: var(--faint); transition: transform .25s; }
  .faq details[open] summary::after { transform: rotate(45deg); }
  .faq .body { padding: 0 16px 15px; font-size: 13.5px; color: var(--muted); }
  .faq .body p { margin: 0 0 8px; }
  .faq .body p:last-child { margin-bottom: 0; }
  .faq code {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;
    background: rgba(0,0,0,.35); padding: 1px 5px; border-radius: 5px; color: #cfe0ff;
  }

  /* ---------- source field ---------- */

  .field {
    display: flex; align-items: center; gap: 10px;
    padding: 12px 14px; border-radius: 14px;
    background: rgba(0,0,0,.3); border: 1px solid rgba(255,255,255,.09);
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 12.5px; color: #cfe0ff; word-break: break-all;
  }
  button.copy {
    flex: none; font: inherit; font-size: 12.5px; font-weight: 600; color: #fff;
    background: linear-gradient(135deg, var(--accent), var(--accent-2));
    border: 0; border-radius: 10px; padding: 8px 13px; cursor: pointer;
    transition: transform .15s, filter .25s;
  }
  button.copy:hover { filter: brightness(1.12); }
  button.copy:active { transform: scale(.95); }
  button.copy.done { background: linear-gradient(135deg, #16a34a, #22c55e); }

  /* ---------- footer ---------- */

  footer {
    margin-top: 40px; padding-top: 22px; text-align: center;
    font-size: 12.5px; color: var(--faint); line-height: 1.9;
    border-top: 1px solid rgba(255,255,255,.07);
  }
  footer a { color: rgba(245,247,255,.6); text-decoration: none; }
  footer a:hover { color: var(--ink); text-decoration: underline; }

  /* ---------- motion ---------- */

  .reveal { opacity: 0; transform: translateY(16px); }
  .reveal.in {
    opacity: 1; transform: none;
    transition: opacity .75s cubic-bezier(.22,1,.36,1), transform .75s cubic-bezier(.22,1,.36,1);
  }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      animation-duration: .001ms !important;
      animation-iteration-count: 1 !important;
      transition-duration: .001ms !important;
    }
    .reveal { opacity: 1; transform: none; }
    html { scroll-behavior: auto; }
  }

  @media (max-width: 420px) {
    .icon { width: 68px; height: 68px; border-radius: 18px; }
    .size { display: none; }
    .card { padding: 18px; }
  }
</style>
</head>
<body>

<div class="aurora"><span></span><span></span><span></span><span></span></div>
<div class="grain"></div>

<main>

  <nav>
    <div class="brand">
      <img src="/gh/JiangWanZhengChouYv/AirStore@develop/AltStore/Resources/Icons.xcassets/AppIcon.appiconset/1024.png" alt="">
      AirStore
    </div>
    <div class="links">
      <a href="#features">功能</a>
      <a href="#shots">截图</a>
      <a href="#install">安装</a>
      <a href="#changelog">更新</a>
      <a href="https://github.com/JiangWanZhengChouYv/AirStore" target="_blank" rel="noopener">GitHub</a>
    </div>
  </nav>

  <header class="hero reveal">
    <img class="icon" alt="AirStore" src="/gh/JiangWanZhengChouYv/AirStore@develop/AltStore/Resources/Icons.xcassets/AppIcon.appiconset/1024.png">
    <div>
      <h1>AirStore</h1>
      <p class="tagline">用你自己的 Apple ID，在 iPhone 上侧载和续签 App。<br>不需要电脑，不需要 AltServer。</p>
      <div class="status"><span class="dot" id="dot"></span><span id="status-text">正在读取源…</span></div>
    </div>
  </header>

  <div class="cta reveal">
    <a class="btn" href="#install">
      <svg viewBox="0 0 16 16" fill="currentColor"><path d="M7.25 1.75a.75.75 0 0 1 1.5 0v7.19l2.22-2.22a.75.75 0 1 1 1.06 1.06l-3.5 3.5a.75.75 0 0 1-1.06 0l-3.5-3.5a.75.75 0 0 1 1.06-1.06l2.22 2.22V1.75Z"/><path d="M2.5 11.5a.75.75 0 0 0-1.5 0v1.25A2.25 2.25 0 0 0 3.25 15h9.5A2.25 2.25 0 0 0 15 12.75V11.5a.75.75 0 0 0-1.5 0v1.25a.75.75 0 0 1-.75.75h-9.5a.75.75 0 0 1-.75-.75V11.5Z"/></svg>
      怎么安装
    </a>
    <a class="btn ghost" id="nightly-btn" href="#" target="_blank" rel="noopener">下载 Nightly</a>
    <a class="btn ghost" href="https://github.com/JiangWanZhengChouYv/AirStore" target="_blank" rel="noopener">查看源码</a>
  </div>

  <section class="card reveal" id="builds">
    <h2><span class="small">Channels</span>当前构建</h2>
    <div class="tracks" id="tracks">
      <div class="track"><span class="badge">…</span><span class="ver">读取中</span></div>
    </div>
  </section>

  <section class="card reveal" id="features">
    <h2><span class="small">Why</span>它解决什么</h2>
    <div class="grid">
      <div class="feat">
        <div class="ico"><svg viewBox="0 0 24 24"><path d="M12 3v18M5 8l7-5 7 5M5 16l7 5 7-5"/></svg></div>
        <h3>不需要电脑</h3>
        <p>和 SideStore 一样全在本机完成。没有 AltServer，也没有「请连接至电脑」。</p>
      </div>
      <div class="feat">
        <div class="ico"><svg viewBox="0 0 24 24"><path d="M12 2 4 6v6c0 5 3.4 9.3 8 10 4.6-.7 8-5 8-10V6l-8-4Z"/><path d="m9 12 2 2 4-4"/></svg></div>
        <h3>绕过 -80045</h3>
        <p>iOS 26.4+ 登录死循环已修。客户端身份与 Anisette 服务器一致，单次 MD 每一步都刷新。</p>
      </div>
      <div class="feat">
        <div class="ico"><svg viewBox="0 0 24 24"><path d="M4 12h4l3 8 3-16 3 8h3"/></svg></div>
        <h3>增量更新</h3>
        <p>更新只下与你当前版本对应的补丁，不再重下整包。实测 8 KB 到 8 MB。</p>
      </div>
      <div class="feat">
        <div class="ico"><svg viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h10"/></svg></div>
        <h3>移动数据可装</h3>
        <p>侧载和续签都不要求 Wi-Fi。关掉 Wi-Fi 只走蜂窝，免费账号也能装成功。</p>
      </div>
      <div class="feat">
        <div class="ico"><svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="3"/><path d="M3 10h18M9 4v16"/></svg></div>
        <h3>AirBox 容器</h3>
        <p>把 App 跑在容器里，不占免费账号那 3 个活跃名额，还能拿更高内存额度。</p>
      </div>
      <div class="feat">
        <div class="ico"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.5 3 14 0 18M12 3C9 6.5 9 17.5 12 21"/></svg></div>
        <h3>中文界面</h3>
        <p>简体中文完整本地化，配对文件与证书支持双向导入导出。</p>
      </div>
    </div>
  </section>

  <section class="card reveal" id="shots">
    <h2><span class="small">Screens</span>长什么样</h2>
    <div class="shots" id="shots-row">
      <figure>
        <img loading="lazy" src="/gh/JiangWanZhengChouYv/AirStore@develop/source/screenshots/airstore-appdetail.jpeg" alt="应用详情">
        <figcaption>详情 · 版本与说明</figcaption>
      </figure>
      <figure>
        <img loading="lazy" src="/gh/JiangWanZhengChouYv/AirStore@develop/source/screenshots/airstore-browse.jpeg" alt="浏览页">
        <figcaption>浏览 · 精选与分类</figcaption>
      </figure>
      <figure>
        <img loading="lazy" src="/gh/JiangWanZhengChouYv/AirStore@develop/source/screenshots/airstore-myapps.jpeg" alt="我的 App">
        <figcaption>我的 App · 续签倒计时</figcaption>
      </figure>
      <figure>
        <img loading="lazy" src="/gh/JiangWanZhengChouYv/AirStore@develop/source/screenshots/airstore-settings.jpeg" alt="设置">
        <figcaption>设置 · 账号与外观</figcaption>
      </figure>
      <figure>
        <img loading="lazy" src="/gh/JiangWanZhengChouYv/AirStore@develop/source/screenshots/airstore-news.jpeg" alt="新闻">
        <figcaption>新闻 · 更新动态</figcaption>
      </figure>
      <figure>
        <img loading="lazy" src="/gh/JiangWanZhengChouYv/AirStore@develop/source/screenshots/airstore-sources.jpeg" alt="源管理">
        <figcaption>源 · 官方与第三方</figcaption>
      </figure>
    </div>
  </section>

  <section class="card reveal" id="install">
    <h2><span class="small">Install</span>怎么装</h2>
    <ol class="steps">
      <li><strong>准备签名环境。</strong>电脑上装 <a href="https://github.com/JiangWanZhengChouYv/AirStore/releases/tag/helper-latest" target="_blank" rel="noopener" style="color:#bfdbfe">AirStore Helper</a>（macOS / Windows），用数据线连上 iPhone。</li>
      <li><strong>选版本并安装。</strong>Helper 里选一台设备，把上面的 <code style="font-family:ui-monospace">AirStore.ipa</code> 装进去；它会顺带放好配对文件。</li>
      <li><strong>打开 App 登录。</strong>用你自己的 Apple ID 登录（免费账号即可），按引导完成配对和证书。</li>
      <li><strong>以后不用再连线。</strong>续签在手机上完成；想自动续签，按引导建一个「快捷指令」自动化，每 5–6 天跑一次。</li>
    </ol>
    <p class="tagline" style="margin-top:16px;font-size:13px">
      需要 iOS 17.4 或更高。0.9.0 起 bundle id 变成 <code style="font-family:ui-monospace;font-size:12px;background:rgba(0,0,0,.35);padding:1px 5px;border-radius:5px;color:#cfe0ff">com.JiangWanZhengChouYv.AirStore</code>，
      和旧 AirStore / SideStore 是两个独立 App，不能覆盖安装 —— 迁移前先导出证书和配对文件。
    </p>
  </section>

  <section class="card reveal" id="changelog">
    <h2><span class="small">Changelog</span>更新日志</h2>
    <div class="log" id="log">
      <details><summary>读取中…</summary></details>
    </div>
  </section>

  <section class="card reveal" id="news">
    <h2><span class="small">News</span>动态</h2>
    <div class="news" id="news-list">
      <div class="item"><p>读取中…</p></div>
    </div>
  </section>

  <section class="card reveal" id="source">
    <h2><span class="small">Add source</span>添加到 AirStore</h2>
    <div class="field">
      <span id="source-url">https://as.mz0520.de5.net/source/airstore-source.json</span>
      <button class="copy" id="copy-btn" type="button">复制</button>
    </div>
    <p class="tagline" style="margin-top:12px;font-size:13px">
      设置 → 源 → 添加源。内置源已经指向这里，通常不用手动加。
    </p>
  </section>

  <section class="card reveal" id="faq">
    <h2><span class="small">FAQ</span>常见问题</h2>
    <div class="faq">
      <details>
        <summary>一定要交钱吗？</summary>
        <div class="body"><p>不用。免费 Apple ID 就够，代价是同时最多 3 个活跃 App、App ID 上限 10 个，证书 7 天要续一次。AirBox 里的 App 不占这 3 个名额。</p></div>
      </details>
      <details>
        <summary>为什么装完打不开 / 闪一下就没？</summary>
        <div class="body">
          <p>最常见的是签名失效或安装包损坏（系统在 exec 阶段就拒绝了，不会留下崩溃报告）。用 Helper 覆盖安装一次通常就好，数据保留。</p>
          <p>如果还是不行，在 设置 → 隐私与安全性 → 分析与改进 → 分析数据 里搜 <code>SideStore</code>，把当天的 <code>.ips</code> 发到 Issue。</p>
        </div>
      </details>
      <details>
        <summary>登录卡在 -80045 / 一直转圈？</summary>
        <div class="body"><p>先在 设置 → 连接与签名 → Anisette 服务器 里看一眼服务器是不是绿的。列表里的红点表示那台服务器不可达，换一台或打开自动轮换再试。仍然失败就把日志导出来。</p></div>
      </details>
      <details>
        <summary>更新会丢数据吗？</summary>
        <div class="body"><p>不会。同一证书签名的覆盖安装是原地升级。换证书签的包才会装失败，那时才需要先导出证书和配对文件、卸载、重装、再导入。</p></div>
      </details>
      <details>
        <summary>Nightly / 开发版有什么区别？</summary>
        <div class="body"><p>开发版（develop）每次推送都出包，最快拿到新功能，也最可能带问题。Nightly 是每天一次的完整 Release 构建，更稳一些。正式版（stable）才是给日常使用的。</p></div>
      </details>
      <details>
        <summary>隐私：这台服务器看到了什么？</summary>
        <div class="body"><p>这是一个只读镜像：它按请求去 GitHub 取源文件和应用包再转发，不记录账号、不碰 Apple ID、不保存下载内容。App 的登录和签名全程在你手机上完成。</p></div>
      </details>
    </div>
  </section>

  <footer class="reveal">
    AirStore 是 <a href="https://github.com/SideStore/SideStore" target="_blank" rel="noopener">SideStore</a> 的 fork，<a href="https://github.com/JiangWanZhengChouYv/AirStore/blob/develop/LICENSE" target="_blank" rel="noopener">AGPL-3.0</a>。<br>
    本站由 Cloudflare Worker 提供，实时读取 <code style="font-family:ui-monospace">develop-source</code> 分支，不做缓存。<br>
    <a href="/source/airstore-source.json">airstore-source.json</a> ·
    <a href="/source/default-sources.json">default-sources.json</a> ·
    <a href="/health">health</a>
  </footer>

</main>

<script>
(() => {
  const FEED = "/source/airstore-source.json";
  const dot = document.getElementById("dot");
  const statusText = document.getElementById("status-text");
  const tracksEl = document.getElementById("tracks");
  const logEl = document.getElementById("log");
  const newsEl = document.getElementById("news-list");

  const reveal = () => {
    document.querySelectorAll(".reveal").forEach((el, i) => {
      setTimeout(() => el.classList.add("in"), 70 * i);
    });
  };

  const bytes = n => {
    if (!n) return "";
    const mb = n / (1024 * 1024);
    return mb >= 1 ? mb.toFixed(1) + " MB" : Math.round(n / 1024) + " KB";
  };

  const esc = s => String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");

  const day = s => {
    if (!s) return "";
    const d = new Date(s);
    return isNaN(d) ? "" : d.toISOString().slice(0, 10);
  };

  const ORDER = ["develop", "nightly", "stable"];
  const LABEL = { develop: "开发版", nightly: "Nightly", stable: "正式版" };

  // A develop version string carries its commit and a timestamp, which is useful on the builds list
  // and noise in a changelog heading, so the log shows only the marketing part.
  const shortVersion = v => {
    const base = String(v || "").split("-")[0];
    const m = String(v || "").match(/-(develop|nightly)-(\d{8})(\d{4})/);
    return m ? base + " · " + m[2].slice(0, 4) + "-" + m[2].slice(4, 6) + "-" + m[2].slice(6, 8) + " " + m[3].slice(0, 2) + ":" + m[3].slice(2, 4) : String(v || "");
  };

  const render = data => {
    const app = (data.apps || []).find(a => (a.bundleIdentifier || "").endsWith(".AirStore"));
    if (!app) throw new Error("源里没有 AirStore 条目");

    const channels = (app.releaseChannels || [])
      .filter(c => c.releases && c.releases.length)
      .sort((a, b) => {
        const ai = ORDER.indexOf(a.track), bi = ORDER.indexOf(b.track);
        return (ai < 0 ? 99 : ai) - (bi < 0 ? 99 : bi);
      });

    tracksEl.innerHTML = channels.map(c => {
      const r = c.releases[0];
      const track = c.track || "?";
      return '<div class="track">' +
        '<span class="badge ' + esc(track) + '">' + esc(LABEL[track] || track) + "</span>" +
        '<span class="ver">' + esc(r.version) + "</span>" +
        '<span class="size">' + bytes(r.size) + "</span>" +
        '<a href="' + esc(r.downloadURL) + '" target="_blank" rel="noopener">下载</a>' +
        "</div>";
    }).join("") || '<div class="track"><span class="ver">源里没有可用的构建</span></div>';

    const nightly = channels.find(c => c.track === "nightly");
    const nightlyBtn = document.getElementById("nightly-btn");
    if (nightly) nightlyBtn.href = nightly.releases[0].downloadURL;
    else nightlyBtn.remove();

    // Changelog: every version the feed carries, newest first.
    const versions = (app.versions || []).slice().sort((a, b) => String(b.date).localeCompare(String(a.date)));
    logEl.innerHTML = versions.map((v, i) =>
      "<details" + (i === 0 ? " open" : "") + ">" +
        "<summary>" + esc(shortVersion(v.version)) +
          '<span class="when">' + esc(day(v.date)) + "</span>" +
        "</summary>" +
        '<div class="body"><p>' + esc(v.localizedDescription || "此版本没有附带说明。") + "</p></div>" +
      "</details>"
    ).join("") || "<details><summary>没有可显示的版本</summary></details>";

    // News items the feed publishes.
    const news = (data.news || []).slice().sort((a, b) => String(b.date).localeCompare(String(a.date)));
    newsEl.innerHTML = news.map(n =>
      '<div class="item">' +
        "<time>" + esc(day(n.date)) + "</time>" +
        "<h3>" + esc(n.title) + "</h3>" +
        "<p>" + esc(n.caption) + "</p>" +
      "</div>"
    ).join("") || '<div class="item"><p>暂无动态。</p></div>';

    dot.classList.add("ok");
    statusText.textContent = "在线 · " + channels.length + " 个通道 · 共 " + versions.length + " 个版本";
  };

  const fail = error => {
    dot.classList.add("bad");
    statusText.textContent = "读不到源：" + (error.message || error);
    tracksEl.innerHTML = '<div class="track"><span class="ver">暂时无法读取，稍后重试。</span></div>';
    logEl.innerHTML = "<details><summary>暂时无法读取</summary></details>";
    newsEl.innerHTML = '<div class="item"><p>暂时无法读取动态。</p></div>';
  };

  fetch(FEED, { cache: "no-store" })
    .then(r => { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
    .then(render)
    .catch(fail)
    .finally(reveal);

  const copyBtn = document.getElementById("copy-btn");
  copyBtn.addEventListener("click", async () => {
    const text = document.getElementById("source-url").textContent.trim();
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const range = document.createRange();
      range.selectNodeContents(document.getElementById("source-url"));
      const sel = getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      document.execCommand("copy");
    }
    copyBtn.textContent = "已复制";
    copyBtn.classList.add("done");
    setTimeout(() => {
      copyBtn.textContent = "复制";
      copyBtn.classList.remove("done");
    }, 1600);
  });
})();
</script>
</body>
</html>
`;
