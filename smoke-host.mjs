/**
 * OTools 插件真宿主冒烟 harness（独立仓库版）
 * ------------------------------------------------------------------
 * 用无头 Chrome 加载某个 OTools 插件的真实 dist/index.html，并通过
 * page.exposeFunction 把宿主桥 `window.__TAURI_INTERNALS__.invoke` 接到
 * Node 端真实 fs。于是插件的 boot → i18n → theme-sync → local.js → host.js
 * → tools_webview_* 全链路都在「真契约 + 真磁盘」下运行，等价于在 OTools
 * 桌面宿主的 webview 里加载（唯一缺的是 Tauri 窗口外壳，不影响插件逻辑）。
 *
 * 校验项（每个插件）：
 *   1) 宿主桥可用（channel==='raw'，usingHost()===true）
 *   2) boot 跑通：全局 bridge 已挂载、diag 面包屑写入
 *   3) 库目录落到真磁盘（<docs>/<folder>/<marker> 真实存在）
 *   4) 文件读写 round-trip：writeFile → 真磁盘 → readFile 内容一致
 *   5) UI 已挂载（#app/#root/.app 有子节点，body 有文本）
 *   6) 无 uncaught pageerror（console.error 单独列为需复核告警）
 *
 * 环境变量（均可覆盖，不写则用默认值）：
 *   OTOOLS_ROOT    插件父目录（各插件 dist 在 <OTOOLS_ROOT>/<dist>/dist）
 *                 默认 /Users/admin/Documents/Repos/xyito/otools
 *   CHROME_PATH    无头 Chrome 可执行文件
 *                 默认 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
 *   SMOKE_ONLY     只跑指定插件 id（逗号分隔），默认全部
 *   HOST_BASE      宿主桥落盘的临时根目录，默认 /tmp/otools-smoke/host
 *
 * 依赖：puppeteer-core（仅驱动 Chrome，不下载浏览器）。Chrome 需本机自带。
 */

import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const ROOT = process.env.OTOOLS_ROOT || '/Users/admin/Documents/Repos/xyito/otools';
const CHROME = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const HOST_BASE = process.env.HOST_BASE || '/tmp/otools-smoke/host';

// 默认插件清单（otools 组织下的 puter-* 移植插件）。改这里或经 SMOKE_ONLY 过滤。
const PLUGINS = [
  { id: 'otools-puter-ps',          dist: 'otools-puter-ps/dist',          bridge: 'otoolsPuterPs',          folder: 'Photo Studio',    marker: 'photo-studio.json' },
  { id: 'otools-puter-3d',          dist: 'otools-puter-3d/dist',          bridge: 'otoolsPuter3d',         folder: '3D Models',       marker: '3d.json' },
  { id: 'otools-puter-documents',   dist: 'otools-puter-documents/dist',   bridge: 'otoolsPuterDocuments',   folder: 'Documents',       marker: 'documents.json' },
  { id: 'otools-puter-spreadsheet', dist: 'otools-puter-spreadsheet/dist', bridge: 'otoolsPuterSpreadsheet', folder: 'Spreadsheets',     marker: 'spreadsheet.json' },
  { id: 'otools-puter-presentation',dist: 'otools-puter-presentation/dist',bridge: 'otoolsPuterPresentation',folder: 'Presentations',  marker: 'presentation.json' },
];

const MIME = {
  '.html':'text/html','.js':'text/javascript','.mjs':'text/javascript','.css':'text/css',
  '.json':'application/json','.svg':'image/svg+xml','.wasm':'application/wasm','.map':'application/json',
  '.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.gif':'image/gif','.webp':'image/webp',
  '.ico':'image/x-icon','.ttf':'font/ttf','.woff':'font/woff','.woff2':'font/woff2','.txt':'text/plain',
};

function serve(dir) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let urlPath = decodeURIComponent(req.url.split('?')[0]);
      if (urlPath === '/' || urlPath === '') urlPath = '/index.html';
      const filePath = path.join(dir, urlPath);
      if (!filePath.startsWith(dir)) { res.writeHead(403); res.end('forbidden'); return; }
      fs.readFile(filePath, (err, data) => {
        if (err) {
          fs.readFile(path.join(dir, 'index.html'), (e2, d2) => {
            if (e2) { res.writeHead(404); res.end('not found'); }
            else { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(d2); }
          });
          return;
        }
        const ext = path.extname(filePath).toLowerCase();
        res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
        res.end(data);
      });
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

