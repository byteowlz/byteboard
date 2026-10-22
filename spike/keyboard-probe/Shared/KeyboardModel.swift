import Foundation

/// The keyboard's anatomy as data.
///
/// Mirrors the accepted direction in Design Studio line `byteboard-keyboard`
/// (entry `byteboard-keyboard-r3`, basis user-directed): a standard iOS anatomy with a
/// permanent number row, the snippet surface in the suggestion strip, one tools key, and a
/// period key right of the space bar.
///
/// Sizing has three cases, and the distinction is what keeps the rows honest:
///
/// - **letter** — one reference unit, derived from the ten-key rows. Also used by the
///   tools and period keys, so they are exactly as wide as a letter key.
/// - **function** — the shared function-key width, so shift and backspace are *exactly*
///   the same width as `123` and return below them.
/// - **flex** — shares whatever is left, by weight. Space is the only one.
///
/// A nine-key letter row has only letter keys, so it insets itself by one unit and a gap,
/// which is deliberate.
enum KeyboardModel {

    static let unitCount: CGFloat = 10
    static let rowHeight: CGFloat = 42
    static let numberRowHeight: CGFloat = 34
    static let stripHeight: CGFloat = 48
    /// Between keys in a row; also the unit-width maths.
    static let gap: CGFloat = 6
    /// Between rows. More air vertically than horizontally, as SwiftKey and Apple do: rows
    /// read as lines and a thumb lands with less doubt about which row it hit.
    static let rowGap: CGFloat = 11
    static let sidePadding: CGFloat = 3
    static let cornerRadius: CGFloat = 7
    static let popupItemWidth: CGFloat = 42

    /// Top padding + strip + gap + the keyboard block + bottom padding, from the real stack
    /// arithmetic rather than an estimate: a wrong height is visible immediately.
    static var totalHeight: CGFloat {
        let keyboardBlock = numberRowHeight + rowGap
            + rowHeight * 3 + rowGap * 2
            + rowGap + rowHeight
        return gap + stripHeight + gap + keyboardBlock + gap
    }

    enum Key: Equatable {
        case character(String)
        case shift
        case delete
        case symbols        // 123
        case letters        // ABC
        case tools
        case space
        case ret
        case spacer
    }

    enum Sizing: Equatable {
        case letter
        case function
        case flex
    }

    struct Slot: Equatable {
        let key: Key
        let weight: CGFloat
        var sizing: Sizing = .letter

        static func letter(_ key: Key, _ weight: CGFloat = 1) -> Slot {
            Slot(key: key, weight: weight, sizing: .letter)
        }
        static func function(_ key: Key) -> Slot {
            Slot(key: key, weight: 1.5, sizing: .function)
        }
        static func flex(_ key: Key, _ weight: CGFloat) -> Slot {
            Slot(key: key, weight: weight, sizing: .flex)
        }
    }

    enum Layer { case letters, symbols }

    /// A permanent number row. Un-native on iPhone by design — the user asked for it and
    /// accepted the ~34 pt cost in exchange.
    static let numberRow: [Slot] = "1234567890".map { .letter(.character(String($0))) }

    static func rows(for layer: Layer) -> [[Slot]] {
        switch layer {
        case .letters:
            return [
                "qwertyuiop".map { .letter(.character(String($0))) },
                "asdfghjkl".map { .letter(.character(String($0))) },
                [.function(.shift)]
                    + "zxcvbnm".map { .letter(.character(String($0))) }
                    + [.function(.delete)],
            ]
        case .symbols:
            return [
                "-/:;()€&@\"".map { .letter(.character(String($0))) },
                ".,?!'„“‚–".map { .letter(.character(String($0))) },
                [Slot(key: .spacer, weight: 1.5, sizing: .function)]
                    + "#$%*+=~".map { .letter(.character(String($0))) }
                    + [.function(.delete)],
            ]
        }
    }

