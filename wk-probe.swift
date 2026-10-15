// WKWebView 能力探针：在**真实的 macOS WKWebView** 里读 Canvas 文本样式属性，
// 并验证移植层的补丁（`shell/src/otools/canvas-text-support.js`）装上之后，
// 上游 `setCanvasTextStyle` 的守卫是否全部放行。
//
// 为什么不用 Chrome 测：Chrome 99+ 全都支持，测了等于没测。macOS 上的
// Tauri 用的就是 WKWebView，只有它能复现插件真机上的情况。
//
// 用法：swiftc -O wk-probe.swift -o wk-probe && ./wk-probe
import WebKit
import Foundation

// 上游 setCanvasTextStyle 的三条守卫，原样复现；并在装/不装补丁两种状态下各跑一遍。
let probe = """
(() => {
  const ctx = document.createElement('canvas').getContext('2d');
  if (!ctx) return { error: 'no 2d context' };

  const run = () => {
    const seen = {};
    try {
      if (!('fontKerning' in ctx)) throw new Error('This browser cannot control font kerning. Open the document in a browser with Canvas font-kerning support.');
      ctx.fontKerning = 'none';
      seen.fontKerning = ctx.fontKerning;
      if ('letterSpacing' in ctx) ctx.letterSpacing = '2.6667px';
      else if (1) throw new Error('This browser cannot display character spacing.');
      if ('wordSpacing' in ctx) ctx.wordSpacing = '4px';
      else if (1) throw new Error('This browser cannot display justified text.');
      return { ok: true, seen };
    } catch (e) { return { ok: false, error: e.message }; }
  };

  const before = run();
  // 装补丁
  (function () {
    const INITIAL = { fontKerning: 'normal', letterSpacing: '0px', wordSpacing: '0px' };
    const proto = CanvasRenderingContext2D.prototype;
    for (const name of Object.keys(INITIAL)) {
      if (name in proto) continue;
      Object.defineProperty(proto, name, { configurable: true, enumerable: false, get: () => INITIAL[name], set: () => {} });
    }
  })();
  const after = run();

  const present = {};
  for (const k of ['fontKerning', 'letterSpacing', 'wordSpacing', 'textRendering']) present[k] = k in ctx;
  return { ua: navigator.userAgent, present, before, after };
})()
"""

final class Delegate: NSObject, WKNavigationDelegate {
  let done = DispatchSemaphore(value: 0)
  var result = ""
  var failure: Error?

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.evaluateJavaScript(probe) { value, error in
      if let error { self.failure = error }
      else if let dict = value as? [String: Any], let json = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: json, encoding: .utf8) {
        self.result = s
      } else {
        self.result = "unexpected: \(String(describing: value))"
      }
      self.done.signal()
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failure = error; done.signal()
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    failure = error; done.signal()
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
let delegate = Delegate()
webView.navigationDelegate = delegate
webView.loadHTMLString("<html><body></body></html>", baseURL: nil)

DispatchQueue.global().asyncAfter(deadline: .now() + 25) { delegate.done.signal() }
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
  if delegate.done.wait(timeout: .now()) == .success { timer.invalidate() }
}
RunLoop.main.run(until: Date().addingTimeInterval(30))

if delegate.result.isEmpty {
  if let failure = delegate.failure { print("ERROR: \(failure)") } else { print("TIMEOUT") }
  exit(2)
}
print(delegate.result)
