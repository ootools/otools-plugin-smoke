# otools-plugin-smoke

OTools 插件的**真宿主冒烟测试** harness。

用无头 Chrome 加载某个 OTools 插件的真实 `dist/index.html`，并通过
`page.exposeFunction` 把宿主桥 `window.__TAURI_INTERNALS__.invoke` 接到
**Node 端真实 fs**。于是插件的

```
boot → i18n → theme-sync → local.js → host.js → tools_webview_*
```

全链路都在「真契约 + 真磁盘」下运行，等价于在 OTools 桌面宿主的 webview 里加载
（唯一缺的是 Tauri 窗口外壳，不影响插件逻辑）。

## 为什么需要它

插件移植只过构建/打包流水线还不够——必须确认它在宿主里真的能：
- 检测到宿主桥（`channel === 'raw'`、`usingHost() === true`）
- `boot()` 跑通、全局 bridge 挂载
- 库目录**真实落到本机磁盘**（`本地文件优先` 不是空话）
- 文件读写 round-trip 内容一致
- UI 正常挂载

本 harness 把这些一次性自动验证完，输出 PASS/FAIL 报告。

## 依赖

- `puppeteer-core`（只驱动浏览器，不下载）—— `npm install`
- 本机自带 Chrome / Chromium（无头模式只用系统已装的，不另行下载）

## 用法

```bash
npm install

# 默认跑 5 个 puter-* 插件（OTOOLS_ROOT 取默认值）
npm run smoke

# 只跑某个插件
SMOKE_ONLY=otools-puter-ps npm run smoke

# 自定义插件父目录 / Chrome 路径
OTOOLS_ROOT=/path/to/xyito/otools \
CHROME_PATH=/usr/bin/chromium \
npm run smoke
```

## 环境变量

| 变量 | 含义 | 默认 |
|---|---|---|
| `OTOOLS_ROOT` | 插件父目录，各插件 dist 在 `<ROOT>/<dist>/dist` | `/Users/admin/Documents/Repos/xyito/otools` |
| `CHROME_PATH` | 无头 Chrome 可执行文件 | `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` |
| `SMOKE_ONLY` | 只跑指定插件 id（逗号分隔） | 全部 |
| `HOST_BASE` | 宿主桥落盘的临时根目录 | `/tmp/otools-smoke/host` |

## 插件清单

默认清单在 `smoke-host.mjs` 顶部的 `PLUGINS` 数组（otools 组织下的 5 个
puter-* 移植插件）。要测别的插件，改这个数组或加一项即可：

```js
{ id: 'otools-puter-ps', dist: 'otools-puter-ps/dist',
  bridge: 'otoolsPuterPs', folder: 'Photo Studio', marker: 'photo-studio.json' }
```

- `bridge`：插件在 `window` 上挂的宿主桥全局名（见各插件 `shell/src/otools/app.js` 的 `bridge` 字段）
- `folder`：本机默认库目录名
- `marker`：库目录标记文件名

## 结果

- 终端逐插件打印 PASS/FAIL、host/channel/disk/ui、round-trip 文本、console/page 错误。
- `result.json` 落盘结构化报告。

## 已知限制（非插件缺陷）

- 无头环境**无 GPU**：ps 的 WebGPU/WebGL2、3d 的 WebGL 视口会报上下文创建失败。
  这只影响像素级渲染的可视验证，应用外壳仍能 boot/挂载/文件链路通；真桌面有 GPU 即正常。
- `requestfailed` 偶发的 `ERR_CONNECTION_CLOSED` 多为 harness 关闭浏览器时的竞态噪声，可重跑确认。

## WKWebView 探针（macOS 专用）

上面的 Chrome harness 有个**盲区**：Chrome 99+ 实现了全套 Canvas 文本样式
属性，而 **macOS 上的 Tauri 用的不是 Chrome，是 WKWebView**。凡是只在
WebKit 上才缺的能力，Chrome harness 一辈子测不出来。

实测结论（本机 macOS 27 / Safari 27）：

| 属性 | WKWebView | Chrome 99+ |
|---|---|---|
| `CanvasRenderingContext2D.fontKerning` | **缺** | 有 |
| `CanvasRenderingContext2D.letterSpacing` | 有（18.4+） | 有 |
| `CanvasRenderingContext2D.wordSpacing` | 有（18.4+） | 有 |
| `CanvasRenderingContext2D.textRendering` | 缺 | 有（116+） |

`fontKerning` 缺失曾让 documents 插件在 macOS 上**完全打不开文档**——上游
`setCanvasTextStyle` 把它当硬前提，缺失即抛错。修法见该仓库的
`shell/src/otools/canvas-text-support.js`。

```bash
# 能力探针：只回答「WKWebView 到底缺什么」
swiftc -O wk-probe.swift -o wk-probe && ./wk-probe

# 端到端：加载真实 dist，跑 boot → 上游守卫 → 绘制落墨
swiftc -O wk-doc-smoke.swift -o wk-doc-smoke && ./wk-doc-smoke

# 换插件：指定 dist 目录
DIST=/path/to/otools-puter-documents/dist ./wk-doc-smoke
```

### 写这类探针时踩过的三个坑

记在这里是因为它们都会**制造假象**，让人以为 bug 修好了或没修好：

1. **别用 `file://` 加载。** 产物入口是 `<script type="module" crossorigin>`，
   ES module 在 `file://` 下被 CORS 拒绝执行——`boot()` 根本不跑，UI 却是空的。
   生产环境走 `otools-plugin://` 自定义 scheme，没这个限制，所以探针里用
   进程内的 `NWListener` 起 http 更接近真实情况。

2. **`didFinishNavigation` 不等于模块执行完。** 模块求值是异步的；在
   `didFinish` 里同步读 `fontKerning in ctx` 会读到「boot 还没跑」的中间态，
   得出「补丁没生效」的错误结论。**先 `await` 一个 setTimeout 再断言。**
   （这个坑真实发生过：同一份数据里前后两个时点结论相反。）

3. **`evaluateJavaScript` 只吃单个表达式**，不接受 `Promise`、不接受
   `let/var` 多语句。做法是 IIFE 包一层，把结果 `JSON.stringify` 后落到
   `window.__xxx`，再轮询取字符串。

### 对照实验才是证据

改完别只跑一次「全绿」就收工。把补丁注释掉重跑一遍，确认能**复现原故障**
（`fatalVisible: true` + 界面出现那句报错），再打开补丁确认恢复——只有这样
才能证明补丁是唯一变量，而不是别的改动碰巧掩盖了问题。