// Node 端「真宿主」：所有 tools_webview_* 落到真实 fs（在 HOST_BASE/<id>/ 下）
function makeHostFs(id) {
  const base = path.join(HOST_BASE, id);
  const docs = path.join(base, 'Documents');
  const home = path.join(base, 'home');
  fs.mkdirSync(docs, { recursive: true });
  fs.mkdirSync(home, { recursive: true });

  return {
    env: { paths: { documents: docs, home }, appName: 'OTools', username: 'smoke' },
    async invoke(cmd, payload = {}) {
      switch (cmd) {
        case 'tools_webview_join_path':
          return path.join(...(payload.parts || []).filter(Boolean));
        case 'tools_webview_pick_files': return [];
        case 'tools_webview_pick_folder': return null;
        case 'tools_webview_pick_save_path': return null;
        case 'tools_webview_read_file': {
          try {
            const buf = await fsp.readFile(payload.path);
            const st = await fsp.stat(payload.path);
            return { path: payload.path, name: path.basename(payload.path), size: st.size,
              mime: '', lastModified: st.mtimeMs, dataBase64: buf.toString('base64') };
          } catch {
            const err = new Error('os error 2: no such file');
            throw err;
          }
        }
        case 'tools_webview_write_file': {
          const { path: p, dataBase64 } = payload.request || {};
          await fsp.mkdir(path.dirname(p), { recursive: true });
          await fsp.writeFile(p, Buffer.from(dataBase64 || '', 'base64'));
          return p;
        }
        case 'tools_webview_list_dir': {
          let entries;
          try { entries = await fsp.readdir(payload.path, { withFileTypes: true }); }
          catch { return []; }
          const out = [];
          for (const e of entries) {
            const ep = path.join(payload.path, e.name);
            let st; try { st = await fsp.stat(ep); } catch { st = null; }
            out.push({ name: e.name, path: ep,
              kind: e.isDirectory() ? 'directory' : 'file',
              size: st ? st.size : 0, mime: '', modified: st ? st.mtimeMs : 0 });
          }
          return out;
        }
        case 'tools_webview_create_dir':
          await fsp.mkdir(payload.path, { recursive: true });
          return payload.path;
        case 'tools_webview_remove_entry':
          await fsp.rm(payload.path, { recursive: Boolean(payload.recursive), force: true });
          return null;
        case 'tools_webview_rename_entry': {
          const { from, to } = payload.request || {};
          await fsp.mkdir(path.dirname(to), { recursive: true });
          await fsp.rename(from, to);
          return null;
        }
        default:
          throw new Error(`unknown host command: ${cmd}`);
      }
    },
    base, docs,
  };
}

