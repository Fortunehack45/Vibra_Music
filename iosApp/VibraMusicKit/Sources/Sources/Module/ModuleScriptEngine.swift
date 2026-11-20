import Foundation
import JavaScriptCore
import VibraMusicCore

// Ports data/sources/module/QuickJsExecutor.kt with JavaScriptCore in place of QuickJS (PORTING §4).
//
// Differences from Android, all deliberate:
// - Arguments reach the module as real JS values. Android spliced them into source text
//   (`"\"$query\""`), so a query containing a quote broke the call.
// - QuickJS's `evaluate` drained the job queue synchronously; JSC resolves promises
//   asynchronously, so a call attaches `then` handlers and resumes a Swift continuation.
// - A module written as ES exports (`export async function searchTracks`) has its top-level
//   functions picked up when it never assigns `module.exports`. Android's wrapper returned `{}` for
//   those; this is a strict superset.
// - Each source's manager owns its own engine pool, rather than one process-wide pool that any
//   source's edit could empty.

/// One JavaScript interpreter with a module's script evaluated into it. Used by one caller at a
/// time (see ``ModuleScriptPool``): a call parks state in the VM between its start and its answer,
/// and modules keep session state in top-level variables that must survive from search to stream.
final class ModuleScriptEngine: @unchecked Sendable {
    private let context: JSContext
    private let lastError = LockedBox<String?>(nil)

    /// Evaluates the polyfills and `jsCode`; throws when the module's own initialisation throws.
    init(jsCode: String, fetchBase: String, session: URLSession) throws {
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            throw ModuleScriptError.engine("could not create a JavaScript context")
        }
        self.context = context
        let lastError = lastError
        context.exceptionHandler = { _, exception in
            lastError.value = exception?.toString()
        }
        Self.bindConsole(context)
        Self.bindNative(context, fetchBase: fetchBase, session: session)
        context.evaluateScript(Self.webShims)
        context.evaluateScript(Self.polyfills)
        if let failure = lastError.take() { throw ModuleScriptError.engine("polyfills failed: \(failure)") }