    /// The bottom row is the same on both layers; only the layer toggle renames.
    ///
    /// The `.` key right of the space bar is a **deliberate deviation** from the
    /// native-first direction: Apple has no such key and reaches `.` through the `123`
    /// layer. The user directed it (2026-10-17) because SwiftKey puts it there and the thumb
    /// already expects it. Recorded as user-directed in Studio.
    static func bottomRow(layer: Layer) -> [Slot] {
        [
            .function(layer == .letters ? .symbols : .letters),
            .letter(.tools, 1),
            .flex(.space, 5),
            .letter(.character("."), 1),
            .function(.ret),
        ]
    }

    /// The reference unit: ten keys and nine gaps across the usable width.
    static func unitWidth(usable: CGFloat) -> CGFloat {
        max(1, (usable - gap * (unitCount - 1)) / unitCount)
    }

    /// The shared function-key width.
    ///
    /// Derived from the shift row having to span the full width, where `u` is the unit and
    /// `g` the gap: `2F + 7u + 8g = 10u + 9g`, so `F = 1.5u + g/2`. Taking it from the unit
    /// alone means the bottom row computes the same number without needing row context,
    /// which is what makes shift and `123` *exactly* equal rather than merely close.
    static func functionWidth(unit: CGFloat) -> CGFloat {
        1.5 * unit + gap / 2
    }

    static func widths(for slots: [Slot], usable: CGFloat, unit: CGFloat) -> [CGFloat] {
        let function = functionWidth(unit: unit)
        let gaps = gap * CGFloat(max(0, slots.count - 1))
        var fixedTotal: CGFloat = 0
        var flexWeight: CGFloat = 0
        for slot in slots {
            switch slot.sizing {
            case .letter: fixedTotal += unit
            case .function: fixedTotal += function
            case .flex: flexWeight += slot.weight
            }
        }
        let flexUnit = flexWeight > 0
            ? max(1, (usable - gaps - fixedTotal) / flexWeight)
            : unit
        return slots.map { slot in
            switch slot.sizing {
            case .letter: return unit
            case .function: return function
            case .flex: return slot.weight * flexUnit
            }
        }
    }

    /// Long-press alternates. iOS anchors the popup to the key; the base character is included
    /// so that releasing without sliding types what a tap would.
    static let alternates: [String: [String]] = [
        ".": ["!", "@", "#", ",", ".", "?"],
        ",": [";", ":", "'", "\"", "…"],
        "?": ["!", ".", ",", "¿", "‽"],
        "!": ["?", ".", ",", "¡"],
        "-": ["—", "–", "•", "_"],
        "'": ["‘", "’", "‚", "\""],
        "\"": ["“", "”", "„", "'"],
        "1": ["!"], "2": ["@"], "3": ["#"], "4": ["$"], "5": ["%"],
        "6": ["^"], "7": ["&"], "8": ["*"], "9": ["("], "0": [")"],
        "a": ["à", "á", "â", "ä", "æ", "å"],
        "e": ["è", "é", "ê", "ë"],
        "i": ["ì", "í", "î", "ï"],
        "o": ["ò", "ó", "ô", "ö", "ø", "õ"],
        "u": ["ù", "ú", "û", "ü"],
        "y": ["ÿ"], "c": ["ç"], "n": ["ñ"], "s": ["ß"],
    ]

    /// Alternates for a key, cased when shift is active, with the base character present so a
    /// long press without a slide behaves like a tap.
    static func popupValues(for key: Key, shifted: Bool) -> (values: [String], base: Int) {
        guard case .character(let text) = key else { return ([], 0) }
        let found = alternates[text.lowercased()] ?? []
        guard !found.isEmpty else { return ([], 0) }
        var values = shifted ? found.map { $0.uppercased() } : found
        let base = shifted ? text.uppercased() : text
        if let index = values.firstIndex(of: base) { return (values, index) }
        values.insert(base, at: 0)
        return (values, 0)
    }

    static func label(for key: Key) -> String {
        switch key {
        case .character(let text): return text
        case .symbols: return "123"
        case .letters: return "ABC"
        case .space: return "space"
        default: return ""
        }
    }
}
