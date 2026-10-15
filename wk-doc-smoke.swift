// 文档打开冒烟：在**真实 WKWebView** 里加载 otools-puter-documents 的构建产物，
// 走完 boot → 打开文档 → 排版绘制，确认不再撞上 fontKerning 守卫。
//
// 为什么必须是 WKWebView：macOS 上 Tauri 用的就是它，而它是唯一不实现
// `CanvasRenderingContext2D.fontKerning` 的引擎（Chrome 99+ / Firefox 104+ 都有）。
// 拿 Chrome 测这个问题等于没测。
//
// 用法：
//   swiftc -O wk-doc-smoke.swift -o wk-doc-smoke
//   DIST=/path/to/otools-puter-documents/dist ./wk-doc-smoke
import WebKit
import Network
import Foundation

let dist = ProcessInfo.processInfo.environment["DIST"]
  ?? "/Users/admin/Documents/Repos/xyito/otools/otools-puter-documents/dist"
let distURL = URL(fileURLWithPath: dist)
guard FileManager.default.fileExists(atPath: distURL.appendingPathComponent("index.html").path) else {
  print("ERROR: 找不到 \(dist)/index.html，先跑 node scripts/build.mjs")
  exit(2)
}

// 进程内起一个静态服务器。不用 file:// ：产物的入口是
// `<script type="module" crossorigin>`，ES module 在 file:// 下会被 CORS
// 拒绝执行（boot 根本不跑，测出来的是假象）。生产环境由宿主用
// otools-plugin:// 自定义 scheme 提供，同样没有 file:// 的限制，
// 所以 http:// 更接近真实情况。
final class StaticServer {
  private let listener: NWListener
  /// start() 之后才有值：NWListener 传 .any 时端口由内核分配，
  /// 在 start 之前读 `listener.port` 会拿到 0。
  private(set) var port: UInt16 = 0

  init?(root: URL) {
    guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
    self.listener = listener

    listener.newConnectionHandler = { conn in
      conn.start(queue: .global(qos: .userInitiated))
      conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        guard let data, let req = String(data: data, encoding: .utf8) else {
          conn.cancel(); return
        }
        let path = req.split(separator: " ")[1].split(separator: "?")[0]
        let rel = String(path) == "/" ? "index.html" : String(path).dropFirst()
        let file = root.appendingPathComponent(String(rel))
        guard let body = try? Data(contentsOf: file) else {
          conn.send(content: nil, completion: .contentProcessed { _ in conn.cancel() })
          return
        }
        let type: String = {
          switch file.pathExtension {
          case "html": return "text/html; charset=utf-8"
          case "js", "mjs": return "text/javascript; charset=utf-8"
          case "css": return "text/css; charset=utf-8"
          case "json": return "application/json; charset=utf-8"
          case "svg": return "image/svg+xml"
          case "ttf": return "font/ttf"
          case "woff2": return "font/woff2"
          case "png": return "image/png"
          case "ico": return "image/x-icon"
          default: return "application/octet-stream"
          }
        }()
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
      }
    }
  }

  func start() {
    listener.start(queue: .global())
    // 等内核把端口分配下来（start 是异步的，通常瞬间就好）
    for _ in 0..<50 {
      if let p = listener.port?.rawValue, p != 0 { port = p; return }
      Thread.sleep(forTimeInterval: 0.02)
    }
  }
}

// WKWebView 不能直接读 file:// 下的模块脚本（跨源限制），所以用
// loadFileURL 显式授权，允许读同目录下的相对路径资源。
// WKWebView 的 evaluateJavaScript 不接受 Promise，也拿不到「对象里套对象」
// 这种结构（Swift 侧只认得住 NSNumber/NSString/NSArray 这些）。所以这里让
// JS 自己跑完再 JSON.stringify 成字符串返回。
let probe = """
(async () => {
  const out = { steps: [] };
  const step = (name, ok, extra) => out.steps.push({ name, ok, ...(extra ? { extra } : {}) });

  // 先等 boot 跑完。入口是 type=module，模块求值是异步的：
  // didFinish 只保证 HTML 解析完，不保证模块执行完。同步读会读到
  // 「boot 还没跑」的中间态，测出来的失败是假的。
  await new Promise(r => setTimeout(r, 3000));

  // 1) 补丁装了吗——必须在等待之后读
  const ctx = document.createElement('canvas').getContext('2d');
  out.nativeFontKerning = 'fontKerning' in CanvasRenderingContext2D.prototype;
  out.fontKerningInContext = ctx ? ('fontKerning' in ctx) : null;
  step('canvas-context', !!ctx);
  step('boot-installed-canvas-patch', out.nativeFontKerning);

  // 2) 上游的守卫（setCanvasTextStyle 原样复现）
  try {
    if (!('fontKerning' in ctx)) throw new Error('This browser cannot control font kerning. Open the document in a browser with Canvas font-kerning support.');
    ctx.fontKerning = 'none';
    step('upstream-kerning-guard', true, { readback: ctx.fontKerning });
  } catch (e) { step('upstream-kerning-guard', false, { error: e.message }); }

  // 3) 宿主桥 / boot 的痕迹
  out.bridge = typeof window.otoolsPuterDocuments;
  step('host-bridge', typeof window.otoolsPuterDocuments === 'object' && window.otoolsPuterDocuments !== null);
  out.bootMarker = {
    dataset: document.documentElement.dataset.otoolsPlugin || null,
    htmlLang: document.documentElement.lang,
  };

  // 4) UI 挂载 + 文本可见
  const app = document.getElementById('app') || document.getElementById('root');
  out.uiChildren = app ? app.children.length : 0;
  out.bodyText = (document.body.innerText || '').slice(0, 300);
  step('ui-mounted', out.uiChildren > 0);

  // 4b) 页面级 JS 错误
  out.jsErrors = (window.__smokeErrors || []).slice(0, 8);
  out.readyState = document.readyState;
  step('no-js-errors', out.jsErrors.length === 0);

  // 5) 页面级错误文案
  out.fatalVisible = /cannot control font kerning|Canvas font-kerning support/i.test(document.body.innerText || '');
  step('no-fatal-banner', !out.fatalVisible);

  // 6) 真的画一页：测量 + 落墨
  try {
    const c = document.createElement('canvas');
    c.width = 400; c.height = 80;
    const g = c.getContext('2d');
    g.font = '24px "Noto Sans", sans-serif';
    if (!('fontKerning' in g)) throw new Error('guard');
    g.fontKerning = 'none';
    const w = g.measureText('Hello 文稿 W').width;
    g.fillStyle = '#000'; g.fillText('Hello 文稿 W', 10, 45);
    const px = g.getImageData(0, 0, 400, 80).data;
    let ink = 0;
    for (let i = 3; i < px.length; i += 4) if (px[i] > 0) ink++;
    out.measureWidth = w;
    out.inkedPixels = ink;
    step('paints-text', ink > 100 && w > 0, { ink, width: w });
  } catch (e) { step('paints-text', false, { error: String(e.message || e) }); }

  return JSON.stringify(out);
})()
"""

