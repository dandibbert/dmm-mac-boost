# 页游保活

给 macOS 上的 DMM 页游用的轻量启动器：后台仍然 100% 常速，并且尽量比 Arc 少占内存。

Arc 会主动休眠不用的标签；Chromium 自己也会把后台定时器降到大约 1 次/秒，并暂停 `requestAnimationFrame`。远征、建造、回合、回复这类逻辑都会变慢，甚至完全停。页游保活不走「标签页」，而是给每个游戏开独立窗口，并在启动时：

- 关闭 Chromium 后台节流
- 在主页面和 iframe 里伪装「始终可见 / 始终有焦点」
- 所有窗口共用一份 DMM 登录态
- 不加载扩展、不加多余标签

收起窗口只会藏起界面，不会停游戏。点「结束」或退出应用才会卸掉。

## 在 Mac 上运行

需要 [Node.js 22+](https://nodejs.org/)。

```bash
npm install
npm run dev
```

第一次先点 **打开 DMM 登录**，登进 DMM / DMM GAMES。然后到游戏库打开具体页游，把地址栏 URL 存成一条，再点启动。

一般向（`dmm.com`）和成人向（`dmm.co.jp` / FANZA）登录态通常不通用，两边都要登一次。

打包成 macOS 应用：

```bash
npm run build:mac
```

## 怎么少占内存

- 不要再用 Arc 同时开一堆空间和标签。这个应用只跑你点过的页游。
- 不用看的窗口点 **收起（保持常速）**，不要关。
- 同时开 2–4 个页游比较合适。每个游戏本身就要一两百 MB，这是游戏的锅，不是启动器的锅。
- 登录态只存一份（`persist:pagekeep`），不会每个游戏复制一套浏览器配置。

启动器会显示当前进程内存，方便你对照活动监视器。

## 如果坚持用 Chrome

比 Electron 更省一层壳，但要自己带启动参数，否则后台照样被掐：

```bash
open -na "Google Chrome" --args \
  --user-data-dir="$HOME/Library/Application Support/PagekeepChrome" \
  --disable-background-timer-throttling \
  --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding \
  --disable-features=IntensiveWakeUpThrottling,CalculateNativeWinOcclusion
```

这只能关掉浏览器层节流。很多 DMM 页游还会监听 `document.hidden`，切走标签后自己暂停。那种情况还是用这个启动器更稳。

Firefox 也能把 `dom.min_background_timeout_value` 改回 `4`，内存往往更低，但不少 DMM 页游只按 Chrome 测过。

## 开发

```bash
npm run preview   # 只看启动器界面（浏览器预览，不会真正关节流）
npm run typecheck
```
