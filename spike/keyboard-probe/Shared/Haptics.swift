import CoreHaptics
import UIKit

/// Haptics for the keyboard.
///
/// Two things are not knowable in advance and are therefore reported rather than
/// assumed: whether a keyboard **extension** is permitted to drive the Taptic Engine,
/// and whether the user has the system's own keyboard haptics switched on. The second
/// has no public API, so byteboard carries its own preference (shared with the app via
/// the app group) instead of pretending to read Apple's.
///
/// Strength is a level, not a constant, because "the tick is too weak" is a taste
/// judgement that only the person holding the phone can make. Level 0 is off.
@MainActor
final class Haptics {

    static let shared = Haptics()

    enum Strength: Int, CaseIterable {
        case off = 0, light, medium, heavy

        var label: String {
            switch self {
            case .off: return "off"
            case .light: return "light"
            case .medium: return "medium"
            case .heavy: return "heavy"
            }
        }

        var style: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .off, .light: return .light
            case .medium: return .medium
            case .heavy: return .heavy
            }
        }

        /// Keypress intensity. Full at every level: the style carries the difference.
        var intensity: CGFloat {
            switch self {
            case .off: return 0
            case .light: return 1.0
            case .medium: return 1.0
            case .heavy: return 1.0
            }
        }
    }

    private var impactGenerator: UIImpactFeedbackGenerator?
    private var selectionGenerator: UISelectionFeedbackGenerator?
    private var generatorStrength: Strength?

    /// What CoreHaptics reports. Diagnostic only — it deliberately does not gate
    /// feedback, because it can under-report inside an extension and a wrong `false`
    /// should not silently disable a feature.
    let hardwareReportsHaptics: Bool

    private(set) var strength: Strength

    private init() {
        hardwareReportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        let stored = ProbeStore.settings.object(forKey: "hapticsStrength") as? Int
        // Default to medium: light-and-gentle was measured as too weak in the hand.
        strength = stored.flatMap(Strength.init(rawValue:)) ?? .medium
    }

    var isEnabled: Bool { strength != .off }

    var describe: String {
        "haptics \(strength.label), hardware \(hardwareReportsHaptics ? "reports capable" : "reports NO")"
    }

    func setStrength(_ level: Strength) {
        strength = level
        ProbeStore.settings.set(level.rawValue, forKey: "hapticsStrength")
        impactGenerator = nil
        generatorStrength = nil
        prepare()
    }

    func cycleStrength() -> Strength {
        let all = Strength.allCases
        let index = all.firstIndex(of: strength) ?? 0
        let next = all[(index + 1) % all.count]
        setStrength(next)
        return next
    }

    private func ensureGenerator() {
        guard isEnabled else { return }
        if impactGenerator == nil || generatorStrength != strength {
            impactGenerator = UIImpactFeedbackGenerator(style: strength.style)
            generatorStrength = strength
            impactGenerator?.prepare()
        }
    }

    /// Call when the keyboard appears, so the first tap does not pay for engine spin-up.
    func prepare() {
        ensureGenerator()
        if selectionGenerator == nil { selectionGenerator = UISelectionFeedbackGenerator() }
        selectionGenerator?.prepare()
    }

    /// One key press.
    ///
    /// Re-arms immediately after firing: the engine's prepared state decays within a
    /// second or two, and an unprepared generator is exactly what makes a tick feel
    /// late. The caller also has to fire this on touch **down** rather than release.
    func key() {
        guard isEnabled else { return }
        ensureGenerator()
        impactGenerator?.impactOccurred(intensity: strength.intensity)
        impactGenerator?.prepare()
    }

    /// Shift, layer switch, cursor steps — a different feel from a character.
    func selection() {
        guard isEnabled else { return }
        if selectionGenerator == nil { selectionGenerator = UISelectionFeedbackGenerator() }
        selectionGenerator?.selectionChanged()
        selectionGenerator?.prepare()
    }

    /// Maximum intensity, for confirming by hand that the extension can drive it at all.
    func strong() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred(intensity: 1.0)
    }
}
