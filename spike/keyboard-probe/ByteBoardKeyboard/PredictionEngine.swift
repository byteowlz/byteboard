import ByteBoardCore
import Foundation

/// The Swift face of byteboard-core: word completion, correction and next-word prediction
/// over every dictionary shipped in the keyboard.
///
/// Dictionaries are memory-mapped, so loading costs almost nothing and only the pages a
/// lookup touches become resident. Suggestions may be requested off the main thread; calls
/// into the core are serialised by a lock.
final class PredictionEngine: @unchecked Sendable {

    struct Suggestion: Sendable, Equatable {
        enum Kind: Sendable { case completion, correction, nextWord }
        let word: String
        let kind: Kind
    }

    private let engine: OpaquePointer?
    private let lock = NSLock()
    private(set) var dictionaries: [String] = []

    init() {
        engine = bb_engine_new()
    }

    deinit {
        bb_engine_free(engine)
    }

    /// Adds every `.bbd` file in `directory`, in name order. Returns the languages loaded.
    @discardableResult
    func load(directory: URL?) -> [String] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "bbd" {
            let path = Array(url.path.utf8)
            let status = lock.withLock {
                path.withUnsafeBufferPointer { bb_engine_add_dict(engine, $0.baseAddress, $0.count) }
            }
            if status == 0 { dictionaries.append(url.deletingPathExtension().lastPathComponent) }
        }
        return dictionaries
    }

    /// Up to `max` suggestions for the text before the cursor, best first.
    func suggest(before: String, max: Int) -> [Suggestion] {
        let input = Array(before.utf8)
        var capacity = 1024
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written: Int = lock.withLock {
                input.withUnsafeBufferPointer { text in
                    output.withUnsafeMutableBufferPointer { out in
                        bb_engine_suggest(engine, text.baseAddress, text.count, UInt32(max), out.baseAddress, out.count)
                    }
                }
            }
            if written >= 0 { return Self.parse(output.prefix(written)) }
            if written == Int.min { return [] }
            // The buffer was too small; the core reported how much it needs.
            capacity = -written
        }
        return []
    }

    private static func parse(_ bytes: ArraySlice<UInt8>) -> [Suggestion] {
        String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let kind: Suggestion.Kind
            switch parts[0] {
            case "x": kind = .correction
            case "n": kind = .nextWord
            default: kind = .completion
            }
            return Suggestion(word: String(parts[1]), kind: kind)
        }
    }
}