final class Delegate: NSObject, WKNavigationDelegate {
  let done = DispatchSemaphore(value: 0)
  var result = ""
  var failure: Error?
  private var waited = 0

  /// 轮询等 Promise 落地。写成方法而不是递归闭包：Swift 不允许在声明处
  /// 自引用局部闭包。
  private func pollResult(_ webView: WKWebView) {
    webView.evaluateJavaScript("window.__smoke || ''") { [weak self] value, _ in
      guard let self else { return }
      let s = (value as? String) ?? ""
      if !s.isEmpty { self.result = s; self.done.signal(); return }
      self.waited += 1
      if self.waited > 300 {
        self.failure = NSError(domain: "smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "poll timeout"])
        self.done.signal()
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.pollResult(webView) }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // 触发探针：把 Promise 的结果落到 window.__smoke，再轮询取字符串。
    // evaluateJavaScript 只接受**一个**表达式，所以整个 kick 写成 IIFE。
    let kick = """
    (function(){ var __r = \(probe);
      if (__r && typeof __r.then === 'function') {
        __r.then(function(s){ window.__smoke = String(s); },
                 function(e){ window.__smoke = 'ERR:' + (e && e.message || e); });
      } else { window.__smoke = String(__r); }
      return true; })()
    """
    webView.evaluateJavaScript(kick) { [weak self] value, error in
      guard let self else { return }
      if let error {
        // kick 本身失败：把 JS 侧的真实错误带出来，别只报 WKErrorDomain 5
        self.failure = NSError(domain: "kick", code: 1, userInfo: [
          NSLocalizedDescriptionKey: "kick failed: \(error.localizedDescription) (value=\(String(describing: value)))"
        ])
        self.done.signal()
        return
      }
      self.pollResult(webView)
    }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    failure = error; done.signal()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failure = error; done.signal()
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let server = StaticServer(root: distURL) else {
  print("ERROR: 静态服务器起不来")
  exit(2)
}
server.start()
guard server.port != 0 else {
  print("ERROR: 静态服务器没拿到端口")
  exit(2)
}
let entryURL = URL(string: "http://127.0.0.1:\(server.port)/index.html")!

let config = WKWebViewConfiguration()
let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
let delegate = Delegate()
webView.navigationDelegate = delegate
// 挂一个假的宿主桥：只给 boot 一个能用的 invoke，其余能力照常缺失。
// 目的是让 boot 走完真实的 local.js 判定路径，而不是因为宿主不存在就短路。
let bridge = """
(function () {
  window.__smokeErrors = [];
  window.addEventListener('error', function (e) {
    window.__smokeErrors.push('error: ' + (e.message || '') + ' @ ' + (e.filename || '') + ':' + (e.lineno || 0));
  }, true);
  window.addEventListener('unhandledrejection', function (e) {
    var r = e.reason;
    window.__smokeErrors.push('unhandledrejection: ' + ((r && r.message) || r));
  });
  window.__TAURI_INTERNALS__ = { invoke: function (cmd, args) {
    return Promise.resolve({ ok: true, cmd: cmd, args: args || null });
  } };
})();
"""
webView.configuration.userContentController.addUserScript(
  WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
)
webView.load(URLRequest(url: entryURL))
DispatchQueue.global().asyncAfter(deadline: .now() + 60) { delegate.done.signal() }
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
  if delegate.done.wait(timeout: .now()) == .success { timer.invalidate() }
}
RunLoop.main.run(until: Date().addingTimeInterval(75))

if delegate.result.isEmpty {
  if let failure = delegate.failure { print("ERROR: \(failure)") } else { print("TIMEOUT") }
  exit(2)
}
print(delegate.result)
