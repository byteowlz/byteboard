import AVFoundation
import MoonshineVoice
import UIKit
import Vision

/// A real keyboard, plus the diagnostic surface that measured the platform limits.
///
/// Anatomy comes from `KeyboardModel`, which mirrors the accepted Design Studio direction
/// (line `byteboard-keyboard`, entry `byteboard-keyboard-r3`, basis user-directed). Every
/// surface — keys, strip, popup, tools — draws from `KeyboardStyle`, so they cannot drift
/// apart. The probe UI is not deleted: it lives behind the tools key, because the
/// measurements are still the evidence for the built keyboard.
final class KeyboardViewController: UIInputViewController {

    // MARK: keyboard state

    private var layer: KeyboardModel.Layer = .letters
    private var isShifted = true
    private var isCapsLocked = false
    private var lastShiftTap = Date.distantPast

    // MARK: views

    private let strip = UIStackView()
    private let popup = KeyPopupView()
    private let keyboard = KeyGrid()
    /// A character key whose finger is still down: the next key's touch commits it, so fast
    /// overlapping taps keep their order.
    private weak var heldCharacterKey: KeyButton?
    private var rolloverCommits = 0
    private let overlay = UIStackView()
    private let diagnostics = UILabel()
    private struct RowSpec {
        let slots: [KeyboardModel.Slot]
        let constraints: [NSLayoutConstraint]
    }
    private var rowSpecs: [RowSpec] = []
    private var shiftButton: KeyButton?
    private var heightConstraint: NSLayoutConstraint!
    private var overlayHeightConstraint: NSLayoutConstraint!

    /// The strip and the toolbar share one slot: icons while nothing is suggested, then
    /// suggestions as soon as there are any, so the keyboard never gains a row.
    private let stripContainer = UIView()
    private let toolbar = UIStackView()
    private let snippetPanel = UITableView(frame: .zero, style: .plain)
    private var snippetPanelHeightConstraint: NSLayoutConstraint!
    private let snippetPanelHeight: CGFloat = 210
    private var panelSnippets: [Snippet] = []
    /// Previews computed once per opening; the list shows what a snippet inserts.
    private var snippetPreviews: [(snippet: Snippet, preview: String, haystack: String)] = []
    private let snippetSearchStrip = UIStackView()
    private let snippetSearchField = UITextField()
    private var snippetSearching = false

    /// The keyboard's own field taking the keys instead of the host, if one is open.
    private var localField: UITextField? {
        if agentMode { return agentField }
        if snippetSearching { return snippetSearchField }
        return nil
    }
    private let overlayHeight: CGFloat = 112

    private var repeatTimer: Timer?
    private var repeatTicks = 0
    private var cursorSteps = 0
    /// The text before the cursor as of the moment word deletion began, trimmed locally as
    /// words are removed. The proxy's own context lags behind deletes we have just sent, so
    /// re-reading it on every step computes word boundaries against stale text.
    private var wordDeleteContext: String?

    /// One popup view serves both purposes, so its mode decides what a release means: a
    /// preview disappears with the finger, an alternates menu commits.
    private enum PopupMode { case none, preview, alternates }
    private var popupMode: PopupMode = .none
    private var popupValues: [String] = []

    // MARK: measurement

    private var latency = TouchLatency()
    private var undelayedRecognizers = 0

    // MARK: probe state

    private var report = ProbeReport()
    private var transcriber: MicTranscriber?
    private var justBash: JustBashHost?
    private let snippets = SnippetEngine()
    /// What the last snippet expansion replaced and inserted, so Backspace can undo it and a
    /// strip tap can swap in a duplicate's other definition.
    private struct Expansion {
        let typed: String
        var inserted: String
        var cursorFromEnd: Int
        let at: Date
    }
    private var lastExpansion: Expansion?
    /// A trigger the user just reverted to; it must not expand again until the word changes.
    private var suppressedTrigger: String?
    private var armTimer: Timer?
    private var lastSpaceTap = Date.distantPast

    // MARK: agent

    /// Agent mode reroutes typing into the strip's own field; the host field is untouched.
    private var agentMode = false
    private var agentRows: [AgentRow] = []
    private var agentStreamTask: Task<Void, Never>?
    private let agentPanel = UITableView(frame: .zero, style: .plain)
    private var agentPanelHeightConstraint: NSLayoutConstraint!
    private let agentStrip = UIStackView()
    private let agentField = UITextField()
    private let agentPanelHeight: CGFloat = 210
    /// Context chips above the prompt: what the next prompt carries besides the question.
    private let agentContextBar = UIStackView()
    private let agentContextHeight: CGFloat = 32
    private var agentContextHeightConstraint: NSLayoutConstraint!
    private struct AgentContext {
        let label: String
        let text: String
    }
    private var agentContexts: [AgentContextSource: AgentContext] = [:]
    private var agentContextButtons: [AgentContextSource: UIButton] = [:]
    private var readingClipboard = false

    // MARK: prediction

    private let predictor = PredictionEngine()
    private var predictionGeneration = 0
    /// Snippet state owns the strip while it is showing; predictions wait their turn.
    private var stripShowsSnippet = false
    private var predictorStatus = "not loaded"
    private var lastPredictionMs: Double?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Transparent: the system's keyboard backdrop shows through (see KeyboardStyle).
        view.backgroundColor = .clear

        report.writer = "keyboard-extension"
        report.appGroupReachable = ProbeStore.container != nil
        report.micStatus = MicProbe.status()
        report.footprintAtLoadMB = physFootprintMB()

        loadSnippets()
        loadPredictor()

        buildStrip()
        buildOverlay()
        rebuildKeyboard()

        buildToolbar()
        buildSnippetPanel()
        buildAgentPanel()
        buildAgentStrip()
        buildAgentContextBar()
        buildSnippetSearchStrip()
        for face in [strip, toolbar, agentStrip, snippetSearchStrip] {
            face.translatesAutoresizingMaskIntoConstraints = false
            stripContainer.addSubview(face)
            NSLayoutConstraint.activate([
                face.leadingAnchor.constraint(equalTo: stripContainer.leadingAnchor),
                face.trailingAnchor.constraint(equalTo: stripContainer.trailingAnchor),
                face.topAnchor.constraint(equalTo: stripContainer.topAnchor),
                face.bottomAnchor.constraint(equalTo: stripContainer.bottomAnchor),
            ])
        }