        let code = Self.preprocess(jsCode)
        context.evaluateScript("""
        var __spine_iife_error = null;
        var __spine_mod = (function() {
            try {
                var module = { exports: {} };
                var exports = module.exports;
                var self = {};
                \(code)
                ;
                if (module.exports && (module.exports.searchTracks || module.exports.getTrackStreamUrl)) {
                    return module.exports;
                }
                var found = {};
                if (typeof searchTracks === 'function') found.searchTracks = searchTracks;
                if (typeof getTrackStreamUrl === 'function') found.getTrackStreamUrl = getTrackStreamUrl;
                return found;
            } catch (e) {
                __spine_iife_error = e && e.message ? e.message : String(e);
                return {};
            }
        })();
        """)
        if let failure = lastError.take() { throw ModuleScriptError.engine("Module init error: \(failure)") }
        if let initError = context.objectForKeyedSubscript("__spine_iife_error"), !initError.isNull, !initError.isUndefined {
            throw ModuleScriptError.engine("Module init error: \(initError.toString() ?? "unknown")")
        }
        let keys = context.evaluateScript("Object.keys(__spine_mod).join(', ')")?.toString() ?? ""
        SourcesLog.d("  Module exports: [\(keys)]")
    }

    /// Calls `functionName` on the module's exports with `arguments` (JSON-encodable values) and
    /// returns its answer as a JSON string — a string answer verbatim, anything else stringified, a
    /// thrown error as `{"error": "…"}`, as Android did.
    func call(_ functionName: String, argumentsJSON: String, timeout: TimeInterval) async -> Result<String, Error> {
        let kind = context.evaluateScript("typeof __spine_mod[\(Self.jsString(functionName))]")?.toString()
        guard kind == "function" else {
            return .failure(ModuleScriptError.missingExport(functionName))
        }

        let gate = ResumeOnce<Result<String, Error>>()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            gate.resume(with: .failure(ModuleScriptError.timedOut(functionName)))
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let resolved: @convention(block) (JSValue?) -> Void = { value in
                gate.resume(with: .success(value?.toString() ?? "null"))
            }
            let rejected: @convention(block) (JSValue?) -> Void = { value in
                gate.resume(with: .failure(ModuleScriptError.engine(value?.toString() ?? "rejected")))
            }
            let invoke = context.objectForKeyedSubscript("__spine_invoke")
            let promise = invoke?.call(withArguments: [functionName, argumentsJSON])
            if let failure = lastError.take() {
                gate.resume(with: .failure(ModuleScriptError.engine(failure)))
                return
            }
            _ = promise?.invokeMethod("then", withArguments: [
                JSValue(object: resolved, in: context) as Any,
                JSValue(object: rejected, in: context) as Any,
            ])
        }
    }

    // MARK: Bindings

    private static func bindConsole(_ context: JSContext) {
        let console = JSValue(newObjectIn: context)
        func line(_ prefix: String, _ log: @escaping (String) -> Void) -> @convention(block) () -> Void {
            return {
                let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "null" }
                log("\(prefix)\(parts.joined(separator: " "))")
            }
        }
        console?.setObject(line("[JS] ", { SourcesLog.d($0) }), forKeyedSubscript: "log" as NSString)
        console?.setObject(line("[JS-INFO] ", { SourcesLog.d($0) }), forKeyedSubscript: "info" as NSString)
        console?.setObject(line("[JS-WARN] ", { SourcesLog.w($0) }), forKeyedSubscript: "warn" as NSString)
        console?.setObject(line("[JS-ERR] ", { SourcesLog.e($0) }), forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    /// `__spine.fetch(url, method, headersJson, body)` → Promise of `{"status","ok","body"}` JSON,
    /// and `__spine.setTimeout(_, ms)` → Promise resolved after `ms`. The web-shaped `fetch()` and
    /// `setTimeout()` in ``webShims`` sit on top, as on Android.
    private static func bindNative(_ context: JSContext, fetchBase: String, session: URLSession) {
        let native = JSValue(newObjectIn: context)
        let fetch: @convention(block) (JSValue?, JSValue?, JSValue?, JSValue?) -> JSValue? = { url, method, headers, body in
            guard let context = JSContext.current() else { return nil }
            let rawURL = url.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() } ?? ""
            let methodName = method.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() } ?? "GET"
            let headersJSON = headers.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() } ?? "{}"
            let bodyText = body.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() }
            return JSValue(newPromiseIn: context) { resolve, reject in
                guard !rawURL.isEmpty else {
                    reject?.call(withArguments: [JSValue(newErrorFromMessage: "fetch requires a URL", in: context) as Any])
                    return
                }
                let target = resolveURL(rawURL, base: fetchBase)
                Task {
                    do {
                        let (status, text) = try await perform(target, method: methodName, headersJSON: headersJSON, body: bodyText, session: session)
                        let payload: [String: Any] = ["status": status, "ok": (200...299).contains(status), "body": text]
                        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                        resolve?.call(withArguments: [json])
                    } catch {
                        reject?.call(withArguments: [JSValue(newErrorFromMessage: error.localizedDescription, in: context) as Any])
                    }
                }
            }
        }
        let sleep: @convention(block) (JSValue?, JSValue?) -> JSValue? = { _, milliseconds in
            guard let context = JSContext.current() else { return nil }
            let delay = max(0, milliseconds?.toDouble() ?? 0)
            return JSValue(newPromiseIn: context) { resolve, _ in
                // A delay past a day fires at once, as a browser's does past its own cap. The delay
                // is the module's own number: sleeping it out would hold the context for a day, and
                // one past about 1.8e13 ms overflowed UInt64 nanoseconds, which traps.
                let nanoseconds = delay.isFinite && delay <= 86_400_000 ? UInt64(delay * 1_000_000) : 0
                Task {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    resolve?.call(withArguments: ["0"])
                }
            }
        }
        native?.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
        native?.setObject(sleep, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(native, forKeyedSubscript: "__spine" as NSString)
    }

    private static func perform(
        _ url: String,
        method: String,
        headersJSON: String,
        body: String?,
        session: URLSession
    ) async throws -> (Int, String) {
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        SourcesLog.d("  → fetch \(method) \(ModuleManager.redact(url))")
        var request = URLRequest(url: target)
        request.httpMethod = method.uppercased()
        request.timeoutInterval = 20
        var hasUserAgent = false
        var hasContentType = false
        if let headers = (try? JSONSerialization.jsonObject(with: Data(headersJSON.utf8))) as? [String: Any] {
            for (name, value) in headers {
                request.setValue("\(value)", forHTTPHeaderField: name)
                if name.lowercased() == "user-agent" { hasUserAgent = true }
                if name.lowercased() == "content-type" { hasContentType = true }
            }
        }
        if !hasUserAgent { request.setValue(VibraMusicHTTP.UserAgent.chromeDesktop, forHTTPHeaderField: "User-Agent") }
        if ["POST", "PUT"].contains(request.httpMethod ?? "") {
            request.httpBody = Data((body ?? "").utf8)
            if !hasContentType { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let text = String(decoding: data, as: UTF8.self)
        SourcesLog.d("    HTTP \(status) (\(data.count) bytes)")
        return (status, text)
    }

    /// A module fetch URL made absolute against the directory its script was downloaded from.
    static func resolveURL(_ url: String, base: String) -> String {
        if url.hasPrefix("http://") || url.hasPrefix("https://") || base.isEmpty { return url }
        if url.hasPrefix("/") {
            let scheme = base.before("://")
            let host = base.components(separatedBy: "://").dropFirst().first?.before("/") ?? ""
            return "\(scheme)://\(host)\(url)"
        }
        return "\(base)/\(url)"
    }

    // MARK: Source preprocessing

    /// Strips ES-module `export` keywords so the code runs inside the CommonJS-style wrapper, and
    /// unwraps the template-literal format some indexes publish (`export const x = \`…JS…\``).
    static func preprocess(_ jsCode: String) -> String {
        let code = jsCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = Pattern(#"^export\s+const\s+\w+\s*=\s*`"#).firstMatch(in: code),
           let range = Range(match.range, in: code) {
            var index = range.upperBound
            while index < code.endIndex {
                if code[index] == "\\" {
                    index = code.index(after: index)
                    if index < code.endIndex { index = code.index(after: index) }
                    continue
                }
                if code[index] == "`" {
                    return String(code[range.upperBound..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                index = code.index(after: index)
            }
            SourcesLog.w("  Template literal not closed, falling through to regex preprocess")
        }
        var result = code
        result = Pattern(#"\bexport\s+default\s+(?=function|class|const|let|var|async)"#).replacing(in: result, with: "")
        result = Pattern(#"\bexport\s+(const|let|var|function|class|async)\b"#).replacing(in: result, with: "$1")
        result = Pattern(#"\bexport\s*\{[^}]*\}\s*;?"#).replacing(in: result, with: "")
        return result
    }

    private static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    // MARK: Scripts

    /// The web-shaped surface over the native bindings, and the call trampoline.
    private static let webShims = """
    var fetch = async function(url, options) {
        var method = 'GET';
        var headers = '{}';
        var body = null;
        if (options) {
            method = options.method || 'GET';
            if (options.headers) {
                if (typeof options.headers === 'string') {
                    headers = options.headers;
                } else {
                    try { headers = JSON.stringify(options.headers); } catch (e) { headers = '{}'; }
                }
            }
            if (options.body !== undefined && options.body !== null) {
                body = typeof options.body === 'string' ? options.body : JSON.stringify(options.body);
            }
            if (options.signal && options.signal.aborted) {
                throw new Error('Aborted');
            }
        }
        var raw = JSON.parse(await __spine.fetch(String(url), method, headers, body));
        var respBody = raw.body;
        return {
            ok: raw.ok,
            status: raw.status,
            statusText: raw.ok ? 'OK' : 'Error',
            json: function() { try { return JSON.parse(respBody); } catch (e) { throw new Error('Invalid JSON: ' + respBody.substring(0, 200)); } },
            text: function() { return respBody; },
            arrayBuffer: function() { throw new Error('Not implemented'); },
            clone: function() { return this; },
            headers: { get: function(k) { return null; } }
        };
    };
    var setTimeout = async function(fn, ms) {
        await __spine.setTimeout(null, ms || 0);
        if (typeof fn === 'function') fn();
        return 0;
    };
    var clearTimeout = function(id) {};
    var __spine_invoke = async function(name, argsJson) {
        var fn = __spine_mod[name];
        if (!fn) { return JSON.stringify({ error: name + ' not found' }); }
        try {
            var r = await fn.apply(__spine_mod, JSON.parse(argsJson));
            return typeof r === 'string' ? r : JSON.stringify(r);
        } catch (e) {
            return JSON.stringify({ error: e && e.message ? e.message : String(e) });
        }
    };
    """

    /// The same polyfills Android evaluated into QuickJS; JavaScriptCore already has most of them,
    /// and each is guarded.
    private static let polyfills = #"""
    if (typeof AbortController === 'undefined') {
        var AbortController = function() { this.signal = { aborted: false }; };
        AbortController.prototype.abort = function() { this.signal.aborted = true; };
    }
    if (typeof Promise.any !== 'function') {
        Promise.any = function(promises) {
            return new Promise(function(resolve, reject) {
                var errors = [];
                var remaining = promises.length;
                if (remaining === 0) { reject(new Error('All promises were rejected')); return; }
                promises.forEach(function(p, i) {
                    Promise.resolve(p).then(resolve, function(e) {
                        errors[i] = e;
                        remaining--;
                        if (remaining === 0) reject(new Error('All promises were rejected'));
                    });
                });
            });
        };
    }
    if (typeof Promise.allSettled !== 'function') {
        Promise.allSettled = function(promises) {
            return Promise.all(promises.map(function(p) {
                return Promise.resolve(p).then(
                    function(value) { return { status: 'fulfilled', value: value }; },
                    function(reason) { return { status: 'rejected', reason: reason }; }
                );
            }));
        };
    }
    if (typeof atob === 'undefined') {
        var atob = function(input) {
            var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
            var str = String(input).replace(/=+$/, '');
            var output = '';
            for (var bc = 0, bs, buffer, idx = 0; buffer = str.charAt(idx++); ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
                buffer = chars.indexOf(buffer);
            }
            return output;
        };
    }
    if (typeof btoa === 'undefined') {
        var btoa = function(input) {
            var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
            var str = String(input), output = '';
            for (var block, charCode, idx = 0, map = chars; str.charAt(idx | 0) || (map = '=', idx % 1); output += map.charAt(63 & block >> 8 - idx % 1 * 8)) {
                charCode = str.charCodeAt(idx += 3/4);
                block = block << 8 | charCode;
            }
            return output;
        };
    }
    if (typeof URL === 'undefined') {
        var URL = function(url, base) {
            this.href = url;
            try {
                var a = url.replace(/^[^:]+:/, 'http:');
                var match = a.match(/^\/\/([^/]+)(\/.*)?$/);
                if (match) {
                    this.hostname = match[1];
                    this.pathname = match[2] || '/';
                } else {
                    var m2 = a.match(/^https?:\/\/([^/]+)(\/.*)?$/);
                    if (m2) { this.hostname = m2[1]; this.pathname = m2[2] || '/'; }
                }
            } catch (e) {}
        };
    }
    """#
}

enum ModuleScriptError: LocalizedError {
    case engine(String)
    case missingExport(String)
    case notLoaded(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .engine(let detail): return detail
        case .missingExport(let name): return "\(name) is not a function on this module"
        case .notLoaded(let id): return "Module \(id) is not loaded"
        case .timedOut(let name): return "\(name) did not answer in time"
        }
    }
}

/// A value behind a lock.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension LockedBox {
    /// The current value, replaced with nil.
    func take<Wrapped>() -> Wrapped? where Value == Wrapped? {
        lock.withLock {
            let current = stored
            stored = nil
            return current
        }
    }
}

/// Up to ``maxModules`` modules' engines, up to ``enginesPerModule`` each.
///
/// Why a module gets several interpreters: one engine is strictly one call at a time, and a
/// module's own HTTP fetches hold it for their whole duration (7.7 s measured on Android), so
/// concurrent downloads would queue behind each other on the one slow module. The pool grows lazily:
/// an uncontended module costs exactly one engine. LRU-capped so a whole index stays resident — a
/// cap below the index size evicts engines the same search is still using.
actor ModuleScriptPool {
    static let maxModules = 12
    static let enginesPerModule = 3

    private struct Pool {
        let jsCode: String
        let fetchBase: String
        var free: [ModuleScriptEngine] = []
        var started = 0
        var waiters: [CheckedContinuation<ModuleScriptEngine?, Never>] = []
    }

    private let session: URLSession
    private var pools: [String: Pool] = [:]
    private var order: [String] = []

    init(session: URLSession) {
        self.session = session
    }

    func isLoaded(_ moduleId: String) -> Bool { pools[moduleId] != nil }

    /// Evaluates `jsCode` into a first engine for `moduleId`, evicting the least recently used
    /// module past the cap. A module already loaded is a hit.
    func load(_ moduleId: String, jsCode: String, fetchBase: String) async throws {
        if pools[moduleId] != nil {
            touch(moduleId)
            SourcesLog.d("ModuleScriptPool.load(\(moduleId)) — ENGINE CACHE HIT")
            return
        }
        let session = session
        let engine = try await Task.detached {
            try ModuleScriptEngine(jsCode: jsCode, fetchBase: fetchBase, session: session)
        }.value
        if pools[moduleId] != nil { return }
        while pools.count >= Self.maxModules, let oldest = order.first {
            SourcesLog.d("  Evicting LRU module engine: \(oldest)")
            unload(oldest)
        }
        pools[moduleId] = Pool(jsCode: jsCode, fetchBase: fetchBase, free: [engine], started: 1)
        touch(moduleId)
    }

    /// Calls an export on one of the module's engines, exclusively, and gives the engine back on
    /// every path — an engine never returned is a slot the pool can never hand out again.
    func call(_ moduleId: String, function: String, argumentsJSON: String, timeout: TimeInterval = 45) async -> Result<String, Error> {
        guard pools[moduleId] != nil else { return .failure(ModuleScriptError.notLoaded(moduleId)) }
        touch(moduleId)
        let engine: ModuleScriptEngine
        do {
            guard let acquired = try await acquire(moduleId) else { return .failure(ModuleScriptError.notLoaded(moduleId)) }
            engine = acquired
        } catch {
            return .failure(error)
        }
        let result = await engine.call(function, argumentsJSON: argumentsJSON, timeout: timeout)
        giveBack(engine, to: moduleId)
        return result
    }

    func unload(_ moduleId: String) {
        guard let pool = pools.removeValue(forKey: moduleId) else { return }
        order.removeAll { $0 == moduleId }
        pool.waiters.forEach { $0.resume(returning: nil) }
        SourcesLog.d("ModuleScriptPool.unload(\(moduleId))")
    }

    func unloadAll() {
        for id in Array(pools.keys) { unload(id) }
    }

    /// A free engine, a new one while the pool has room (the claim taken before building, released
    /// if building throws), or a wait for whoever holds one.
    private func acquire(_ moduleId: String) async throws -> ModuleScriptEngine? {
        guard var pool = pools[moduleId] else { return nil }
        if let engine = pool.free.popLast() {
            pools[moduleId] = pool
            return engine
        }
        if pool.started < Self.enginesPerModule {
            pool.started += 1
            pools[moduleId] = pool
            let (code, base, session) = (pool.jsCode, pool.fetchBase, session)
            do {
                return try await Task.detached {
                    try ModuleScriptEngine(jsCode: code, fetchBase: base, session: session)
                }.value
            } catch {
                pools[moduleId]?.started -= 1
                throw error
            }
        }
        return await withCheckedContinuation { continuation in
            pools[moduleId]?.waiters.append(continuation)
        }
    }

    private func giveBack(_ engine: ModuleScriptEngine, to moduleId: String) {
        guard var pool = pools[moduleId] else { return }
        if !pool.waiters.isEmpty {
            let waiter = pool.waiters.removeFirst()
            pools[moduleId] = pool
            waiter.resume(returning: engine)
        } else {
            pool.free.append(engine)
            pools[moduleId] = pool
        }
    }

    private func touch(_ moduleId: String) {
        order.removeAll { $0 == moduleId }
        order.append(moduleId)
    }
}