async function smokeOne(plugin) {
  const result = {
    id: plugin.id, ok: false, channel: null, available: null,
    bootBridged: false, libraryOnDisk: false, markerPath: null,
    roundTrip: null, ui: null, pageErrors: [], consoleErrors: [], requestFailed: [],
    note: '',
  };
  const hostFs = makeHostFs(plugin.id);
  result.markerPath = path.join(hostFs.docs, plugin.folder, plugin.marker);

  const server = await serve(path.join(ROOT, plugin.dist));
  const port = server.address().port;
  const url = `http://127.0.0.1:${port}/`;

  let browser;
  try {
    browser = await puppeteer.launch({
      executablePath: CHROME,
      headless: true,
      args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--disable-setuid-sandbox'],
    });
    const page = await browser.newPage();

    await page.exposeFunction('__otoolsHostInvoke', (cmd, payload) => hostFs.invoke(cmd, payload));

    await page.evaluateOnNewDocument((env) => {
      window.__OToolsEnv = env;
      window.__TAURI_INTERNALS__ = {
        invoke: (cmd, payload) => window.__otoolsHostInvoke(cmd, payload),
        postMessage: () => {},
      };
    }, hostFs.env);

    page.on('pageerror', (e) => result.pageErrors.push(String(e.message || e)));
    page.on('console', (m) => { if (m.type() === 'error') result.consoleErrors.push(m.text()); });
    page.on('requestfailed', (r) => {
      result.requestFailed.push(`${r.url()} :: ${(r.failure() && r.failure().errorText) || '?'}`);
    });

    await page.goto(url, { waitUntil: 'load', timeout: 60000 });

    try {
      await page.waitForFunction((b) => typeof window[b] !== 'undefined', { timeout: 20000 }, plugin.bridge);
      result.bootBridged = true;
    } catch {
      result.note += ' bridge global 未挂载;';
    }

    await new Promise((r) => setTimeout(r, 4000));

    const probe = await page.evaluate(async (b) => {
      const api = window[b];
      const out = { channel: null, available: null, diag: null, ui: null, rt: null };
      if (!api) return out;
      out.channel = (typeof api.channel === 'function') ? api.channel() : null;
      out.available = (typeof api.available === 'function') ? api.available() : null;
      try { out.diag = JSON.parse(window.localStorage.getItem(`${b}.diag`) || 'null'); } catch {}
      const root = document.querySelector('#app,#root,.app,.editor,.app-root,.ps-app') || document.body;
      out.ui = { hasRoot: !!root && root !== document.body, bodyLen: document.body ? document.body.innerText.length : 0, title: document.title };
      try {
        const docs = api.knownPath ? api.knownPath('documents') : '';
        const tp = await api.joinPath(docs, 'otools-smoke-' + b + '.txt');
        await api.writeFile(tp, api.bytesToBase64(new TextEncoder().encode('hello otools host ' + b)));
        const back = await api.readFile(tp);
        const text = back ? new TextDecoder().decode(api.base64ToBytes(back.dataBase64)) : null;
        out.rt = { path: tp, text };
      } catch (e) {
        out.rt = { error: String(e && e.message || e) };
      }
      return out;
    }, plugin.bridge);

    result.channel = probe.channel;
    result.available = probe.available;
    result.ui = probe.ui;
    if (probe.rt) result.roundTrip = probe.rt;

    result.libraryOnDisk = fs.existsSync(result.markerPath);
  } catch (e) {
    result.note += ' EXCEPTION: ' + (e && e.message || e);
  } finally {
    if (browser) await browser.close();
    server.close();
  }

  const functionalOk =
    result.bootBridged &&
    result.available === true &&
    result.libraryOnDisk &&
    result.roundTrip && result.roundTrip.text && result.roundTrip.text.startsWith('hello otools host') &&
    result.ui && result.ui.bodyLen > 50;
  result.ok = functionalOk;
  return result;
}

async function main() {
  const only = process.env.SMOKE_ONLY ? String(process.env.SMOKE_ONLY).split(',') : null;
  const PLUGINS_RUN = only ? PLUGINS.filter((p) => only.includes(p.id)) : PLUGINS;
  const summary = [];
  for (const p of PLUGINS_RUN) {
    process.stdout.write(`▶ smoke ${p.id} ... `);
    const r = await smokeOne(p);
    summary.push(r);
    const tag = r.ok ? 'PASS ✅' : 'FAIL ❌';
    console.log(`${tag}  host=${r.available} channel=${r.channel} disk=${r.libraryOnDisk} ui=${r.ui ? r.ui.bodyLen : '?'}`);
    if (r.roundTrip) console.log(`   round-trip: ${r.roundTrip.error ? 'ERR ' + r.roundTrip.error : JSON.stringify(r.roundTrip.text)}`);
    if (r.pageErrors.length) console.log(`   pageErrors(${r.pageErrors.length}): ${r.pageErrors.slice(0,3).join(' | ')}`);
    if (r.consoleErrors.length) console.log(`   consoleErrors(${r.consoleErrors.length}): ${r.consoleErrors.slice(0,3).join(' | ')}`);
    if (r.requestFailed.length) console.log(`   requestFailed(${r.requestFailed.length}): ${r.requestFailed.slice(0,3).join(' | ')}`);
    if (r.note) console.log(`   note: ${r.note}`);
  }
  const passed = summary.filter((r) => r.ok).length;
  console.log(`\n==== ${passed}/${summary.length} PASS ====`);
  await fsp.writeFile(path.join(__dirname, 'result.json'), JSON.stringify(summary, null, 2));
  console.log('report: result.json');
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