        let stack = UIStackView(arrangedSubviews: [overlay, snippetPanel, agentPanel, agentContextBar, stripContainer, keyboard])
        stack.axis = .vertical
        stack.spacing = KeyboardModel.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: KeyboardModel.sidePadding),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -KeyboardModel.sidePadding),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: KeyboardModel.gap),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -KeyboardModel.gap),
        ])
        stripContainer.heightAnchor.constraint(equalToConstant: KeyboardModel.stripHeight).isActive = true
        snippetPanel.isHidden = true
        snippetPanelHeightConstraint = snippetPanel.heightAnchor.constraint(equalToConstant: 0)
        snippetPanelHeightConstraint.isActive = true
        agentPanel.isHidden = true
        agentPanelHeightConstraint = agentPanel.heightAnchor.constraint(equalToConstant: 0)
        agentPanelHeightConstraint.isActive = true
        agentContextBar.isHidden = true
        agentContextHeightConstraint = agentContextBar.heightAnchor.constraint(equalToConstant: 0)
        agentContextHeightConstraint.isActive = true
        overlay.isHidden = true
        overlayHeightConstraint = overlay.heightAnchor.constraint(equalToConstant: 0)
        overlayHeightConstraint.isActive = true

        // The popup is anchored to a key, so it lives on the view, not in the stack: a popup
        // that reflows the keyboard is a layout change, not a popup.
        popup.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(popup)

        heightConstraint = view.heightAnchor.constraint(equalToConstant: KeyboardModel.totalHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        flush("extension loaded")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let usable = view.bounds.width - 2 * KeyboardModel.sidePadding
        let unit = KeyboardModel.unitWidth(usable: usable)
        for spec in rowSpecs {
            let widths = KeyboardModel.widths(for: spec.slots, usable: usable, unit: unit)
            for (constraint, width) in zip(spec.constraints, widths) {
                constraint.constant = width
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Haptics.shared.prepare()
        followKeyboardAppearance()
        applyContextualShift()
        requestPredictions()
    }

    /// Hosts can ask for a dark or light keyboard regardless of the system setting; the keys
    /// should match the backdrop the system then draws.
    private func followKeyboardAppearance() {
        switch textDocumentProxy.keyboardAppearance {
        case .dark: overrideUserInterfaceStyle = .dark
        case .light: overrideUserInterfaceStyle = .light
        default: overrideUserInterfaceStyle = .unspecified
        }
    }

    /// The host changed the text or moved the cursor (a tap in the field, a sent message
    /// clearing it): re-derive shift and suggestions. Our own edits land here too, which is
    /// harmless because stale prediction answers are dropped by generation.
    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        followKeyboardAppearance()
        applyContextualShift()
        if !stripShowsSnippet { requestPredictions() }
    }


    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        undelaySystemGestures()
        Haptics.shared.prepare()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        dismissPopup()
        stopRepeating()
        transcriber?.close()
        transcriber = nil
        // The keyboard process outlives the keyboard; the durable store does not need to.
        if agentMode { leaveAgentMode() }
        Task { await KeyboardAgent.shared.close() }
    }

    /// The system installs gesture recognizers above the keyboard (screen-edge and
    /// home-indicator gestures) that can hold back `touchesBegan` until they decide the touch
    /// is not theirs. For a keyboard that is pure latency, felt most on edge keys. Turning
    /// their touch delay off leaves the gestures working; it only stops them withholding
    /// touches. Whether it helps is measured by `latency`, not assumed.
    private func undelaySystemGestures() {
        var changed = 0
        var node: UIView? = view
        while let current = node {
            for recognizer in current.gestureRecognizers ?? [] where recognizer.delaysTouchesBegan {
                recognizer.delaysTouchesBegan = false
                changed += 1
            }
            node = current.superview
        }
        for recognizer in view.window?.gestureRecognizers ?? [] where recognizer.delaysTouchesBegan {
            recognizer.delaysTouchesBegan = false
            changed += 1
        }
        undelayedRecognizers += changed
    }

    // MARK: - keyboard construction

    private func buildStrip() {
        strip.axis = .horizontal
        strip.spacing = KeyboardModel.gap
        strip.distribution = .fillEqually
        for _ in 0..<3 {
            let slot = StripButton(type: .custom)
            slot.setTitleColor(KeyboardStyle.text, for: .normal)
            slot.titleLabel?.font = KeyboardStyle.stripFont
            slot.casting = false
            slot.titleLabel?.lineBreakMode = .byTruncatingTail
            slot.titleLabel?.adjustsFontSizeToFitWidth = true
            slot.titleLabel?.minimumScaleFactor = 0.75
            slot.addTarget(self, action: #selector(stripPressed(_:)), for: .touchDown)
            slot.addTarget(self, action: #selector(stripTapped(_:)), for: .touchUpInside)
            strip.addArrangedSubview(slot)
        }
        showStrip([])
    }

    private func rebuildKeyboard() {
        keyboard.arrangedSubviews.forEach { $0.removeFromSuperview() }
        keyboard.axis = .vertical
        keyboard.spacing = KeyboardModel.rowGap
        keyboard.alignment = .center
        rowSpecs.removeAll()
        shiftButton = nil

        addRow(KeyboardModel.numberRow, height: KeyboardModel.numberRowHeight)
        for row in KeyboardModel.rows(for: layer) { addRow(row, height: KeyboardModel.rowHeight) }
        // The bottom row is function material as a whole, which keeps the period key the same
        // shade as its neighbours instead of taking the letter material.
        addRow(KeyboardModel.bottomRow(layer: layer), height: KeyboardModel.rowHeight, functions: true)
        updateShiftAppearance()
    }

    private func addRow(_ slots: [KeyboardModel.Slot], height: CGFloat, functions: Bool = false) {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = KeyboardModel.gap
        row.alignment = .fill
        var constraints: [NSLayoutConstraint] = []
        for slot in slots {
            let key = makeView(for: slot.key, functions: functions)
            key.heightAnchor.constraint(equalToConstant: height).isActive = true
            let width = key.widthAnchor.constraint(equalToConstant: 0)
            width.isActive = true
            constraints.append(width)
            row.addArrangedSubview(key)
        }
        rowSpecs.append(RowSpec(slots: slots, constraints: constraints))
        keyboard.addArrangedSubview(row)
    }

    private func makeView(for key: KeyboardModel.Key, functions: Bool) -> UIView {
        if case .spacer = key {
            let spacer = UIView()
            spacer.backgroundColor = .clear
            return spacer
        }
        let button = KeyButton(type: .custom)
        button.key = key
        button.material = (functions || isFunction(key)) ? KeyboardStyle.functionKey : KeyboardStyle.letterKey
        button.accessibilityLabel = accessibilityLabel(for: key)

        if let symbol = symbolName(for: key) {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.tintColor = KeyboardStyle.text
        } else {
            button.setTitle(KeyboardModel.label(for: key), for: .normal)
            button.setTitleColor(KeyboardStyle.text, for: .normal)
            button.titleLabel?.font = isFunction(key) ? KeyboardStyle.functionFont : KeyboardStyle.letterFont
        }

        switch key {
        case .space:
            // Hold and drag to move the cursor. A tap never begins the pan, so a tap still
            // inserts a space.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(spacePanned(_:)))
            pan.cancelsTouchesInView = true
            button.addGestureRecognizer(pan)
        case .delete:
            // Hold to remove characters, then whole words, accelerating.
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(deleteHeld(_:)))
            hold.minimumPressDuration = 0.4
            hold.cancelsTouchesInView = true
            button.addGestureRecognizer(hold)
        case .character:
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(characterHeld(_:)))
            hold.minimumPressDuration = 0.35
            // The default is 10pt, which cancels the gesture if the finger starts moving
            // before recognition — exactly what press-and-drag does.
            hold.allowableMovement = 70
            hold.cancelsTouchesInView = true
            button.addGestureRecognizer(hold)
        default:
            break
        }

        button.addTarget(self, action: #selector(keyPressed(_:event:)), for: .touchDown)
        button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        for event: UIControl.Event in [.touchUpOutside, .touchCancel, .touchDragExit] {
            button.addTarget(self, action: #selector(keyReleased(_:)), for: event)
        }
        // VoiceOver gets the alternates too, since they are only reachable by long press.
        let (choices, _) = KeyboardModel.popupValues(for: key, shifted: false)
        if !choices.isEmpty {
            button.accessibilityHint = "Long press for \(choices.joined(separator: " "))"
        }
        if case .shift = key { shiftButton = button }
        return button
    }

    private func isFunction(_ key: KeyboardModel.Key) -> Bool {
        if case .character = key { return false }
        return true
    }

    private func symbolName(for key: KeyboardModel.Key) -> String? {
        switch key {
        case .shift: return isCapsLocked ? "capslock.fill" : (isShifted ? "shift.fill" : "shift")
        case .delete: return "delete.left"
        case .tools: return "ellipsis"
        case .ret: return "return"
        default: return nil
        }
    }

    private func accessibilityLabel(for key: KeyboardModel.Key) -> String {
        switch key {
        case .character(let text): return text
        case .shift: return "shift"
        case .delete: return "delete"
        case .symbols: return "numbers and symbols"
        case .letters: return "letters"
        case .tools: return "byteboard tools"
        case .space: return "space"
        case .ret: return "return"
        case .spacer: return ""
        }
    }

    private func updateShiftAppearance() {
        guard let shiftButton else { return }
        let symbol = isCapsLocked ? "capslock.fill" : (isShifted ? "shift.fill" : "shift")
        shiftButton.setImage(UIImage(systemName: symbol), for: .normal)
    }

    // MARK: - suggestion strip

    /// Strip rule, same as everywhere else: a candidate that exists is drawn in function
    /// material, the one that will fire on its own is drawn in the accent, and an empty slot
    /// draws nothing. Every candidate is tappable.
    private func showStrip(_ items: [StripItem?]) {
        // Agent mode and snippet search own the slot while they are open.
        guard localField == nil else { return }
        // Nothing to suggest: the toolbar takes the slot instead of an empty strip.
        let empty = items.allSatisfy { $0 == nil }
        toolbar.isHidden = !empty
        strip.isHidden = empty
        let buttons = strip.arrangedSubviews.compactMap { $0 as? StripButton }
        for (index, button) in buttons.enumerated() {
            let item = index < items.count ? items[index] : nil
            button.item = item
            button.setTitle(item?.title ?? "", for: .normal)
            button.alpha = item == nil ? 0 : 1
            button.isUserInteractionEnabled = item != nil
            // Bare text like SwiftKey's strip: the likeliest word gets a soft plate and full
            // white, the others sit back in grey; a snippet waiting to fire keeps the accent.
            switch item?.emphasis {
            case .accent?:
                button.material = KeyboardStyle.accent
                button.setTitleColor(.white, for: .normal)
            case .primary?:
                button.material = KeyboardStyle.stripHighlight
                button.setTitleColor(KeyboardStyle.text, for: .normal)
            default:
                button.material = .clear
                button.setTitleColor(KeyboardStyle.secondaryText, for: .normal)
            }
            button.titleLabel?.font = item?.emphasis == .primary ? KeyboardStyle.stripPrimaryFont : KeyboardStyle.stripFont
        }
    }

    /// A trigger that is complete but also the start of longer ones: it, its label, and the
    /// first longer trigger. It fires on its own after a pause.
    private func showArmed(_ match: SnippetEngine.Match) {
        stripShowsSnippet = true
        let longer = snippets.candidates(prefix: match.snippet.trigger, limit: 3)
            .first { $0.trigger != match.snippet.trigger }
        showStrip([
            StripItem(title: match.snippet.trigger, action: .expandSnippet(match.snippet), emphasis: .accent),
            StripItem(title: match.snippet.label, action: .expandSnippet(match.snippet), emphasis: .normal),
            longer.map { StripItem(title: $0.trigger, action: .expandSnippet($0), emphasis: .normal) },
        ])
    }

    /// Mid-trigger: what the typed prefix could become.
    private func showSnippetCandidates(_ candidates: [Snippet]) {
        stripShowsSnippet = true
        showStrip(candidates.prefix(3).map { StripItem(title: $0.trigger, action: .expandSnippet($0), emphasis: .normal) })
    }

    /// After a duplicate trigger expanded: its other definitions, tap to swap.
    private func showVariants(_ variants: [Snippet]) {
        stripShowsSnippet = !variants.isEmpty
        showStrip(variants.prefix(3).map { StripItem(title: $0.label, action: .swapVariant($0), emphasis: .normal) })
    }

    /// Predictions laid out the way SwiftKey does: best in the middle, then left, then right.
    private func showPredictions(_ list: [PredictionEngine.Suggestion]) {
        let items = list.map { StripItem(title: $0.word, action: .word($0.word), emphasis: .normal) }
        var slots: [StripItem?] = [nil, nil, nil]
        for (rank, slot) in [1, 0, 2].enumerated() where rank < items.count {
            slots[slot] = items[rank]
        }
        if let best = slots[1] {
            slots[1] = StripItem(title: best.title, action: best.action, emphasis: .primary)
        }
        showStrip(slots)
    }

    @objc private func stripPressed(_ sender: StripButton) {
        Haptics.shared.selection()
    }

    @objc private func stripTapped(_ sender: StripButton) {
        guard let item = sender.item else { return }
        switch item.action {
        case .expandSnippet(let snippet):
            guard let match = snippets.match(typed: snippet.trigger) else { return }
            // Replace only the trigger text, not whatever word it is attached to.
            let word = currentWord
            let typed = SnippetEngine.triggerSuffix(of: word) ?? word
            expand(match, replacing: typed)
        case .swapVariant(let snippet):
            swapLastExpansion(with: snippet)
        case .word(let word):
            acceptPrediction(word)
        case .notice:
            break
        }
    }

    // MARK: - prediction

    private func loadPredictor() {
        let before = physFootprintMB()
        let loaded = predictor.load(directory: Bundle.main.url(forResource: "dicts", withExtension: nil))
        let after = physFootprintMB()
        let delta = (before != nil && after != nil) ? String(format: "%+.1f MB", after! - before!) : "?"
        predictorStatus = loaded.isEmpty ? "no dictionaries" : "\(loaded.joined(separator: "+")) \(delta)"
    }

    /// The word being typed, as the core sees it: letters, digits, apostrophe and hyphen.
    private var predictionWord: String {
        guard let context = contextBefore else { return "" }
        let word = context.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" }
        return String(word.reversed())
    }

    /// Computes suggestions off the main thread so a slow lookup never sits between a tap
    /// and its letter. Stale answers are dropped by generation.
    private func requestPredictions() {
        stripShowsSnippet = false
        predictionGeneration += 1
        let generation = predictionGeneration
        let before = String((contextBefore ?? "").suffix(160))
        let predictor = self.predictor
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = Date()
            let list = predictor.suggest(before: before, max: 3)
            let ms = Date().timeIntervalSince(started) * 1000
            await self?.receivePredictions(list, generation: generation, ms: ms)
        }
    }

    private func receivePredictions(_ list: [PredictionEngine.Suggestion], generation: Int, ms: Double) {
        guard generation == predictionGeneration, !stripShowsSnippet else { return }
        lastPredictionMs = ms
        showPredictions(list)
    }

    /// Replaces the word being typed (or, after a space, appends) and adds a space, which also
    /// asks for the next word.
    private func acceptPrediction(_ word: String) {
        lastExpansion = nil
        let typed = predictionWord
        for _ in 0..<typed.count { backspace() }
        put(word + " ")
        clearOneShotShift()
        applyContextualShift()
        refreshSnippetState()
    }

    // MARK: - key handling

    /// Haptics fire first, on touch **down**, before any layout work. The event's own
    /// timestamp says when the screen registered the touch, so the gap to this handler is
    /// the latency the system added before we could react — recorded, not guessed.
    @objc private func keyPressed(_ sender: KeyButton, event: UIEvent) {
        // Rollover: a new key landing while a letter is still held commits that letter now,
        // in the order the fingers landed, instead of whenever its finger happens to lift.
        if let held = heldCharacterKey, held !== sender, !held.committedEarly {
            commitEarly(held)
        }
        if case .character = sender.key { heldCharacterKey = sender }
        sendFeedback(for: sender.key)
        let delayMs = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
        latency.record(delayMs, edge: isEdgeKey(sender))
        showPreview(for: sender)
    }

    private func commitEarly(_ key: KeyButton) {
        // Its alternates can no longer open: the letter is already typed.
        for recognizer in key.gestureRecognizers ?? [] {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
        keyTapped(key)
        key.committedEarly = true
        rolloverCommits += 1
    }

    @objc private func keyReleased(_ sender: KeyButton) {
        sender.committedEarly = false
        if heldCharacterKey === sender { heldCharacterKey = nil }
        // A long press cancels the button's touch when it takes over; that must not take
        // the alternates menu down with it.
        if popupMode == .preview { dismissPopup() }
    }

    @objc private func keyTapped(_ sender: KeyButton) {
        if heldCharacterKey === sender { heldCharacterKey = nil }
        // Already typed when the next key landed; its own lift adds nothing.
        if sender.committedEarly {
            sender.committedEarly = false
            return
        }
        dismissPopup()
        // The keyboard's own field owns the keys: text goes there, never to the host.
        if localField != nil {
            switch sender.key {
            case .character(let text):
                put(text)
                clearOneShotShift()
            case .space: put(" ")
            case .delete: backspace()
            case .ret:
                if agentMode {
                    sendAgentPrompt()
                } else if let first = panelSnippets.first {
                    insertFromPanel(first)
                }
            case .shift: handleShift()
            case .symbols:
                layer = .symbols
                rebuildKeyboard()
            case .letters:
                layer = .letters
                rebuildKeyboard()
            default: break
            }
            return
        }
        // Anything that edits text, other than Backspace itself, ends the window in which
        // Backspace undoes the last expansion — otherwise it would delete the wrong text.
        switch sender.key {
        case .character, .space, .ret: lastExpansion = nil
        default: break
        }
        switch sender.key {
        case .character(let text):
            insert(text)
            refreshSnippetState()
        case .shift:
            handleShift()
        case .delete:
            if !revertLastExpansionIfArmed() {
                backspace()
                clearOneShotShift()
            }
            refreshSnippetState()
        case .symbols:
            layer = .symbols
            rebuildKeyboard()
        case .letters:
            layer = .letters
            rebuildKeyboard()
        case .tools:
            toggleTools()
        case .space:
            handleSpace()
            refreshSnippetState()
        case .ret:
            put("\n")
            refreshSnippetState()
        case .spacer:
            break
        }
    }

    private func isEdgeKey(_ key: UIView) -> Bool {
        let frame = key.convert(key.bounds, to: view)
        let margin: CGFloat = 16
        return frame.minX < margin
            || frame.maxX > view.bounds.width - margin
            || frame.maxY > view.bounds.height - KeyboardModel.rowHeight - margin
    }

    // MARK: - snippets

    private func loadSnippets() {
        let bundleURL = Bundle.main.url(forResource: "snippets.local", withExtension: "json")
        let shared = ProbeStore.container?.appendingPathComponent("snippets.json")
        snippets.load(bundleURL: bundleURL, appGroupURL: shared)
    }

    /// The text from the last whitespace before the cursor, which is where a trigger must
    /// live. Falls back to an empty string when the host reports nothing.
    private var currentWord: String {
        guard let context = contextBefore else { return "" }
        guard let last = context.last else { return "" }
        if last.isWhitespace { return "" }
        if let index = context.lastIndex(where: { $0.isWhitespace || $0.isNewline }) {
            return String(context[context.index(after: index)...])
        }
        return String(context.suffix(64))
    }

    /// Called after every insert, delete and cursor move: snippet state first, because a
    /// trigger in progress owns the strip; otherwise predictions.
    private func refreshSnippetState() {
        armTimer?.invalidate()
        armTimer = nil
        // The agent trigger commits on the typed space: the prompt never lands in the host
        // field, so "@pi" is removed from it before the agent field takes over.
        if !agentMode, let context = textDocumentProxy.documentContextBeforeInput {
            let armed = context.hasSuffix("@pi ")
            let bare = context == "@pi"
            if armed || bare {
                for _ in 0..<(bare ? 3 : 4) { textDocumentProxy.deleteBackward() }
                enterAgentMode()
                return
            }
        }
        // The keyboard's own fields get plain typing; snippets and predictions stay with the host.
        if localField != nil { return }
        let word = currentWord

        // A trigger the user just reverted to stays literal until the word changes.
        if let suppressed = suppressedTrigger {
            if word == suppressed {
                showStrip([])
                stripShowsSnippet = true
                return
            }
            suppressedTrigger = nil
        }

        if let match = snippets.match(typed: word), !match.isPrefix {
            expand(match, replacing: word)
            return
        }

        if let match = snippets.match(typed: word), match.isPrefix {
            // Armed but ambiguous: offer it and its extensions, and fire it if the user stops
            // typing for a moment.
            showArmed(match)
            let armed = match
            armTimer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.currentWord == word else { return }
                    self.expand(armed, replacing: word)
                }
            }
            RunLoop.main.add(armTimer!, forMode: .common)
            return
        }

        if let suffix = SnippetEngine.triggerSuffix(of: word) {
            let candidates = snippets.candidates(prefix: suffix, limit: 3)
            if !candidates.isEmpty {
                showSnippetCandidates(candidates)
                return
            }
        }

        requestPredictions()
    }

    /// Expands `match` over `typed`, the text the user wrote for it.
    private func expand(_ match: SnippetEngine.Match, replacing typed: String) {
        let snippet = match.snippet
        guard !typed.isEmpty else { return }

        if snippet.kind == "image" {
            // Images cannot be inserted into a field; they go to the pasteboard. The path is
            // the desktop's, so on the phone the file is usually missing — then the trigger is
            // left alone rather than silently deleted.
            guard let image = UIImage(contentsOfFile: snippet.replace) else {
                showStrip([nil, StripItem(title: "image not on this device", action: .notice, emphasis: .normal), nil])
                stripShowsSnippet = true
                return
            }
            UIPasteboard.general.image = image
            for _ in 0..<typed.count { backspace() }
            showStrip([])
            return
        }

        if snippet.kind == "shell" || snippet.kind == "script" {
            expandShell(snippet, replacing: typed)
            return
        }

        let result = SnippetExpansion.expand(snippet, clipboard: UIPasteboard.general.string)
        for _ in 0..<typed.count { backspace() }
        insertExpansion(result.text, cursorFromEnd: result.cursorFromEnd)
        lastExpansion = Expansion(typed: typed, inserted: result.text, cursorFromEnd: result.cursorFromEnd, at: Date())
        // A duplicate trigger's other definitions stay offered, tap to swap.
        showVariants(Array(match.variants.dropFirst()))
    }

    private func insertExpansion(_ text: String, cursorFromEnd: Int) {
        put(text)
        if cursorFromEnd > 0 {
            moveCursor(by: -cursorFromEnd)
        }
    }

    /// Removes the last expansion's text, leaving the cursor where the expansion began.
    private func removeLastExpansionText(_ expansion: Expansion) {
        if expansion.cursorFromEnd > 0 {
            moveCursor(by: expansion.cursorFromEnd)
        }
        for _ in 0..<expansion.inserted.count { backspace() }
    }

    private func swapLastExpansion(with snippet: Snippet) {
        guard var expansion = lastExpansion else { return }
        let result = SnippetExpansion.expand(snippet, clipboard: UIPasteboard.general.string)
        removeLastExpansionText(expansion)
        insertExpansion(result.text, cursorFromEnd: result.cursorFromEnd)
        expansion.inserted = result.text
        expansion.cursorFromEnd = result.cursorFromEnd
        lastExpansion = expansion
    }

    private func expandShell(_ snippet: Snippet, replacing typed: String) {
        diagnostics.text = "shell…"
        Task { @MainActor in
            if justBash == nil { justBash = JustBashHost() }
            let command = snippet.shellCmd ?? snippet.replace
            let output = await justBash?.run(command) ?? ""
            let text: String
            if let data = output.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let stdout = decoded["stdout"] as? String {
                text = stdout.hasSuffix("\n") ? String(stdout.dropLast()) : stdout
            } else {
                text = output
            }
            for _ in 0..<typed.count { backspace() }
            put(text)
            lastExpansion = Expansion(typed: typed, inserted: text, cursorFromEnd: 0, at: Date())
            showStrip([])
        }
    }

    // MARK: ergonomics — cursor, word delete, alternates

    /// Hold and drag the space bar to move the cursor. `adjustTextPosition` is relative, so
    /// cumulative steps are tracked rather than re-derived from the raw translation.
    @objc private func spacePanned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            cursorSteps = 0
            Haptics.shared.selection()
        case .changed:
            let target = Int((gesture.translation(in: view).x / 14).rounded())
            let delta = target - cursorSteps
            guard delta != 0 else { return }
            moveCursor(by: delta)
            cursorSteps = target
            Haptics.shared.selection()
        default:
            break
        }
    }

    @objc private func deleteHeld(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            repeatTicks = 0
            startRepeating()
        case .ended, .cancelled, .failed:
            stopRepeating()
        default:
            break
        }
    }

    /// Characters briefly, then whole words — SwiftKey and the system keyboard both switch to
    /// words within about half a second. Word steps are slower than character steps so the
    /// finger can stop on the word it wants.
    private static let characterTicks = 5
    private static let characterInterval: TimeInterval = 0.09
    private static let wordInterval: TimeInterval = 0.2

    private func startRepeating() {
        stopRepeating()
        wordDeleteContext = nil
        deleteOneCharacter()
        scheduleRepeat(Self.characterInterval)
    }

    private func scheduleRepeat(_ interval: TimeInterval) {
        repeatTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.repeatTick() }
        }
        // .common keeps it firing while a touch is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        wordDeleteContext = nil
    }

    private func repeatTick() {
        repeatTicks += 1
        if repeatTicks <= Self.characterTicks {
            deleteOneCharacter()
            if repeatTicks == Self.characterTicks { scheduleRepeat(Self.wordInterval) }
        } else {
            deleteWordBackward()
        }
        if repeatTicks > 120 { stopRepeating() }
    }

    private func deleteOneCharacter() {
        backspace()
        Haptics.shared.key()
    }

    /// Deletes the word before the cursor, plus the whitespace between it and the cursor.
    ///
    /// The context is read once per hold and then trimmed locally, because the proxy's
    /// `documentContextBeforeInput` does not yet reflect the deletes we have just sent. It is
    /// re-read only when the local copy runs out, since the proxy exposes a limited window.
    /// A host that reports no context gets single characters rather than a guess.
    private func deleteWordBackward() {
        if wordDeleteContext?.isEmpty ?? true {
            wordDeleteContext = contextBefore
        }
        guard let context = wordDeleteContext, !context.isEmpty else {
            deleteOneCharacter()
            return
        }
        let count = Self.lastWordLength(in: context)
        for _ in 0..<count { backspace() }
        wordDeleteContext = String(context.dropLast(count))
        Haptics.shared.key()
    }

    /// Trailing whitespace, then the word before it. Punctuation attached to a word goes with
    /// it, which matches both reference keyboards. Always at least one character.
    static func lastWordLength(in context: String) -> Int {
        var count = 0
        var index = context.endIndex
        while index > context.startIndex, context[context.index(before: index)].isWhitespace {
            index = context.index(before: index)
            count += 1
        }
        while index > context.startIndex, !context[context.index(before: index)].isWhitespace {
            index = context.index(before: index)
            count += 1
        }
        return max(1, count)
    }

    @objc private func characterHeld(_ gesture: UILongPressGestureRecognizer) {
        guard let button = gesture.view as? KeyButton else { return }
        switch gesture.state {
        case .began:
            let (values, baseIndex) = KeyboardModel.popupValues(
                for: button.key, shifted: isShifted || isCapsLocked)
            guard !values.isEmpty else { return }
            Haptics.shared.selection()
            popupValues = values
            popupMode = .alternates
            popup.showAlternates(values, baseIndex: baseIndex,
                                 itemWidth: KeyboardModel.popupItemWidth,
                                 keyFrame: button.convert(button.bounds, to: view),
                                 in: view.bounds)
        case .changed:
            guard popupMode == .alternates,
                  let index = popup.nearestIndex(to: gesture.location(in: view), from: view),
                  index != popup.selectedIndex else { return }
            popup.select(index)
            Haptics.shared.selection()
        case .ended:
            commitPopup()
        default:
            dismissPopup()
        }
    }

    // MARK: popup

    /// The enlarged character growing out of the pressed key. Character keys only: the
    /// system keyboard shows no bubble for shift, delete or return.
    private func showPreview(for key: KeyButton) {
        guard case .character(let text) = key.key else { return }
        popupMode = .preview
        popup.showPreview((isShifted || isCapsLocked) ? text.uppercased() : text,
                          keyFrame: key.convert(key.bounds, to: view),
                          in: view.bounds)
    }

    private func commitPopup() {
        if popupMode == .alternates, let index = popup.selectedIndex,
           popupValues.indices.contains(index) {
            put(popupValues[index])
            clearOneShotShift()
        }
        dismissPopup()
    }

    private func dismissPopup() {
        popupMode = .none
        popupValues = []
        popup.dismiss()
    }

    /// A tap on a modifier should feel different from a character.
    private func sendFeedback(for key: KeyboardModel.Key) {
        switch key {
        case .character, .delete, .space, .ret:
            Haptics.shared.key()
        case .shift, .symbols, .letters, .tools:
            Haptics.shared.selection()
        case .spacer:
            break
        }
    }

    private func insert(_ text: String) {
        let output = (isShifted || isCapsLocked) ? text.uppercased() : text
        put(output)
        clearOneShotShift()
        applyContextualShift()
    }

    private func handleSpace() {
        // Double-space period: a second space inside the double-tap window, where the first
        // space followed a word character, becomes ". ". URL and email fields opt out.
        let now = Date()
        let context = contextBefore ?? ""
        if !isURLOrEmailField, now.timeIntervalSince(lastSpaceTap) < 0.35,
           context.hasSuffix(" "), context.count >= 2 {
            let beforePrevious = context[context.index(context.endIndex, offsetBy: -2)]
            if !beforePrevious.isWhitespace {
                backspace()
                put(". ")
                isShifted = true
                updateShiftAppearance()
                lastSpaceTap = .distantPast
                return
            }
        }
        lastSpaceTap = now
        put(" ")
        clearOneShotShift()
        applyContextualShift()
    }

    private var isURLOrEmailField: Bool {
        textDocumentProxy.keyboardType == .URL || textDocumentProxy.keyboardType == .emailAddress
    }

    /// One-shot shift for the start of sentences: beginning of the field, after `. ` / `! ` /
    /// `? ` / a newline. Hosts that request no capitalisation are left alone.
    private func applyContextualShift() {
        guard !isCapsLocked else { return }
        let autocap = textDocumentProxy.autocapitalizationType
        guard autocap != .none else { return }
        let context = contextBefore
        let shouldShift: Bool
        if context == nil || context?.isEmpty == true {
            shouldShift = true
        } else if let context {
            shouldShift = context.hasSuffix(". ") || context.hasSuffix("! ")
                || context.hasSuffix("? ") || context.hasSuffix("\n")
        } else {
            shouldShift = false
        }
        if shouldShift != isShifted {
            isShifted = shouldShift
            updateShiftAppearance()
        }
    }

    /// Backspace right after an expansion replaces it with the trigger the user typed, which
    /// then stays literal instead of expanding again.
    private func revertLastExpansionIfArmed() -> Bool {
        guard let expansion = lastExpansion else { return false }
        lastExpansion = nil
        guard Date().timeIntervalSince(expansion.at) < 6 else { return false }
        // Only undo if the expansion is still exactly what sits before the cursor. A tap that
        // moved the cursor, or an edit we did not see, means Backspace is just Backspace.
        let before = contextBefore ?? ""
        let expectedBefore = String(expansion.inserted.dropLast(expansion.cursorFromEnd))
        guard before.hasSuffix(expectedBefore) else { return false }
        removeLastExpansionText(expansion)
        put(expansion.typed)
        if !expansion.typed.isEmpty { suppressedTrigger = expansion.typed }
        return true
    }

    private func handleShift() {
        let now = Date()
        if now.timeIntervalSince(lastShiftTap) < 0.4 {
            isCapsLocked.toggle()
            isShifted = isCapsLocked
        } else {
            isCapsLocked = false
            isShifted.toggle()
        }
        lastShiftTap = now
        updateShiftAppearance()
    }

    private func clearOneShotShift() {
        guard isShifted, !isCapsLocked else { return }
        isShifted = false
        updateShiftAppearance()
    }

    private func toggleTools() {
        overlay.isHidden.toggle()
        if !overlay.isHidden { snippetPanel.isHidden = true }
        updateKeyboardHeight()
        if !overlay.isHidden { refreshDiagnostics(note: "tools") }
    }

    private func toggleSnippetPanel() {
        snippetPanel.isHidden.toggle()
        snippetSearching = !snippetPanel.isHidden
        if snippetSearching {
            overlay.isHidden = true
            snippetPreviews = snippets.bundle.entries.map { snippet in
                let preview = SnippetSearch.preview(snippet)
                return (snippet, preview, SnippetSearch.fold("\(preview) \(snippet.label) \(snippet.trigger)"))
            }
            snippetSearchField.text = ""
            toolbar.isHidden = true
            strip.isHidden = true
            snippetSearchStrip.isHidden = false
            filterSnippets()
        } else {
            snippetSearchStrip.isHidden = true
            requestPredictions()
        }
        updateKeyboardHeight()
    }

    /// Fuzzy search over what the snippets insert (and their labels and triggers, which are
    /// searchable but not shown).
    private func filterSnippets() {
        let query = snippetSearchField.text ?? ""
        panelSnippets = SnippetSearch.rank(snippetPreviews, query: query).map(\.snippet)
        snippetPanel.reloadData()
        if !panelSnippets.isEmpty {
            snippetPanel.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        }
    }

    private func buildSnippetSearchStrip() {
        snippetSearchStrip.axis = .horizontal
        snippetSearchStrip.spacing = 8
        snippetSearchStrip.isHidden = true
        let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let glass = UIImageView(image: UIImage(systemName: "magnifyingglass", withConfiguration: configuration))
        glass.tintColor = KeyboardStyle.secondaryText
        glass.contentMode = .center
        glass.frame = CGRect(x: 0, y: 0, width: 32, height: 20)
        snippetSearchField.leftView = glass
        snippetSearchField.leftViewMode = .always
        snippetSearchField.backgroundColor = KeyboardStyle.functionKey
        snippetSearchField.textColor = KeyboardStyle.text
        snippetSearchField.font = .systemFont(ofSize: 15)
        snippetSearchField.layer.cornerRadius = KeyboardStyle.keyRadius
        snippetSearchField.attributedPlaceholder = NSAttributedString(
            string: "search snippets",
            attributes: [.foregroundColor: KeyboardStyle.secondaryText])
        snippetSearchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19)), for: .normal)
        close.tintColor = KeyboardStyle.secondaryText
        close.accessibilityLabel = "Close snippets"
        close.widthAnchor.constraint(equalToConstant: 36).isActive = true
        close.addTarget(self, action: #selector(closeSnippetPanelTapped), for: .touchUpInside)
        snippetSearchStrip.addArrangedSubview(snippetSearchField)
        snippetSearchStrip.addArrangedSubview(close)
    }

    @objc private func closeSnippetPanelTapped() {
        Haptics.shared.selection()
        if !snippetPanel.isHidden { toggleSnippetPanel() }
    }

    /// The keys plus whichever panels are open. A hidden arranged subview is laid out at
    /// zero, so each panel's own height constraint has to follow it or the two disagree.
    private func updateKeyboardHeight() {
        overlayHeightConstraint.constant = overlay.isHidden ? 0 : overlayHeight
        snippetPanelHeightConstraint.constant = snippetPanel.isHidden ? 0 : snippetPanelHeight
        agentPanelHeightConstraint.constant = agentPanel.isHidden ? 0 : agentPanelHeight
        agentContextHeightConstraint.constant = agentContextBar.isHidden ? 0 : agentContextHeight
        var height = KeyboardModel.totalHeight
        if !agentContextBar.isHidden { height += agentContextHeight + KeyboardModel.gap }
        if !overlay.isHidden { height += overlayHeight + KeyboardModel.gap }
        if !snippetPanel.isHidden { height += snippetPanelHeight + KeyboardModel.gap }
        if !agentPanel.isHidden { height += agentPanelHeight + KeyboardModel.gap }
        heightConstraint.constant = height
    }

    // MARK: agent mode

    private var piStatusText = "idle"

    private func buildAgentPanel() {
        agentPanel.backgroundColor = .clear
        agentPanel.separatorStyle = .none
        agentPanel.rowHeight = UITableView.automaticDimension
        agentPanel.estimatedRowHeight = 44
        agentPanel.dataSource = self
        agentPanel.delegate = self
        agentPanel.layer.cornerRadius = KeyboardStyle.keyRadius
        agentPanel.register(UITableViewCell.self, forCellReuseIdentifier: "agent")
        Self.clearEdgeEffects(agentPanel)
    }

    /// iOS 26 blurs whatever scrolls under a scroll view's edges. Inside the keyboard that
    /// smeared the first line of the panels; the panel's own inset keeps it off the edge.
    static func clearEdgeEffects(_ scrollView: UIScrollView) {
        if #available(iOS 26.0, *) {
            scrollView.topEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
        }
        scrollView.contentInset.top = 6
    }

    private func buildAgentStrip() {
        agentStrip.axis = .horizontal
        agentStrip.spacing = 8
        agentStrip.alignment = .fill
        agentStrip.isHidden = true
        agentField.placeholder = "ask @pi"
        agentField.backgroundColor = KeyboardStyle.functionKey
        agentField.textColor = KeyboardStyle.text
        agentField.attributedPlaceholder = NSAttributedString(
            string: "ask @pi",
            attributes: [.foregroundColor: KeyboardStyle.secondaryText])
        agentField.font = .systemFont(ofSize: 15)
        agentField.returnKeyType = .send
        agentField.enablesReturnKeyAutomatically = true
        agentField.delegate = self
        agentField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        agentField.leftViewMode = .always
        agentField.layer.cornerRadius = KeyboardStyle.keyRadius
        // Plain glyphs like the toolbar icons: chrome, not keys.
        let configuration = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        let send = UIButton(type: .system)
        send.setImage(UIImage(systemName: "arrow.up.circle.fill", withConfiguration: configuration), for: .normal)
        send.tintColor = KeyboardStyle.text
        send.accessibilityLabel = "Send"
        send.widthAnchor.constraint(equalToConstant: 40).isActive = true
        send.addTarget(self, action: #selector(sendAgentPrompt), for: .touchUpInside)
        let fresh = UIButton(type: .system)
        fresh.setImage(UIImage(systemName: "square.and.pencil", withConfiguration: configuration), for: .normal)
        fresh.tintColor = KeyboardStyle.text
        fresh.accessibilityLabel = "New session"
        fresh.widthAnchor.constraint(equalToConstant: 40).isActive = true
        fresh.addTarget(self, action: #selector(newAgentSession), for: .touchUpInside)
        let exit = UIButton(type: .system)
        exit.widthAnchor.constraint(equalToConstant: 36).isActive = true
        exit.setImage(UIImage(systemName: "xmark", withConfiguration: configuration), for: .normal)
        exit.tintColor = KeyboardStyle.secondaryText
        exit.accessibilityLabel = "Leave agent"
        exit.addTarget(self, action: #selector(exitAgentTapped), for: .touchUpInside)
        agentField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        send.setContentHuggingPriority(.required, for: .horizontal)
        exit.setContentHuggingPriority(.required, for: .horizontal)
        agentStrip.addArrangedSubview(agentField)
        agentStrip.addArrangedSubview(send)
        agentStrip.addArrangedSubview(fresh)
        agentStrip.addArrangedSubview(exit)
    }

    /// `@pi` was typed: the prompt lives in the keyboard's own field, never in the host.
    private func enterAgentMode() {
        agentMode = true
        snippetPanel.isHidden = true
        overlay.isHidden = true
        toolbar.isHidden = true
        strip.isHidden = true
        agentStrip.isHidden = false
        agentPanel.isHidden = false
        agentContextBar.isHidden = false
        agentContexts = [:]
        refreshContextChips()
        agentField.text = ""
        updateKeyboardHeight()
        agentField.becomeFirstResponder()
        piStatusText = "opening"
        agentStreamTask?.cancel()
        agentStreamTask = Task { [weak self] in
            let agent = KeyboardAgent.shared
            if let reason = await agent.openIfNeeded() {
                await MainActor.run { self?.showAgentNotice(reason) }
                return
            }
            await MainActor.run { self?.recordAgentStatus() }
            do {
                for try await rows in await agent.rowStream() {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.renderAgentRows(rows) }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.showAgentNotice(String(describing: error)) }
            }
        }
    }

    private func leaveAgentMode() {
        agentMode = false
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStrip.isHidden = true
        agentField.resignFirstResponder()
        agentPanel.isHidden = true
        agentContextBar.isHidden = true
        agentContexts = [:]
        updateKeyboardHeight()
        requestPredictions()
    }

    // MARK: agent context and answer actions

    private func buildAgentContextBar() {
        agentContextBar.axis = .horizontal
        agentContextBar.spacing = 8
        agentContextBar.alignment = .fill
        agentContextBar.distribution = .fillProportionally
        for source in AgentContextSource.allCases {
            let button = UIButton(type: .system)
            button.tag = source.rawValue
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
            button.layer.cornerRadius = agentContextHeight / 2
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            button.addTarget(self, action: #selector(contextChipTapped(_:)), for: .touchUpInside)
            agentContextButtons[source] = button
            agentContextBar.addArrangedSubview(button)
        }
        // Chips hug the left; the spacer takes the rest.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        agentContextBar.addArrangedSubview(spacer)
        refreshContextChips()
    }

    private func refreshContextChips() {
        for (source, button) in agentContextButtons {
            let attached = agentContexts[source]
            let title: String
            if source == .clipboard, readingClipboard {
                title = "reading clipboard..."
            } else if let attached {
                let words = attached.text.split(whereSeparator: \.isWhitespace).count
                title = "\(attached.label) \u{00B7} \(words) words  \u{2715}"
            } else {
                title = "+ \(source.title)"
            }
            button.setTitle(title, for: .normal)
            button.tintColor = attached == nil ? KeyboardStyle.text : .white
            button.backgroundColor = attached == nil ? KeyboardStyle.functionKey : KeyboardStyle.accent
        }
    }

    @objc private func contextChipTapped(_ sender: UIButton) {
        guard let source = AgentContextSource(rawValue: sender.tag) else { return }
        Haptics.shared.selection()
        if agentContexts[source] != nil {
            agentContexts[source] = nil
            refreshContextChips()
            return
        }
        switch source {
        case .field:
            // The host field around the cursor: iOS hands a keyboard a window of text, not
            // necessarily the whole document.
            let proxy = textDocumentProxy
            let parts = [proxy.documentContextBeforeInput, proxy.selectedText, proxy.documentContextAfterInput]
                .compactMap { $0 }
            let text = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                showAgentNotice("The text field is empty, or the app does not share its text with keyboards.")
                return
            }
            let label = proxy.selectedText?.isEmpty == false ? "selection" : "field"
            let chosen = proxy.selectedText?.isEmpty == false ? proxy.selectedText! : text
            agentContexts[.field] = AgentContext(label: label, text: chosen)
            refreshContextChips()
        case .clipboard:
            attachClipboard()
        }
    }

    /// Copied text as-is; a copied image (a screenshot: tap its thumbnail, then Copy and
    /// Delete) is read with Vision's on-device text recognition.
    private func attachClipboard() {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, let image = pasteboard.image, let cgImage = image.cgImage {
            readingClipboard = true
            refreshContextChips()
            let start = Date()
            Task.detached(priority: .userInitiated) { [weak self] in
                let text = Self.recognizeText(in: cgImage)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                await MainActor.run {
                    guard let self else { return }
                    self.readingClipboard = false
                    if text.isEmpty {
                        self.showAgentNotice("No text found in the copied image.")
                    } else {
                        self.agentContexts[.clipboard] = AgentContext(label: "screenshot", text: text)
                    }
                    self.piStatusText = "ocr \(ms) ms, \(text.count) chars"
                    self.refreshContextChips()
                }
            }
            return
        }
        if let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            agentContexts[.clipboard] = AgentContext(label: "clipboard", text: text)
            refreshContextChips()
            return
        }
        showAgentNotice("The clipboard is empty. For screen context: take a screenshot, tap its thumbnail, then Copy and Delete.")
    }

    nonisolated static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "en-US", "es-ES"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    @objc private func insertAnswerTapped(_ sender: UIButton) {
        guard agentRows.indices.contains(sender.tag) else { return }
        Haptics.shared.selection()
        insertAgentRow(agentRows[sender.tag])
    }

    @objc private func copyAnswerTapped(_ sender: UIButton) {
        guard agentRows.indices.contains(sender.tag) else { return }
        Haptics.shared.selection()
        UIPasteboard.general.string = agentRows[sender.tag].text
        let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        sender.setImage(UIImage(systemName: "checkmark", withConfiguration: configuration), for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            sender.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: configuration), for: .normal)
        }
    }

    /// The answer actions: insert at the host cursor, or copy.
    private func answerActions(row index: Int) -> UIView {
        let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        func button(_ symbol: String, _ label: String, _ action: Selector) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
            button.tintColor = KeyboardStyle.text
            button.accessibilityLabel = label
            button.tag = index
            button.addTarget(self, action: action, for: .touchUpInside)
            button.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
            return button
        }
        let insert = button("text.insert", "Insert", #selector(insertAnswerTapped(_:)))
        let copy = button("doc.on.doc", "Copy", #selector(copyAnswerTapped(_:)))
        copy.frame.origin.x = 38
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 74, height: 36))
        container.addSubview(insert)
        container.addSubview(copy)
        return container
    }

    /// Inserts an answer at the cursor in the host and leaves agent mode.
    private func insertAgentRow(_ row: AgentRow) {
        guard !row.text.isEmpty else { return }
        lastExpansion = nil
        textDocumentProxy.insertText(row.text)
        leaveAgentMode()
    }

    // MARK: text output

    /// Every edit goes through these three, so nothing can reach the host while the agent
    /// prompt is open: long-press alternates, word delete, double-space period, the space-bar
    /// cursor, strip and snippet inserts all follow the same target.
    /// The text before the cursor in whichever field is being typed into.
    private var contextBefore: String? {
        guard let field = localField else { return textDocumentProxy.documentContextBeforeInput }
        guard let text = field.text, let range = field.selectedTextRange else { return field.text }
        let offset = field.offset(from: field.beginningOfDocument, to: range.start)
        return String(text.prefix(offset))
    }

    private func put(_ text: String) {
        if let field = localField { field.insertText(text) } else { textDocumentProxy.insertText(text) }
        if snippetSearching { filterSnippets() }
    }

    private func backspace() {
        if let field = localField { field.deleteBackward() } else { textDocumentProxy.deleteBackward() }
        if snippetSearching { filterSnippets() }
    }

    private func moveCursor(by offset: Int) {
        guard let field = localField else {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            return
        }
        guard let range = field.selectedTextRange,
              let moved = field.position(from: range.start, offset: offset) else { return }
        field.selectedTextRange = field.textRange(from: moved, to: moved)
    }

    @objc private func newAgentSession() {
        Haptics.shared.selection()
        Task { [weak self] in
            do {
                try await KeyboardAgent.shared.newSession()
            } catch {
                await MainActor.run { self?.showAgentNotice(String(describing: error)) }
            }
        }
    }

    @objc private func exitAgentTapped() {
        Haptics.shared.selection()
        leaveAgentMode()
    }

    @objc private func sendAgentPrompt() {
        let question = (agentField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let prompt = AgentPrompt.compose(
            question: question,
            contexts: AgentContextSource.allCases.compactMap { source in
                agentContexts[source].map { ($0.label, $0.text) }
            })
        agentField.text = ""
        agentContexts = [:]
        refreshContextChips()
        Haptics.shared.selection()
        Task { [weak self] in
            do {
                try await KeyboardAgent.shared.send(prompt)
            } catch {
                await MainActor.run { self?.showAgentNotice(String(describing: error)) }
            }
            await MainActor.run { self?.recordAgentStatus() }
        }
    }

    private func renderAgentRows(_ rows: [AgentRow]) {
        agentRows = rows
        agentPanel.reloadData()
        if !rows.isEmpty {
            let last = IndexPath(row: rows.count - 1, section: 0)
            agentPanel.scrollToRow(at: last, at: .bottom, animated: false)
        }
    }

    private func showAgentNotice(_ text: String) {
        renderAgentRows([AgentRow(id: "notice", role: "notice", text: text, failed: true, live: false)])
    }

    private func recordAgentStatus() {
        Task { [weak self] in
            let status = await KeyboardAgent.shared.status()
            await MainActor.run {
                guard let self else { return }
                if let reason = status.reason {
                    self.piStatusText = reason
                } else {
                    self.piStatusText = "open \(status.openMilliseconds ?? -1) ms"
                        + "  turn \(status.lastTurnMilliseconds.map { String($0) } ?? "-") ms"
                        + (status.footprintDeltaMB.map { String(format: "  +%.1f MB", $0) } ?? "")
                }
                self.refreshDiagnostics(note: "agent")
            }
        }
    }

    // MARK: - toolbar

    private func buildToolbar() {
        toolbar.axis = .horizontal
        toolbar.distribution = .fill
        toolbar.alignment = .fill
        // SwiftKey's rhythm: fixed slots rather than icons stretched across the width,
        // glyphs about the size of a letter, near-white. Hide sits apart at the far end.
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        for tool in ToolbarTool.allCases {
            let button = ToolbarButton(type: .system)
            button.tool = tool
            let image = tool.symbol.map { UIImage(systemName: $0, withConfiguration: configuration) }
                ?? UIImage(named: "pi-icon")?.withRenderingMode(.alwaysTemplate)
            button.setImage(image, for: .normal)
            button.tintColor = KeyboardStyle.text.withAlphaComponent(0.9)
            button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            if tool == .hide {
                let spacer = UIView()
                spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
                toolbar.addArrangedSubview(spacer)
            }
            button.accessibilityLabel = tool.label
            button.addTarget(self, action: #selector(toolbarPressed(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(toolbarTapped(_:)), for: .touchUpInside)
            toolbar.addArrangedSubview(button)
        }
    }

    @objc private func toolbarPressed(_ sender: ToolbarButton) {
        Haptics.shared.selection()
    }

    @objc private func toolbarTapped(_ sender: ToolbarButton) {
        switch sender.tool {
        case .pi:
            enterAgentMode()
        case .snippets:
            toggleSnippetPanel()
        case .paste:
            // Reading the pasteboard is a deliberate tap, so iOS may ask to allow it once.
            guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
            lastExpansion = nil
            put(text)
            refreshSnippetState()
        case .hide:
            dismissKeyboard()
        }
    }

    // MARK: - snippet panel

    private func buildSnippetPanel() {
        snippetPanel.backgroundColor = .clear
        snippetPanel.separatorColor = KeyboardStyle.functionKey
        snippetPanel.rowHeight = 44
        snippetPanel.dataSource = self
        snippetPanel.delegate = self
        snippetPanel.layer.cornerRadius = KeyboardStyle.keyRadius
        snippetPanel.register(UITableViewCell.self, forCellReuseIdentifier: "snippet")
        Self.clearEdgeEffects(snippetPanel)
    }

    /// Inserts a snippet chosen from the list at the cursor: nothing typed to replace.
    private func insertFromPanel(_ snippet: Snippet) {
        // Close the search first: while it is open, put() would type into the search field.
        toggleSnippetPanel()
        switch snippet.kind {
        case "image":
            if let image = UIImage(contentsOfFile: snippet.replace) {
                UIPasteboard.general.image = image
            }
        case "shell", "script":
            expandShell(snippet, replacing: "")
        default:
            let result = SnippetExpansion.expand(snippet, clipboard: UIPasteboard.general.string)
            insertExpansion(result.text, cursorFromEnd: result.cursorFromEnd)
            lastExpansion = Expansion(typed: "", inserted: result.text, cursorFromEnd: result.cursorFromEnd, at: Date())
        }
        refreshSnippetState()
    }

    // MARK: - tools overlay (the probe, moved)

    private func buildOverlay() {
        diagnostics.font = KeyboardStyle.diagnosticsFont
        diagnostics.textColor = KeyboardStyle.secondaryText
        diagnostics.numberOfLines = 0

        let feel = makeTool("Feel it", #selector(feelHaptics))
        feel.addGestureRecognizer(UILongPressGestureRecognizer(
            target: self, action: #selector(cycleHaptics(_:))))
        feel.accessibilityHint = "Tap to feel the current strength, long press to change it"

        let buttons = [
            makeTool("Probe", #selector(probeNow)),
            makeTool("Mic", #selector(requestMic)),
            makeTool("Capture", #selector(captureNow)),
            makeTool("Model", #selector(loadModel)),
            makeTool("bash", #selector(runJustBash)),
            makeTool("Agent", #selector(runAgentModel)),
            feel,
            makeTool("Next kb", #selector(advanceToNextInputMode)),
        ]
        let grid = UIStackView(arrangedSubviews: [
            row(of: Array(buttons[0..<4])),
            row(of: Array(buttons[4..<8])),
        ])
        grid.axis = .vertical
        grid.spacing = KeyboardModel.gap
        grid.distribution = .fillEqually

        overlay.axis = .vertical
        overlay.spacing = KeyboardModel.gap
        overlay.addArrangedSubview(diagnostics)
        overlay.addArrangedSubview(grid)
    }

    private func row(of views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = KeyboardModel.gap
        stack.distribution = .fillEqually
        return stack
    }

    /// A tools button is a function key: same material, radius, shadow and pressed shade.
    private func makeTool(_ title: String, _ action: Selector) -> MaterialButton {
        let button = MaterialButton(type: .custom)
        button.material = KeyboardStyle.functionKey
        button.setTitle(title, for: .normal)
        button.setTitleColor(KeyboardStyle.text, for: .normal)
        button.titleLabel?.font = KeyboardStyle.toolFont
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.addTarget(self, action: #selector(toolPressed), for: .touchDown)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func toolPressed() {
        Haptics.shared.selection()
    }

    @objc private func probeNow() {
        report.micStatus = MicProbe.status()
        report.appGroupReachable = ProbeStore.container != nil
        flush("probed")
    }

    @objc private func requestMic() {
        Task { @MainActor in
            let result = await MicProbe.request()
            report.micRequestResult = result
            report.micStatus = MicProbe.status()
            flush("mic request returned \(result)")
        }
    }

    @objc private func captureNow() {
        diagnostics.text = "capturing…"
        Task { @MainActor in
            let outcome = await CaptureProbe.capture()
            report.captureResult = outcome
            flush("capture: \(outcome)")
        }
    }

    @objc private func loadModel() {
        Task { @MainActor in
            do {
                let directory = try modelDirectory()
                let spec = ModelSpec.stt(language: "en", modelArch: .tinyStreaming)
                _ = try await AssetDownloader().ensureModelPresent(
                    root: directory, spec: spec, onProgress: { _ in }
                )
                let candidate = MicTranscriber().language("en").modelArch(.tinyStreaming).modelsFrom(directory)
                try await candidate.load()
                transcriber?.close()
                transcriber = candidate
                report.footprintAfterModelMB = physFootprintMB()
                flush("model loaded")
            } catch {
                report.notes.append("model failed: \(error)")
                flush("model failed")
            }
        }
    }

    @objc private func runJustBash() {
        diagnostics.text = "just-bash…"
        Task { @MainActor in
            if justBash == nil { justBash = JustBashHost() }
            let result = await justBash?.run(
                "echo extension-ok && printf 'a\\nb\\nc\\n' | grep b && echo 'x y z' | wc -w"
            ) ?? "no host"
            report.justBashResult = result
            report.justBashFootprintMB = physFootprintMB()
            flush("just-bash: \(result)")
        }
    }

    @objc private func runAgentModel() {
        diagnostics.text = "agent model…"
        Task { @MainActor in
            let result = await AgentModelProbe.describe()
            report.agentModelResult = result
            flush("agent model: \(result)")
        }
    }

    /// Confirms by hand whether the extension can drive the Taptic Engine at all.
    @objc private func feelHaptics() {
        Haptics.shared.strong()
        flush("haptics: \(Haptics.shared.describe)")
    }

    /// Long press cycles off → light → medium → heavy, firing a sample each time so the
    /// choice is made in the hand rather than in the abstract.
    @objc private func cycleHaptics(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        _ = Haptics.shared.cycleStrength()
        Haptics.shared.strong()
        flush("haptics: \(Haptics.shared.describe)")
    }

    private func modelDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("tiny-streaming-en", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func flush(_ note: String) {
        let now = physFootprintMB() ?? -1
        report.updatedAt = Date()
        report.touchLatency = latency.summary
        report.notes.append("line\(report.notes.count + 1) \(note): \(String(format: "%.1f", now)) MB")
        ProbeStore.write(report)
        refreshDiagnostics(note: note)
    }

    private func refreshDiagnostics(note: String) {
        let now = physFootprintMB() ?? -1
        diagnostics.text = """
        \(note)  now \(String(format: "%.1f", now)) MB  atload \(String(format: "%.1f", report.footprintAtLoadMB ?? -1))
        \(latency.summary)  gates undelayed \(undelayedRecognizers)
        touch gap-rescued \(keyboard.rescuedTouches)  rollover \(rolloverCommits)
        predict \(predictorStatus)  last \(lastPredictionMs.map { String(format: "%.1f ms", $0) } ?? "-")
        bash \(report.justBashResult ?? "-")
        agent \(report.agentModelResult ?? "-")
        pi \(piStatusText)
        \(Haptics.shared.describe)
        """
    }
}

/// A button in one of the two key materials. The pressed shade comes from the highlight
/// state UIKit already tracks, so it can never be left stuck.
class MaterialButton: UIButton {
    var material: UIColor = KeyboardStyle.functionKey {
        didSet { refresh() }
    }
    /// Keys cast a shadow; bare chrome such as strip suggestions does not.
    var casting = true {
        didSet { setNeedsLayout() }
    }

    override var isHighlighted: Bool {
        didSet { refresh() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = KeyboardStyle.keyRadius
        // No clipping: the shadow sits outside the bounds. The background colour still
        // honours the corner radius without masking.
        clipsToBounds = false
        adjustsImageWhenHighlighted = false
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        backgroundColor = isHighlighted ? KeyboardStyle.pressed(material) : material
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard casting else {
            layer.shadowOpacity = 0
            return
        }
        KeyboardStyle.applyShadow(
            to: layer,
            path: UIBezierPath(roundedRect: bounds, cornerRadius: KeyboardStyle.keyRadius).cgPath)
    }
}

/// A key that knows what it is.
private final class KeyButton: MaterialButton {
    var key: KeyboardModel.Key = .spacer
    var committedEarly = false
}

/// The key area. A touch in the gap between keys, or in a row's inset, belongs to the nearest
/// key instead of to nothing: on glass a near miss should still type.
private final class KeyGrid: UIStackView {
    private(set) var rescuedTouches = 0
    /// Farther than this from every key, a touch is not meant for one.
    private let reach: CGFloat = 20

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit is KeyButton { return hit }
        guard covers(point) else { return hit }
        var best: (key: KeyButton, distance: CGFloat)?
        for case let row as UIStackView in arrangedSubviews {
            for case let key as KeyButton in row.arrangedSubviews where !key.isHidden {
                let frame = key.convert(key.bounds, to: self)
                let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
                let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
                let distance = dx * dx + dy * dy
                if best == nil || distance < best!.distance { best = (key, distance) }
            }
        }
        guard let best, best.distance <= reach * reach else { return hit }
        // Only count an actual touch, not UIKit's repeated hit tests for the same one.
        if event?.type == .touches, event?.allTouches?.contains(where: { $0.phase == .began }) == true {
            rescuedTouches += 1
        }
        return best.key
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        covers(point)
    }

    /// Sideways and below, never above: the strip sits directly over the number row and its
    /// taps must stay its own.
    private func covers(_ point: CGPoint) -> Bool {
        point.y >= bounds.minY && point.y <= bounds.maxY + reach
            && point.x >= bounds.minX - reach && point.x <= bounds.maxX + reach
    }
}

/// What a suggestion-strip slot does when tapped.
private enum StripAction {
    /// Expand this snippet over the trigger text being typed.
    case expandSnippet(Snippet)
    /// Replace the last expansion with this other definition of the same trigger.
    case swapVariant(Snippet)
    /// Replace the word being typed with this one.
    case word(String)
    /// Information only.
    case notice
}

private struct StripItem {
    enum Emphasis { case normal, primary, accent }
    let title: String
    let action: StripAction
    let emphasis: Emphasis
}

private final class StripButton: MaterialButton {
    var item: StripItem?
}

/// The icons shown in the strip's place while there is nothing to suggest. Only actions
/// that work today; agent, emoji, clipboard history and memes join as they are built.
private enum ToolbarTool: CaseIterable {
    case pi, snippets, paste, hide

    /// An SF Symbol, or nil for the bundled Oqto mascot.
    var symbol: String? {
        switch self {
        case .pi: return nil
        case .snippets: return "text.badge.plus"
        case .paste: return "clipboard"
        case .hide: return "keyboard.chevron.compact.down"
        }
    }

    var label: String {
        switch self {
        case .pi: return "Ask Pi"
        case .snippets: return "Snippets"
        case .paste: return "Paste"
        case .hide: return "Hide keyboard"
        }
    }
}

private final class ToolbarButton: UIButton {
    var tool: ToolbarTool = .pi
}

extension KeyboardViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableView === agentPanel ? agentRows.count : panelSnippets.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView === agentPanel {
            let cell = tableView.dequeueReusableCell(withIdentifier: "agent", for: indexPath)
            let row = agentRows[indexPath.row]
            var content = UIListContentConfiguration.cell()
            // Your prompts are quiet; answers, which are what you insert, carry the weight.
            let mine = row.role == "user"
            if !mine, !row.failed, let rendered = Self.markdown(row.text) {
                content.attributedText = rendered
            } else if mine {
                let parsed = AgentPrompt.parse(row.text)
                content.text = parsed.labels.isEmpty
                    ? parsed.question
                    : "[\(parsed.labels.joined(separator: ", "))] \(parsed.question)"
            } else {
                content.text = row.text
            }
            cell.accessoryView = (!mine && !row.failed && !row.live && !row.text.isEmpty)
                ? answerActions(row: indexPath.row)
                : nil
            content.textProperties.color = row.failed
                ? .systemRed
                : (mine ? KeyboardStyle.secondaryText : KeyboardStyle.text)
            content.textProperties.font = mine ? .systemFont(ofSize: 13) : .systemFont(ofSize: 15)
            content.directionalLayoutMargins.leading = mine ? 32 : 8
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.backgroundColor = .clear
            cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "snippet", for: indexPath)
        let snippet = panelSnippets[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = SnippetSearch.preview(snippet)
        content.textProperties.color = KeyboardStyle.text
        content.textProperties.font = .systemFont(ofSize: 15)
        content.textProperties.numberOfLines = 2
        let preview = content.text ?? ""
        content.secondaryText = snippet.label.isEmpty || preview.hasPrefix(snippet.label) ? nil : snippet.label
        content.secondaryTextProperties.color = KeyboardStyle.secondaryText
        content.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = KeyboardStyle.functionKey
        cell.selectedBackgroundView = selected
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        // Answers act through their Insert and Copy buttons only, so a tap while scrolling
        // cannot type into the host.
        if tableView === agentPanel { return }
        Haptics.shared.selection()
        insertFromPanel(panelSnippets[indexPath.row])
    }
}

extension KeyboardViewController {
    /// Inline markdown (bold, italic, code, links) with line breaks kept, so lists and
    /// paragraphs stay readable. Block styling such as headings is not rendered yet.
    static func markdown(_ source: String) -> NSAttributedString? {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var parsed = try? AttributedString(markdown: source, options: options) else { return nil }
        let base = UIFont.systemFont(ofSize: 15)
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = base
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            } else {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
                    font = UIFont(descriptor: descriptor, size: 15)
                }
            }
            parsed[run.range].uiKit.font = font
            parsed[run.range].uiKit.foregroundColor = KeyboardStyle.text
        }
        return NSAttributedString(parsed)
    }
}

extension KeyboardViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendAgentPrompt()
        return false
    }
}

/// How late touches reach the keyboard, split by where they land. Edge keys are reported
/// separately because the system's edge gestures are the usual cause of a delay there.
struct TouchLatency {
    private var centre: [Double] = []
    private var edge: [Double] = []

    mutating func record(_ milliseconds: Double, edge isEdge: Bool) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        if isEdge {
            edge.append(milliseconds)
            if edge.count > 40 { edge.removeFirst() }
        } else {
            centre.append(milliseconds)
            if centre.count > 40 { centre.removeFirst() }
        }
    }

    var summary: String {
        "touch→key ms: centre \(Self.describe(centre))  edge \(Self.describe(edge))"
    }

    private static func describe(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        let average = values.reduce(0, +) / Double(values.count)
        let worst = values.max() ?? 0
        return String(format: "avg %.0f max %.0f n%d", average, worst, values.count)
    }
}


/// Where a piece of agent context comes from.
private enum AgentContextSource: Int, CaseIterable {
    case field, clipboard

    var title: String {
        switch self {
        case .field: return "field"
        case .clipboard: return "clipboard"
        }
    }
}

/// The stored user message carries its context ahead of the question, in fenced blocks the
/// transcript can fold back into chips.
enum AgentPrompt {
    static let maxContextCharacters = 6000

    static func compose(question: String, contexts: [(label: String, text: String)]) -> String {
        guard !contexts.isEmpty else { return question }
        var budget = maxContextCharacters
        var blocks: [String] = []
        for context in contexts {
            var text = String(context.text.prefix(max(0, budget)))
            if text.count < context.text.count { text += "\n[truncated]" }
            budget -= text.count
            blocks.append("[context: \(context.label)]\n\(text)\n[/context]")
        }
        return blocks.joined(separator: "\n\n") + "\n\nUsing the context above: " + question
    }

    static func parse(_ message: String) -> (labels: [String], question: String) {
        guard message.hasPrefix("[context: ") else { return ([], message) }
        var labels: [String] = []
        var rest = Substring(message)
        while rest.hasPrefix("[context: "), let close = rest.range(of: "[/context]") {
            let header = rest.dropFirst("[context: ".count)
            if let end = header.firstIndex(of: "]") { labels.append(String(header[..<end])) }
            rest = rest[close.upperBound...].drop { $0.isWhitespace }
        }
        let question = rest.hasPrefix("Using the context above: ")
            ? String(rest.dropFirst("Using the context above: ".count))
            : String(rest)
        return (labels, question)
    }
}


/// What a snippet looks like in the list, and the fuzzy ranking for its search.
enum SnippetSearch {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The text the snippet would insert, not its trigger. Dynamic kinds show what they do.
    static func preview(_ snippet: Snippet) -> String {
        let text: String
        switch snippet.kind {
        case "image":
            text = "image: " + (snippet.replace as NSString).lastPathComponent
        case "shell", "script":
            text = "$ " + (snippet.shellCmd ?? snippet.replace)
        case "clipboard", "form":
            text = snippet.replace
        default:
            text = SnippetExpansion.expand(snippet).text
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every query word must match: a substring scores most (more at a word start), a
    /// subsequence of the shown text scores least; anything else drops out.
    static func rank(_ items: [(snippet: Snippet, preview: String, haystack: String)],
                     query: String) -> [(snippet: Snippet, preview: String, haystack: String)] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return items.sorted { $0.preview.localizedCaseInsensitiveCompare($1.preview) == .orderedAscending }
        }
        var scored: [(item: (snippet: Snippet, preview: String, haystack: String), score: Int)] = []
        for item in items {
            var total = 0
            var matched = true
            for word in words {
                if let range = item.haystack.range(of: word) {
                    let atStart = range.lowerBound == item.haystack.startIndex
                        || !item.haystack[item.haystack.index(before: range.lowerBound)].isLetter
                    total += 10 + (atStart ? 6 : 0)
                } else if isSubsequence(word, of: fold(item.preview)) {
                    total += 2
                } else {
                    matched = false
                    break
                }
            }
            if matched { scored.append((item, total)) }
        }
        return scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.item.preview.count < $1.item.preview.count
        }.map(\.item)
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = haystack.startIndex
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }
}
