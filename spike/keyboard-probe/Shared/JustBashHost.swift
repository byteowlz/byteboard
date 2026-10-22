import Foundation
import JavaScriptCore

/// Hosts just-bash in a bare `JSContext`.
///
/// A `JSContext` gives you `console` and `Promise` and almost nothing else: no
/// event loop, no timers, no Web globals. The prelude below is the contract a
/// just-bash-class bundle needs, and it is the same shape PiDurableKit's
/// codemode worker shims.
///
/// The event loop is implemented in JavaScript and pumped synchronously from
/// Swift. That is deliberate: an app extension has no run loop we should rely
/// on, and a pumped queue is deterministic.
@MainActor
final class JustBashHost {

    private let context: JSContext
    private var didLoad = false
    private(set) var loadError: String?

    init() {
        context = JSContext()!
        context.exceptionHandler = { _, exception in
            if let exception, let text = exception.toString() {
                NSLog("byteboard just-bash: %@", text)
            }
        }
        context.evaluateScript(Self.prelude)
    }

    /// Loads the bundle. Returns the footprint delta in MB, or nil on failure.
    @discardableResult
    func load() -> Double? {
        guard !didLoad else { return 0 }
        let before = physFootprintMB()
        guard let url = Bundle.main.url(forResource: "just-bash-iife", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = "just-bash-iife.js missing from the extension bundle"
            return nil
        }
        context.evaluateScript(source)
        if let exception = context.exception {
            loadError = exception.toString()
            return nil
        }
        guard !(context.objectForKeyedSubscript("JustBash")?.isUndefined ?? true) else {
            loadError = "bundle evaluated but did not define JustBash"
            return nil
        }
        didLoad = true
        let after = physFootprintMB()
        if let before, let after { return after - before }
        return nil
    }

    /// Runs one command and returns a compact JSON result, or an error string.
    func run(_ command: String, timeout: TimeInterval = 10) async -> String {
        if !didLoad { _ = load() }
        if let loadError { return "load failed: \(loadError)" }

        context.evaluateScript("globalThis.__out = \"__PENDING__\";")
        context.evaluateScript("""
        (async () => {
          try {
            const bash = new JustBash.Bash();
            const r = await bash.exec(\(Self.quoted(command)));
            globalThis.__out = JSON.stringify({
              stdout: r.stdout, stderr: r.stderr, code: r.exitCode
            });
          } catch (e) {
            globalThis.__out = "ERROR: " + (e && e.message ? e.message : String(e));
          }
        })();
        """)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = context.objectForKeyedSubscript("__out")?.toString(),
               value != "__PENDING__" {
                return value
            }
            context.evaluateScript("__pump();0")
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return "TIMEOUT after \(Int(timeout))s"
    }

    /// A JSON string literal is a valid JavaScript string literal.
    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    /// Timers, Web globals, and the pump. Everything a bare context lacks.
    private static let prelude = """
    (function () {
      var g = globalThis;

      var timers = [], seq = 1;
      g.setTimeout = function (fn, ms) {
        timers.push({ id: seq, fn: fn, at: Date.now() + (ms || 0), every: null });
        return seq++;
      };
      g.setInterval = function (fn, ms) {
        timers.push({ id: seq, fn: fn, at: Date.now() + (ms || 0), every: ms || 1 });
        return seq++;
      };
      g.clearTimeout = g.clearInterval = function (id) {
        for (var i = 0; i < timers.length; i++) {
          if (timers[i] && timers[i].id === id) timers[i] = null;
        }
      };
      g.__pump = function () {
        var now = Date.now();
        for (var i = 0; i < timers.length; i++) {
          var t = timers[i];
          if (!t || t.at > now) continue;
          if (t.every) { t.at = now + t.every; } else { timers[i] = null; }
          try { t.fn(); } catch (e) {}
        }
      };

      if (typeof g.performance === "undefined") {
        var t0 = Date.now();
        g.performance = {
          timeOrigin: t0,
          now: function () { return Date.now() - t0; },
          mark: function () {}, measure: function () {}
        };
      }
      if (typeof g.TextEncoder === "undefined") {
        g.TextEncoder = function () {};
        g.TextEncoder.prototype.encode = function (s) {
          s = String(s);
          var o = [];
          for (var i = 0; i < s.length; i++) {
            var c = s.charCodeAt(i);
            if (c < 0x80) o.push(c);
            else if (c < 0x800) o.push(0xc0 | c >> 6, 0x80 | c & 63);
            else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
              var c2 = s.charCodeAt(++i);
              var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
              o.push(0xf0 | cp >> 18, 0x80 | cp >> 12 & 63, 0x80 | cp >> 6 & 63, 0x80 | cp & 63);
            } else {
              o.push(0xe0 | c >> 12, 0x80 | c >> 6 & 63, 0x80 | c & 63);
            }
          }
          return new Uint8Array(o);
        };
      }
      if (typeof g.TextDecoder === "undefined") {
        g.TextDecoder = function () {};
        g.TextDecoder.prototype.decode = function (buf) {
          if (!buf) return "";
          var b = buf instanceof Uint8Array ? buf : new Uint8Array(buf.buffer || buf);
          var s = "", i = 0;
          while (i < b.length) {
            var c = b[i++];
            if (c < 0x80) s += String.fromCharCode(c);
            else if (c < 0xe0) s += String.fromCharCode((c & 31) << 6 | b[i++] & 63);
            else if (c < 0xf0) {
              s += String.fromCharCode((c & 15) << 12 | (b[i++] & 63) << 6 | b[i++] & 63);
            } else {
              var cp = ((c & 7) << 18 | (b[i++] & 63) << 12 | (b[i++] & 63) << 6 | (b[i++] & 63)) - 0x10000;
              s += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023));
            }
          }
          return s;
        };
      }
      if (typeof g.crypto === "undefined") {
        g.crypto = {
          getRandomValues: function (a) {
            for (var i = 0; i < a.length; i++) a[i] = (Math.random() * 256) | 0;
            return a;
          },
          randomUUID: function () {
            var a = new Uint8Array(16);
            g.crypto.getRandomValues(a);
            return Array.prototype.map.call(a, function (x) {
              return ("0" + x.toString(16)).slice(-2);
            }).join("");
          }
        };
      }
      if (typeof g.self === "undefined") g.self = g;
      if (typeof g.queueMicrotask === "undefined") {
        g.queueMicrotask = function (fn) { Promise.resolve().then(fn); };
      }
      if (typeof g.structuredClone === "undefined") {
        g.structuredClone = function (v) { return JSON.parse(JSON.stringify(v)); };
      }
    })();
    """
}
