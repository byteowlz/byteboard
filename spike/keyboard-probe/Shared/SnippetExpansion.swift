import Foundation

/// Expands a matched snippet into the text to insert and where the cursor should land.
///
/// Pure and synchronous so it is unit-testable without UIKit: the controller applies the
/// result through `textDocumentProxy`.
enum SnippetExpansion {

    struct Result: Equatable {
        let text: String
        /// Characters after the cursor that were already inserted, for `$|$` placement.
        let cursorFromEnd: Int
        /// Set when the expansion should be replaced by the literal trigger on the next
        /// Backspace.
        let revertTrigger: String?
    }

    static func expand(_ snippet: Snippet, date: Date = Date(), clipboard: String? = nil) -> Result {
        switch snippet.kind {
        case "cursor":
            let parts = snippet.replace.components(separatedBy: "$|$")
            let text = parts.joined()
            let after = parts.count > 1 ? parts.last?.count ?? 0 : 0
            return Result(text: text, cursorFromEnd: after, revertTrigger: snippet.trigger)
        case "date":
            return Result(
                text: formatDate(date, format: snippet.dateFormat, offset: snippet.dateOffsetSeconds),
                cursorFromEnd: 0,
                revertTrigger: snippet.trigger)
        case "clipboard":
            var text = snippet.replace
            if let variable = snippet.clipVar, !variable.isEmpty {
                text = text.replacingOccurrences(of: "{{\(variable)}}", with: clipboard ?? "")
            } else {
                text = text.replacingOccurrences(of: "{{clipb}}", with: clipboard ?? "")
            }
            return Result(text: text, cursorFromEnd: 0, revertTrigger: snippet.trigger)
        case "image":
            // Images cannot be inserted into a host field (`0004`); the controller copies to
            // the pasteboard instead, so expansion yields the label as insertable text.
            return Result(text: "", cursorFromEnd: 0, revertTrigger: nil)
        case "shell", "script", "form":
            // Evaluated asynchronously by the controller through JustBashHost or the form
            // panel; this returns the template so tests have something deterministic.
            return Result(text: snippet.replace, cursorFromEnd: 0, revertTrigger: nil)
        default:
            return Result(text: snippet.replace, cursorFromEnd: 0, revertTrigger: snippet.trigger)
        }
    }

    /// The strftime subset the Espanso corpus actually uses: `%Y %m %d %H %M %S %B %b %A %a`,
    /// with `%-d`/`%-m` supported because date.yml uses them.
    static func formatDate(_ date: Date, format: String?, offset: Int) -> String {
        var shifted = date
        if offset != 0 { shifted = date.addingTimeInterval(TimeInterval(offset)) }
        guard let format, !format.isEmpty else {
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: shifted)
        }
        var output = format
        let replacements: [String: String] = [
            "%Y": "yyyy", "%y": "yy",
            "%m": "MM", "%-m": "M",
            "%d": "dd", "%-d": "d",
            "%H": "HH", "%-H": "H",
            "%M": "mm", "%S": "ss",
            "%B": "MMMM", "%b": "MMM", "%h": "MMM",
            "%A": "EEEE", "%a": "EEE",
            "%p": "a", "%Z": "zzz", "%z": "ZZZZ",
        ]
        // Longest first so %-m is replaced before %m.
        for (token, unicode) in replacements.sorted(by: { $0.key.count > $1.key.count }) {
            output = output.replacingOccurrences(of: token, with: "\u{2060}\(unicode)\u{2060}")
        }
        // Restore the placeholders to plain Unicode format strings.
        output = output.replacingOccurrences(of: "\u{2060}", with: "")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = output
        return formatter.string(from: shifted)
    }
}
