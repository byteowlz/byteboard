import Foundation
import PiDurableKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One row of the durable conversation, projected for keyboard UI.
public struct AgentRow: Sendable, Identifiable, Equatable {
    public let id: String
    public let role: String
    public let text: String
    public let failed: Bool
    public let live: Bool
}

/// What the agent spent since the keyboard process started, for the tools overlay.
public struct AgentStatus: Sendable {
    public let available: Bool
    public let reason: String?
    public let openMilliseconds: Int?
    public let lastTurnMilliseconds: Int?
    public let footprintDeltaMB: Double?
}

/// The keyboard's own durable agent: a PiDurableKit harness driven by Apple's on-device
/// model. No tools are offered, and the harness runtime denies every network request by
/// URLProtocol, so the extension keeps its no-socket property; inference is on-device.
///
/// Sessions live in the shared app group. The keyboard process is killed freely by iOS,
/// which is exactly what the durable store is for: the next `@pi` resumes the same
/// conversation from sqlite, and the containing app can read the same store later.
public actor KeyboardAgent {
    public static let shared = KeyboardAgent()

    static let appGroup = "group.com.byteowlz.byteboard"

    private var harness: Harness?
    private var conversation: Conversation?
    private var lease: FlockLease?
    private var footprintBeforeOpenMB: Double?
    private var openMilliseconds: Int?
    private var lastTurnMilliseconds: Int?
    private var unavailableReason: String?
    private var storeRoot: URL?

    /// Framed as a chat assistant on purpose. Describing the answer as text for a keyboard's
    /// suggestion strip made the small on-device model behave like autocomplete and echo the
    /// user's words back (measured: "idk" -> "idk").
    private static let instructions = """
    You are Pi, a helpful assistant the user chats with from their phone keyboard. Reply \
    conversationally and helpfully, in the user's language. Keep answers short unless asked \
    for more. Never just repeat the user's words back. You run on the device and have no \
    tools, network or file access; never claim otherwise.
    """

    // MARK: lifecycle

    /// Opens the harness once per keyboard process. Cheap after the first call.
    public func openIfNeeded() async -> String? {
        if harness != nil { return nil }
        if let unavailableReason { return unavailableReason }
        do {
            footprintBeforeOpenMB = Self.footprintMB()
            let start = Date()
            let root = try Self.sessionRoot()
            guard let lease = try? FlockLease(root: root) else {
                throw AgentUnavailable("The agent store is in use by the containing app.")
            }
            self.lease = lease

            // Deny everything: no request can leave the process, on principle.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DenyAllNetwork.self]
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            let runtime = Runtime(configuration: .init(urlSessionConfiguration: configuration, log: { _, _ in }))
            let models = Models(builtinProviders: false, catalog: nil, runtime: runtime)
            let provider = try Self.makeProvider()
            try await models.register(provider)

            let opened = try await Harness.open(
                .sqlite(at: root.appendingPathComponent("agent.sqlite")),
                models: models,
                extensions: [],
                settings: Settings(
                    stream: .init(maxRetries: 0, cacheRetention: nil),
                    retry: .init(enabled: false),
                    compaction: .forContextWindow(4096)),
                resume: false)
            let conversation = try await opened.root(agent: AgentChange(model: provider.model, instructions: Self.instructions))
            try await opened.resume()
            harness = opened
            self.conversation = conversation
            storeRoot = root
            openMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
            await exportTranscript()
            return nil
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            unavailableReason = reason
            harness = nil
            conversation = nil
            lease?.release()
            lease = nil
            return reason
        }
    }

    /// Closed when the keyboard disappears: the harness holds the sqlite lease and some
    /// memory; durability makes closing free, the next open resumes.
    public func close() async {
        if let harness { try? await harness.close() }
        harness = nil
        conversation = nil
        lease?.release()
        lease = nil
        openMilliseconds = nil
        lastTurnMilliseconds = nil
        footprintBeforeOpenMB = nil
    }

    // MARK: turns

    /// Submits one prompt and waits for the turn to settle.
    public func send(_ text: String) async throws {
        guard let conversation else { throw AgentUnavailable("The agent is not open.") }
        let start = Date()
        _ = try await conversation.submit(text, whenBusy: .reject, requestId: UUID().uuidString)
        try await conversation.waitForIdle()
        lastTurnMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
        await exportTranscript()
    }

    /// Debug export: every stored entry (resets included) as JSON in the process's own
    /// tmp directory, which `devicectl` can copy off a development-signed device. Pull with
    /// `just pull-transcript`. Overwritten each time; never leaves the phone by itself.
    private func exportTranscript() async {
        guard let conversation else { return }
        do {
            let entries = try await conversation.view().entries
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let body = try encoder.encode(entries)
            var envelope = Data("{\"store\": ".utf8)
            envelope += try JSONEncoder().encode(storeRoot?.path ?? "unknown")
            envelope += Data(", \"exported\": ".utf8)
            envelope += try JSONEncoder().encode(ISO8601DateFormatter().string(from: Date()))
            envelope += Data(", \"entries\": ".utf8)
            envelope += body
            envelope += Data("}".utf8)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-transcript.json")
            try envelope.write(to: url, options: .atomic)
        } catch {
            // Debug aid only; a failed export must never disturb the conversation.
        }
    }

    /// Starts a fresh session: the model forgets, storage keeps the old turns.
    public func newSession() async throws {
        guard let conversation else { throw AgentUnavailable("The agent is not open.") }
        try await conversation.reset()
    }

    public func status() -> AgentStatus {
        AgentStatus(
            available: harness != nil,
            reason: unavailableReason,
            openMilliseconds: openMilliseconds,
            lastTurnMilliseconds: lastTurnMilliseconds,
            footprintDeltaMB: {
                guard let before = footprintBeforeOpenMB, let now = Self.footprintMB() else { return nil }
                return max(0, now - before)
            }())
    }

    /// Live rows for the transcript, driven by the conversation's own update stream.
    public func rowStream() -> AsyncThrowingStream<[AgentRow], Error> {
        guard let conversation else {
            return AsyncThrowingStream { $0.finish() }
        }
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await view in conversation.views() {
                        continuation.yield(Self.project(view))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A one-shot read of the current rows (used right after opening, before any turn).
    public func rows() async throws -> [AgentRow] {
        guard let conversation else { return [] }
        return Self.project(try await conversation.view())
    }

    // MARK: pieces

    private nonisolated static func sessionRoot() throws -> URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var root = base.appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("keyboard", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return root
    }

    private nonisolated static func makeProvider() throws -> NativeModelProvider {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            throw AgentUnavailable("The on-device model needs iOS 26.")
        }
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(.appleIntelligenceNotEnabled):
            throw AgentUnavailable("Turn on Apple Intelligence to use the on-device model.")
        case .unavailable(.deviceNotEligible):
            throw AgentUnavailable("This device does not run Apple's on-device model.")
        case .unavailable(.modelNotReady):
            throw AgentUnavailable("Apple's on-device model is still downloading.")
        case .unavailable(_):
            throw AgentUnavailable("Apple's on-device model is unavailable.")
        }
        return NativeModelProvider(id: "byteboard-local", modelID: "on-device", name: "Apple on-device",
            contextWindow: 4096) { request, emit in
                try await Self.respond(request, emit: emit)
        }
        #else
        throw AgentUnavailable("The on-device model is not in this build.")
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private nonisolated static func respond(_ request: JSONValue, emit: @escaping @Sendable (JSONValue) -> Void) async throws -> JSONValue {
        // The harness replays the full history each turn; keep it inside the small
        // on-device context instead of silently truncating mid-sentence.
        let messages = request["messages"]?.arrayValue ?? []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(messages)
        guard data.count <= 12_000 else {
            return NativeModelProvider.answer(error: "This conversation outgrew the on-device context. Clear it and start fresh; nothing left the phone.")
        }
        // Earlier turns become a real model transcript, so the model sees a conversation
        // rather than a quoted one; the last user message is the prompt.
        let turns = dialogueTurns(messages)
        guard let last = turns.last, last.role == "user" else {
            return NativeModelProvider.answer(error: "There is no new message to answer.")
        }
        let session = LanguageModelSession(model: .default, transcript: transcript(Array(turns.dropLast())))
        let response = try await session.respond(
            to: last.text,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 512))
        try Task.checkCancellation()
        let answer = response.content
        emit(["type": "text", "delta": .string(answer)])
        return NativeModelProvider.answer(text: answer)
    }
    #endif

    /// User and assistant text in order; system, tool and empty entries dropped.
    nonisolated static func dialogueTurns(_ messages: [JSONValue]) -> [(role: String, text: String)] {
        func text(_ message: JSONValue) -> String {
            if let plain = message["content"]?.stringValue { return plain }
            return (message["content"]?.arrayValue ?? [])
                .filter { $0["type"]?.stringValue == "text" }
                .compactMap { $0["text"]?.stringValue }
                .joined()
        }
        return messages.compactMap { message in
            let role = message["role"]?.stringValue ?? ""
            guard role == "user" || role == "assistant" else { return nil }
            let body = text(message).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : (role, body)
        }
    }

    #if canImport(FoundationModels)
    /// Rebuilds the on-device session from stored turns without generating them again.
    @available(iOS 26.0, *)
    nonisolated static func transcript(_ turns: [(role: String, text: String)]) -> Transcript {
        func segment(_ text: String) -> Transcript.Segment {
            .text(Transcript.TextSegment(content: text))
        }
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [segment(instructions)], toolDefinitions: []))
        ]
        for turn in turns {
            entries.append(turn.role == "user"
                ? .prompt(Transcript.Prompt(segments: [segment(turn.text)]))
                : .response(Transcript.Response(assetIDs: [], segments: [segment(turn.text)])))
        }
        return Transcript(entries: entries)
    }
    #endif

    private nonisolated static func project(_ view: ConversationView) -> [AgentRow] {
        // A reset keeps older entries in storage; the visible session starts after the last one.
        let entries = view.entries
        let start = entries.lastIndex { $0.kind.rawValue.hasSuffix("reset") }.map { entries.index(after: $0) }
            ?? entries.startIndex
        var rows = entries[start...]
            .filter { $0.kind.rawValue.hasSuffix("user") || $0.kind.rawValue.hasSuffix("assistant") }
            .map { entry in
                let failure = entry.assistantMessage?.errorMessage
                return AgentRow(
                    id: String(entry.id.rawValue),
                    role: entry.kind.rawValue.hasSuffix("user") ? "user" : "assistant",
                    text: (failure?.isEmpty == false ? failure! : entry.text),
                    failed: entry.toolResult?.isError == true || entry.assistantMessage?.stopReason == .error,
                    live: false)
            }
        if let streaming = view.streamingMessage, !streaming.text.isEmpty {
            rows.append(AgentRow(id: "live", role: "assistant", text: streaming.text, failed: false, live: true))
        }
        return rows
    }

    private nonisolated static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}

public struct AgentUnavailable: LocalizedError, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// One holder per store root, like the kit's own lease: the app and the extension must not
/// write the same conversation concurrently.
final class FlockLease: @unchecked Sendable {
    private var descriptor: Int32 = -1

    init(root: URL) throws {
        descriptor = Darwin.open(root.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
            throw AgentUnavailable("The agent store is locked elsewhere.")
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

/// Defense in depth behind the empty tool list: the harness runtime cannot fetch anything.
final class DenyAllNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
