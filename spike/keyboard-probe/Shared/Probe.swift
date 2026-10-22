import AVFoundation
import Foundation
import MachO

let byteBoardAppGroup = "group.com.byteowlz.byteboard"

/// Everything the probe measures. Written by the extension, read by the app.
struct ProbeReport: Codable, Sendable {
    var updatedAt = Date()
    var writer = "unknown"
    var micStatus = "unknown"
    var micRequestResult: String?
    /// A real capture attempt. A permission flag is not proof of audio.
    var captureResult: String?
    /// Just-bash run inside the extension: the Espanso snippet engine.
    var justBashResult: String?
    var justBashFootprintMB: Double?
    /// Apple's on-device model, reached from inside the extension.
    var agentModelResult: String?
    /// Suggestion-strip state. Wired by the snippet engine; optional so that a report
    /// written by an older build still decodes.
    var snippetTrigger: String?
    var snippetArmedLabel: String?
    /// Delay between the screen registering a touch and the keyboard's handler running.
    var touchLatency: String?
    /// The first reading after the extension loads. Set once and never
    /// overwritten, so it stays a baseline instead of tracking later actions.
    var footprintAtLoadMB: Double?
    var footprintAfterModelMB: Double?
    var modelDirectory: String?
    var appGroupReachable = false
    var notes: [String] = []
}

enum ProbeStore {
    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: byteBoardAppGroup)
    }

    static var reportURL: URL? {
        container?.appendingPathComponent("probe-report.json")
    }

    static func write(_ report: ProbeReport) {
        guard let url = reportURL else { return }
        do {
            try JSONEncoder().encode(report).write(to: url, options: .atomic)
        } catch {
            NSLog("byteboard probe: write failed: %@", String(describing: error))
        }
    }

    static func read() -> ProbeReport? {
        guard let url = reportURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProbeReport.self, from: data)
    }

    /// Keyboard preferences shared with the containing app. Haptics is the first;
    /// the app is expected to expose it, because a keyboard cannot read the system's
    /// own keyboard-feedback setting.
    static var settings: UserDefaults {
        UserDefaults(suiteName: byteBoardAppGroup) ?? .standard
    }
}

/// `phys_footprint` is the metric iOS actually kills extensions on.
func physFootprintMB() -> Double? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Double(info.phys_footprint) / 1_048_576.0
}

@MainActor
enum MicProbe {
    static func status() -> String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    /// Whether a keyboard extension can even make this request is an open question.
    static func request() async -> String {
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? "granted" : "denied"
    }
}

/// Thread-safe meter. The tap block runs on a real-time audio thread, so its
/// state must not be mutated from the main actor.
private final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var peakDB: Float = -160
    private var firstError: String?

    func observe(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        buffers += 1
        guard let channel = buffer.floatChannelData?[0] else {
            firstError = firstError ?? "no float channel data"
            return
        }
        let frames = Int(buffer.frameLength)
        var localPeak: Float = 0
        for index in 0..<frames {
            localPeak = max(localPeak, abs(channel[index]))
        }
        if localPeak > 0 {
            peakDB = max(peakDB, 20 * log10(localPeak))
        }
    }

    func snapshot() -> (buffers: Int, peakDB: Float, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (buffers, peakDB, firstError)
    }
}

/// The test that actually matters: open a record session and see whether real
/// audio arrives. Reading `recordPermission` only reports a flag.
///
/// Three configurations are attempted in turn, because a single failure proves
/// nothing: `.duckOthers` with a record-only category is itself invalid, and an
/// engine failure may be the configuration rather than the extension sandbox.
@MainActor
enum CaptureProbe {
    static func capture(seconds: Double = 1.0) async -> String {
        var lines: [String] = []
        let a = await engineAttempt(
            category: .record, mode: .default, options: [], seconds: seconds)
        lines.append("A record/engine: " + a)
        let b = await engineAttempt(
            category: .playAndRecord, mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth], seconds: seconds)
        lines.append("B playAndRecord/engine: " + b)
        let c = await recorderAttempt(seconds: seconds)
        lines.append("C playAndRecord/recorder: " + c)
        return lines.joined(separator: " // ")
    }

    private static func shortError(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    private static func engineAttempt(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions,
        seconds: Double
    ) async -> String {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(category, mode: mode, options: options)
            try session.setActive(true, options: [])
        } catch {
            return "session failed: \(shortError(error))"
        }
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            return "input format invalid (rate 0)"
        }
        let meter = Meter()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            meter.observe(buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return "engine start failed: \(shortError(error))"
        }

        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        engine.stop()
        input.removeTap(onBus: 0)

        let result = meter.snapshot()
        if let error = result.error {
            return "buffer error: \(error)"
        }
        let verdict = result.buffers == 0
            ? "NO AUDIO"
            : (result.peakDB <= -60 ? "buffers but silent" : "AUDIO OK")
        return String(
            format: "%@ buffers=%d peak=%.1f dB rate=%.0f",
            verdict, result.buffers, result.peakDB, format.sampleRate
        )
    }

    /// AVAudioRecorder exercises a different path into the input hardware.
    private static func recorderAttempt(seconds: Double) async -> String {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
        } catch {
            return "session failed: \(shortError(error))"
        }
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bb-probe.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { return "record() refused" }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            recorder.stop()
        } catch {
            return "recorder failed: \(shortError(error))"
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        try? FileManager.default.removeItem(at: url)
        return size > 1024 ? "AUDIO OK \(size) bytes" : "NO AUDIO (\(size) bytes)"
    }
}
