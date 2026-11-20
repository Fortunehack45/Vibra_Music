/*
 * Copyright (C) 2026 Kushagra Singh
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
 * Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import os
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

/// The CPU budget for Automix's background analysis, not its audible mix algorithm. Maps from
/// Core's Automix performance setting (efficient 1 thread, balanced 2, performance 4).
public enum AutomixAnalysisBudget: String, Sendable, CaseIterable {
    /// One inference thread, and analysis yields to decoding and playback (background QoS).
    case efficient
    case balanced
    case performance

    public var inferenceThreads: Int {
        switch self {
        case .efficient: return 1
        case .balanced: return 2
        case .performance: return 4
        }
    }

    /// The queue priority analysis runs at. Efficient mode yields rather than competing for a core;
    /// thread count remains the speed knob.
    ///
    /// Android runs efficient mode at `THREAD_PRIORITY_BACKGROUND` and the others at the default
    /// priority. The iOS equivalents are one step up from the literal names: `.background` QoS is
    /// throttled to the point of being deferred outright while the device is busy or the app is in
    /// the background, and an analysis that lands after the transition it was for is worth nothing.
    var qos: DispatchQoS {
        self == .efficient ? .utility : .userInitiated
    }
}

/// The two models Automix ships as module resources.
enum AutomixModel: String {
    /// Beat This! (CPJKU, ISMIR 2024), int8. MIT code and weights.
    case beatThis = "beat_this_int8"
    /// open-unmix "vocals" target (Inria/SigSep), int8. MIT weights.
    case vocals = "vocals_umxhq_int8"

    /// The bundled copy, or nil if the resource is missing from the build.
    var bundledURL: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "onnx", subdirectory: "Models")
    }
}

/// One lazily opened ONNX Runtime session over a model file.
///
/// Parsing a graph is far too expensive to repeat per track, so one session is kept — but only
/// while analysis is running: ``TrackAnalyzer`` calls ``release()`` the moment nothing is in
/// flight, because the parsed graph and its buffers are tens of megabytes a backgrounded music
/// player cannot justify between transitions. Reloading costs under a second against an analysis
/// that already takes several.
///
/// Everything here is optional. A missing model file, an unreadable graph, or a build without
/// ONNX Runtime all resolve to nil, and the callers keep the DSP estimate they already had. A
/// missing beat tracker degrades transitions; a throwing one would break playback.
///
/// Differs from Android in one respect: the Objective-C API has no switch for ONNX Runtime's CPU
/// arena allocator, which the Android build turns off. Releasing the session between analyses is
/// what bounds the retained memory here instead.
final class AutomixModelSession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Automix")

    /// True when this build links ONNX Runtime. Without it every model step answers nil.
    static var isRuntimeAvailable: Bool {
        #if canImport(OnnxRuntimeBindings)
        return true
        #else
        return false
        #endif
    }

    let modelURL: URL?
    private let threads: @Sendable () -> Int
    private let lock = NSLock()

    #if canImport(OnnxRuntimeBindings)
    private var session: ORTSession?
    private var sessionThreads = 0
    private var outputNames: [String] = []
    private var inputName = ""

    /// One environment per process, as ONNX Runtime recommends. Nil if it could not be created.
    private static let environment: ORTEnv? = {
        do {
            return try ORTEnv(loggingLevel: .warning)
        } catch {
            logger.warning("ONNX Runtime environment unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()
    #endif

    init(modelURL: URL?, threads: @escaping @Sendable () -> Int) {
        self.modelURL = modelURL
        self.threads = threads
    }

    /// Runs the model once over a float32 input of `shape`, which `fill` writes in place, and
    /// hands `read` every output (in the graph's declared output order) alongside the input.
    ///
    /// The buffers are only valid inside `read`; nothing is copied out that the caller does not
    /// copy itself, because the vocal model's output alone is sixteen megabytes.
    func run<T>(
        shape: [Int],
        fill: (UnsafeMutableBufferPointer<Float>) -> Void,
        read: (_ outputs: [UnsafeBufferPointer<Float>], _ input: UnsafeBufferPointer<Float>) -> T?
    ) -> T? {
        #if canImport(OnnxRuntimeBindings)
        guard let opened = openSession() else { return nil }
        let (session, inputName, outputNames) = opened
        let count = shape.reduce(1, *)
        guard count > 0, let input = NSMutableData(length: count * MemoryLayout<Float>.stride) else { return nil }
        let inputPointer = input.mutableBytes.bindMemory(to: Float.self, capacity: count)
        fill(UnsafeMutableBufferPointer(start: inputPointer, count: count))
        do {
            let tensor = try ORTValue(
                tensorData: input,
                elementType: .float,
                shape: shape.map { NSNumber(value: $0) }
            )
            let results = try session.run(
                withInputs: [inputName: tensor],
                outputNames: Set(outputNames),
                runOptions: nil
            )
            var buffers: [UnsafeBufferPointer<Float>] = []
            var retained: [NSMutableData] = []
            for name in outputNames {
                guard let value = results[name] else { return nil }
                let data = try value.tensorData()
                retained.append(data)
                let floats = data.length / MemoryLayout<Float>.stride
                buffers.append(UnsafeBufferPointer(start: data.mutableBytes.bindMemory(to: Float.self, capacity: floats), count: floats))
            }
            let result = read(buffers, UnsafeBufferPointer(start: inputPointer, count: count))
            withExtendedLifetime((retained, input, tensor, results)) {}
            return result
        } catch {
            Self.logger.warning("Inference failed for \(self.modelURL?.lastPathComponent ?? "model", privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Whether there is anything to open at all: a model file and a linked runtime. Checked
    /// before preparing a model's input, so a build or a test without the model does not pay for
    /// resampling and spectrograms nothing will read. Unlike ``isAvailable`` it never parses the
    /// graph.
    var isConfigured: Bool { modelURL != nil && Self.isRuntimeAvailable }

    /// Whether a session can be opened right now (model present, runtime linked, graph parses).
    var isAvailable: Bool {
        #if canImport(OnnxRuntimeBindings)
        return openSession() != nil
        #else
        return false
        #endif
    }

    #if canImport(OnnxRuntimeBindings)
    private func openSession() -> (ORTSession, String, [String])? {
        let wanted = max(1, threads())
        lock.lock()
        defer { lock.unlock() }
        if let session, sessionThreads == wanted { return (session, inputName, outputNames) }
        session = nil
        guard let modelURL, let environment = Self.environment else { return nil }
        do {
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(Int32(wanted))
            try options.setGraphOptimizationLevel(.all)
            let opened = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: options)
            guard let firstInput = try opened.inputNames().first else { return nil }
            let outputs = try opened.outputNames()
            session = opened
            sessionThreads = wanted
            inputName = firstInput
            outputNames = outputs
            return (opened, firstInput, outputs)
        } catch {
            Self.logger.warning("Model \(modelURL.lastPathComponent, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    #endif

    /// Closes the session; the next ``run(shape:fill:read:)`` reopens it.
    func release() {
        #if canImport(OnnxRuntimeBindings)
        lock.lock()
        session = nil
        sessionThreads = 0
        lock.unlock()
        #endif
    }
}
