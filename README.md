# 页游保活

给 macOS 上的 DMM 页游用的轻量启动器：后台仍然 100% 常速，并且尽量比 Arc 少占内存。

## 推到 GitHub 并下载安装包

代码现在在 Cursor Origin 上。GitHub Actions 只认 GitHub，所以要 **在你自己的电脑上** 再建一个 GitHub 仓库，把代码推过去。这边登录不了你的 GitHub，没法替你推。

### 1. 在 GitHub 建空仓库

1. 打开 https://github.com/new （需先登录 GitHub）。
2. Repository name 填 `dmm-mac-boost`（别的名字也行，后面远程地址跟着改）。
3. 选 **Private** 或 Public 都可以。
4. **不要**勾 Add a README、.gitignore、License。必须是空仓库，否则第一次推送会冲突。
5. 点 Create repository。页面上会出现 `https://github.com/你的用户名/dmm-mac-boost.git`，复制下来。

### 2. 本机拿到这份代码（若还没有）

```bash
# Install the Origin CLI
curl -fsSL https://downloads.cursor.com/origin/install.sh | sh

# Sign in (also sets up git credentials)
origin auth login

# Clone the repository
origin repo clone mizuki-middleson/dmm-mac-boost
```

如果提示找不到 `origin`：

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Origin 仓库页：https://cursor.com/codebase/mizuki-middleson/dmm-mac-boost （Private，可在该页设置里改可见性）。CLI 文档：https://cursor.com/docs/origin/cli

### 3. 加上 GitHub 远程并推送

`origin` 这个远程已经指向 Cursor，不要改它。另加一个叫 `github` 的远程：

```bash
cd dmm-mac-boost

# 把「你的用户名」换成你的 GitHub 用户名，不一定和 Origin 的 mizuki-middleson 相同
git remote add github https://github.com/你的用户名/dmm-mac-boost.git

git push -u github main
```

第一次推送时，Git 会要 GitHub 登录。macOS 上一般会弹出浏览器；若要你填密码，不要填 GitHub 登录密码，到 https://github.com/settings/tokens 建一个 Fine-grained token（至少勾 Contents: Read and write），把 token 当作密码贴进去。

用 SSH 的话，远程改成：

```bash
git remote add github git@github.com:你的用户名/dmm-mac-boost.git
```

如果报 `remote github already exists`，说明加过了，直接 `git push -u github main`。

### 4. 下载编好的 .dmg

1. 打开你刚建的 GitHub 仓库 → **Actions**。
2. 点最新一次 **Build macOS**，等绿勾（大约几分钟）。
3. 最下面 **Artifacts** 下载 `pagekeep-macos`，解压后：
   - Apple Silicon（M 系列）：`Pagekeep-1.0.0-mac-arm64.dmg`
   - Intel：`Pagekeep-1.0.0-mac-x64.dmg`

想要一个长期挂着的下载页，再打标签（同样在本机执行）：

```bash
git tag v1.0.0
git push github v1.0.0
```

然后到仓库的 **Releases**。也可以在 Actions 页点 **Run workflow** 再编一次。

安装包没有 Apple 开发者签名。第一次打开：在 Finder 里 **右键 → 打开**，不要双击。若仍被拦，到 **系统设置 → 隐私与安全性** 点「仍要打开」。

以后改完代码：`git push origin main` 更新 Origin，`git push github main` 才会触发 GitHub 重新编译。

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
