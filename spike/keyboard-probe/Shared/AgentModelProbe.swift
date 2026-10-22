import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The gate for pi-durable in the keyboard: can an app extension reach Apple's
/// on-device model at all?
///
/// `SystemLanguageModel` is a system service, so the model weights are not
/// charged to our process and there is no network call and no credential. If it
/// works here, the keyboard can run an agent turn entirely on-device.
///
/// API confirmed against the iOS 26.5 SDK `swiftinterface`, not from docs:
/// `SystemLanguageModel.default.availability` is `.available` or
/// `.unavailable(UnavailableReason)` with `.deviceNotEligible`,
/// `.appleIntelligenceNotEnabled` or `.modelNotReady`; the session is
/// `LanguageModelSession(model:tools:instructions:)` and
/// `respond(to:)` returns a `Response` whose `.content` is the text.
@MainActor
enum AgentModelProbe {

    static func describe() async -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            return "iOS 26 required for FoundationModels"
        }

        let before = physFootprintMB()
        let model = SystemLanguageModel.default

        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            let label: String
            switch reason {
            case .deviceNotEligible: label = "deviceNotEligible"
            case .appleIntelligenceNotEnabled: label = "appleIntelligenceNotEnabled"
            case .modelNotReady: label = "modelNotReady"
            @unknown default: label = "unknown reason"
            }
            return "unavailable: \(label) (footprint \(mb(before)))"
        @unknown default:
            return "unknown availability (footprint \(mb(before)))"
        }

        // One bounded turn — the thing a keyboard would actually need.
        let started = Date()
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: "Reply with exactly one word: pong")
            let elapsed = Date().timeIntervalSince(started)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(
                format: "AVAILABLE — said \"%@\" in %.2fs, footprint %@ -> %@ MB",
                text, elapsed, mb(before), mb(physFootprintMB())
            )
        } catch {
            return "available but the turn failed: \(error.localizedDescription)"
        }
        #else
        return "FoundationModels not in this SDK"
        #endif
    }

    private static func mb(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f", value)
    }
}
