import UIKit

/// One source for every surface the keyboard draws: keys, the suggestion strip, the key
/// popup and the tools overlay.
///
/// Coherence comes from a few rules rather than from matching colours by eye:
///
/// - **There are two key materials**, letter and function, and everything else borrows one
///   of them. A tools-overlay button is a function key; a suggestion that exists is a
///   function key; the popup is a letter key, grown.
/// - **Pressing swaps the materials**, the way the system keyboard does: a held letter key
///   takes the function shade and vice versa. No third "pressed" grey.
/// - **One accent** marks whatever will happen on release — the armed snippet, the selected
///   alternate. Nothing else is coloured.
/// - **One shadow**, one key radius, one font family.
///
/// Values are the Apple-dark reference recorded in Design Studio (`byteboard-keyboard`),
/// not approved tokens. Changing them here changes every surface at once, which is the point.
enum KeyboardStyle {

    // MARK: materials

    // No background colour: the system draws the keyboard's own backdrop (on iOS 26 a rounded
    // container), and painting an opaque rectangle over it produced a second shade with a
    // square top edge. The keys sit directly on the system material, as Apple's do.

    /// Each colour follows light and dark mode, so the keys suit whichever backdrop the
    /// system draws.
    private static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    static let letterKey = adaptive(light: .white, dark: UIColor(white: 0.42, alpha: 1))
    static let functionKey = adaptive(
        light: UIColor(red: 0.67, green: 0.69, blue: 0.74, alpha: 1),
        dark: UIColor(white: 0.27, alpha: 1))
    static let accent = UIColor.systemBlue

    static let text = adaptive(light: .black, dark: .white)
    static let secondaryText = adaptive(light: UIColor(white: 0.38, alpha: 1), dark: UIColor(white: 0.62, alpha: 1))

    /// The popup is the pressed key grown out of the keyboard, so it uses the letter material.
    static let popupFill = letterKey

    /// The held shade of a key: the other material.
    static func pressed(_ base: UIColor) -> UIColor {
        base == letterKey ? functionKey : letterKey
    }

    // MARK: geometry

    static let keyRadius: CGFloat = 7
    static let popupRadius: CGFloat = 9
    /// The inward curve where the popup body meets the key it grows out of.
    static let popupJoinRadius: CGFloat = 5
    static let previewBodyHeight: CGFloat = 52
    static let popupBodyHeight: CGFloat = 50
    static let popupInset: CGFloat = 5

    // MARK: type

    static let letterFont = UIFont.systemFont(ofSize: 25)
    static let functionFont = UIFont.systemFont(ofSize: 15)
    static let previewFont = UIFont.systemFont(ofSize: 32)
    static let popupFont = UIFont.systemFont(ofSize: 24)
    static let stripFont = UIFont.systemFont(ofSize: 17)
    /// The centre suggestion, the one most likely wanted.
    static let stripPrimaryFont = UIFont.systemFont(ofSize: 17, weight: .semibold)
    /// The soft plate behind the centre suggestion; the others are bare text.
    static let stripHighlight = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.07) }
    static let toolFont = UIFont.systemFont(ofSize: 13, weight: .medium)
    static let diagnosticsFont = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)

    // MARK: shadow

    /// The thin lower edge every key and the popup share. A shadow path is required:
    /// without one, Core Animation renders the shadow offscreen on every frame.
    static func applyShadow(to layer: CALayer, path: CGPath) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowPath = path
    }
}
