import Foundation
import JavaScriptCore

/// YouTube's player script, running in JavaScriptCore with the two functions this module needs
/// exported from inside it.
///
/// Android ran the same script through Rhino (NewPipe) and a hidden WebView (zemer-cipher). iOS
/// has JavaScriptCore built in, but no DOM: the player's top level touches `document`,
/// `navigator` and friends while it sets itself up, and one `ReferenceError` there aborts the
/// whole closure before the exports at its end run. So the context is seeded with permissive
/// stand-ins (`environmentPrelude`) — every property of them exists and every call returns
/// another stand-in — which is enough for the player to finish defining its classes. The
/// cipher code itself is pure string manipulation and never touches them.
///
/// Fragility, stated plainly: this depends on the player still being one
/// `(function(g){…})(_yt_player);` closure, on the stand-ins satisfying whatever the top level
/// touches, and on a correct `PlayerScriptConfig` for the exact player version. Any of those
/// can change with a player rotation (every few days). `StreamCipherSolver` self-tests every
/// runtime it builds and the resolver probes every URL, so a break costs this tier, not
/// playback — the direct-URL clients ahead of it in the catalog are unaffected.
final class PlayerScriptRuntime {
    let hash: String
    let config: PlayerScriptConfig
    private let context: JSContext
    private let sigFunction: JSValue
    private let nFunction: JSValue
    private var lastException: String?

    enum RuntimeError: Error, LocalizedError, Equatable {
        case evaluationFailed(String)
        case exportsMissing
        case selfTestFailed(String)
        case callFailed(String)

        var errorDescription: String? {
            switch self {
            case .evaluationFailed(let detail): return "player script failed to evaluate: \(detail)"
            case .exportsMissing: return "player script did not reach its exports"
            case .selfTestFailed(let detail): return "cipher self-test failed: \(detail)"
            case .callFailed(let detail): return "cipher call failed: \(detail)"
            }
        }
    }

    static let sigExport = "__vibramusic_sig"
    static let nExport = "__vibramusic_n"
    static let closingMarker = "})(_yt_player);"

