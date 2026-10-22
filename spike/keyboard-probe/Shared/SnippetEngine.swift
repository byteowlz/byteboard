import Foundation

/// One compiled Espanso match.
struct Snippet: Codable, Equatable {
    let trigger: String
    let label: String
    let replace: String
    let kind: String            // static | cursor | date | clipboard | shell | script | form | image
    let dateFormat: String?
    let dateOffsetSeconds: Int
    let shellCmd: String?
    let clipVar: String?
    let source: String
}

/// The compiled snapshot plus the lookup structures the keyboard needs.
struct SnippetBundle: Codable {
    let version: Int
    let count: Int
    let entries: [Snippet]
}

/// Loads the compiled snapshot and matches typed text against it.
///
/// Matching rules, from `0006`:
/// - Longest match wins; a trigger that is a strict prefix of a longer one does not fire on
///   its own, it arms and waits (there are six such triggers in the real corpus).
/// - Duplicates resolve deterministically: first definition wins for expansion, later ones
///   stay available as strip candidates.
/// - Matching is case-insensitive on lookup, but the typed text is what gets deleted, so
///   `:BYT` still expands and still reverts to `:BYT`.
final class SnippetEngine {

    struct Match {
        let snippet: Snippet
        /// Every definition sharing this trigger, primary first.
        let variants: [Snippet]
        /// True when longer triggers also start with this text, so it must not auto-fire.
        let isPrefix: Bool
    }

    private(set) var bundle = SnippetBundle(version: 0, count: 0, entries: [])
    private var byTrigger: [String: [Snippet]] = [:]
    /// Trigger -> triggers that strictly extend it, for the arming rule.
    private var extensions: [String: Set<String>] = [:]
    private(set) var loadError: String?

    var isEmpty: Bool { bundle.entries.isEmpty }

    /// Loads from the extension bundle (`snippets.local.json`, gitignored) or, failing that,
    /// from the app group, which is where git-synced updates land.
    func load(bundleURL: URL?, appGroupURL: URL?) {
        let candidates = [appGroupURL, bundleURL].compactMap { $0 }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(SnippetBundle.self, from: data),
                  !decoded.entries.isEmpty else { continue }
            install(decoded)
            loadError = nil
            return
        }
        loadError = candidates.isEmpty
            ? "no snippet bundle found"
            : "snippet bundle unreadable"
    }

    private func install(_ bundle: SnippetBundle) {
        self.bundle = bundle
        var byTrigger: [String: [Snippet]] = [:]
        for snippet in bundle.entries {
            byTrigger[snippet.trigger.lowercased(), default: []].append(snippet)
        }
        // Deterministic duplicate order: keep file order, which is Espanso's load order.
        var extensions: [String: Set<String>] = [:]
        let triggers = byTrigger.keys.sorted()
        for trigger in triggers {
            var extends: Set<String> = []
            for other in triggers where other.count > trigger.count && other.hasPrefix(trigger) {
                extends.insert(other)
            }
            extensions[trigger] = extends
        }
        self.byTrigger = byTrigger
        self.extensions = extensions
    }

    /// Matches `typed` (the text from the last word boundary to the cursor) against the
    /// trigger set.
    func match(typed: String) -> Match? {
        let key = typed.lowercased()
        guard let variants = byTrigger[key], let primary = variants.first else { return nil }
        let isPrefix = !(extensions[key] ?? []).isEmpty
        return Match(snippet: primary, variants: variants, isPrefix: isPrefix)
    }

    /// Candidates whose triggers start with `typed`, for live strip preview while arming.
    func candidates(prefix: String, limit: Int = 3) -> [Snippet] {
        let key = prefix.lowercased()
        guard !key.isEmpty else { return [] }
        var found: [Snippet] = []
        for trigger in byTrigger.keys.sorted() where trigger.hasPrefix(key) {
            if let primary = byTrigger[trigger]?.first {
                found.append(primary)
                if found.count == limit { break }
            }
        }
        return found
    }

    /// Words that end in a trigger separator, for arming detection while typing.
    static func triggerSuffix(of typed: String) -> String? {
        guard let colon = typed.lastIndex(of: ":") else { return nil }
        let suffix = String(typed[colon...])
        // A second colon means a new trigger is being started.
        return suffix.count == 1 || suffix.dropFirst().allSatisfy { $0.isLetter || $0.isNumber }
            ? suffix
            : nil
    }
}
