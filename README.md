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