    /// Builds the runtime and proves it works before anyone relies on it.
    init(hash: String, playerSource: String, config: PlayerScriptConfig) throws {
        guard config.isValidShape else { throw RuntimeError.selfTestFailed("config has an invalid shape") }
        self.hash = hash
        self.config = config
        guard let context = JSContext() else { throw RuntimeError.evaluationFailed("no JSContext") }
        self.context = context
        var captured: String?
        context.exceptionHandler = { _, exception in
            captured = exception?.toString()
        }
        context.evaluateScript(Self.environmentPrelude)
        let source = Self.inject(exportsFor: config, into: playerSource)
        context.evaluateScript(source, withSourceURL: PlayerScriptLocator.scriptURL(hash: hash))
        guard let sig = context.objectForKeyedSubscript(Self.sigExport), let n = context.objectForKeyedSubscript(Self.nExport),
              Self.isFunction(sig, in: context), Self.isFunction(n, in: context)
        else {
            if let captured { throw RuntimeError.evaluationFailed(captured) }
            throw RuntimeError.exportsMissing
        }
        sigFunction = sig
        nFunction = n
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString()
        }
        try selfTest()
    }

    /// The obfuscated `s` value (already URL-decoded) turned into the real signature.
    func decipherSignature(_ scrambled: String) throws -> String {
        lastException = nil
        let result = sigFunction.call(withArguments: [scrambled])
        if let lastException { throw RuntimeError.callFailed(lastException) }
        guard let result, result.isString, let text = result.toString(), !text.isEmpty else {
            throw RuntimeError.callFailed("signature function returned no string")
        }
        return text
    }

    /// The throttling parameter `n` transformed as the player would; the input back unchanged
    /// means the transform did not run.
    func transformN(_ value: String) throws -> String {
        lastException = nil
        let result = nFunction.call(withArguments: [value])
        if let lastException { throw RuntimeError.callFailed(lastException) }
        guard let result, result.isString, let text = result.toString() else {
            throw RuntimeError.callFailed("n transform returned no string")
        }
        return text
    }

    private func selfTest() throws {
        let sigInput = String(repeating: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", count: 2)
        let sig = try decipherSignature(sigInput)
        if sig == sigInput { throw RuntimeError.selfTestFailed("signature function is the identity") }
        let nInput = "KdrqFlzJXl9EcCwlmEy"
        let n = try transformN(nInput)
        if n == nInput || n.count < 5 || n.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil {
            throw RuntimeError.selfTestFailed("n transform returned \(n)")
        }
    }

    private static func isFunction(_ value: JSValue, in context: JSContext) -> Bool {
        guard !value.isUndefined, !value.isNull else { return false }
        return context.evaluateScript("(function(v){return typeof v === 'function';})")?
            .call(withArguments: [value])?.toBool() ?? false
    }

    /// The player source with the exports written in just before its closure ends, where the
    /// obfuscated internal names are in scope.
    static func inject(exportsFor config: PlayerScriptConfig, into source: String) -> String {
        let sig = config.sigExpression.replacingOccurrences(of: "INPUT", with: "s")
        let n = PlayerScriptConfig.nExpression(nClass: config.nClass).replacingOccurrences(of: "INPUT", with: "v")
        let exports = "; \(sigExport) = function(s){ return \(sig); }; \(nExport) = function(v){ return \(n); };"
        if let range = source.range(of: closingMarker, options: .backwards) {
            return source.replacingCharacters(in: range, with: exports + " " + closingMarker)
        }
        // No closing marker: the exports would run outside the closure, where the names don't
        // exist; the self-test turns that into a clear failure.
        return source + "\n" + exports
    }

    /// Stand-ins for the browser globals the player's top level expects. Every property of a
    /// stand-in exists and is itself a stand-in, calling or constructing one returns another,
    /// and timers never fire (nothing here needs them to).
    static let environmentPrelude = #"""
    var __vibramusic_sig, __vibramusic_n;
    (function (global) {
      function stub(name) {
        var target = function () {};
        return new Proxy(target, {
          get: function (t, prop) {
            if (prop === Symbol.toPrimitive) return function () { return ""; };
            if (prop === "toString" || prop === "valueOf") return function () { return ""; };
            if (prop === Symbol.iterator || prop === "then") return undefined;
            if (prop === "length") return 0;
            if (prop in t) return t[prop];
            var child = stub(name + "." + String(prop));
            t[prop] = child;
            return child;
          },
          set: function (t, prop, value) { t[prop] = value; return true; },
          apply: function () { return stub(name + "()"); },
          construct: function () { return stub("new " + name); },
          has: function () { return true; }
        });
      }
      global.window = global;
      global.self = global;
      var names = ["document", "navigator", "location", "localStorage", "sessionStorage", "XMLHttpRequest",
        "screen", "history", "performance", "Image", "HTMLElement", "Element", "Node", "HTMLVideoElement",
        "HTMLMediaElement", "MediaSource", "ManagedMediaSource", "SourceBuffer", "MutationObserver",
        "IntersectionObserver", "ResizeObserver", "CSS", "Event", "CustomEvent", "EventTarget", "indexedDB",
        "caches", "crypto", "matchMedia", "requestAnimationFrame", "cancelAnimationFrame", "getComputedStyle",
        "fetch", "Request", "Response", "Headers", "Blob", "Worker", "trustedTypes", "chrome", "yt", "ytcfg",
        "addEventListener", "removeEventListener", "postMessage", "Audio", "AudioContext", "webkitAudioContext",
        "FileReader", "WebSocket", "DOMParser", "MessageChannel", "BroadcastChannel", "origin", "URL",
        "TextEncoder", "TextDecoder"];
      for (var i = 0; i < names.length; i++) {
        if (typeof global[names[i]] === "undefined") global[names[i]] = stub(names[i]);
      }
      global.setTimeout = function () { return 0; };
      global.clearTimeout = function () {};
      global.setInterval = function () { return 0; };
      global.clearInterval = function () {};
      global.queueMicrotask = function () {};
    })(this);
    """#
}
