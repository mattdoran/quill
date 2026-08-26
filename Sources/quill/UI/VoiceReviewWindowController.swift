import AppKit
import AVFAudio

private final class TranscriptReviewRootView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

@MainActor
final class VoiceReviewWindowController: NSWindowController, NSWindowDelegate,
    NSTextFieldDelegate
{
    private enum SeparationState { case idle, separating(String), failed(String) }
    private struct Row {
        let voiceID: String
        let field: NSTextField
        let playButton: NSButton
    }
    private struct FocusEntry {
        let id: String
        let view: NSView
    }

    private let session: URL
    private var transcript: TranscriptDocument
    private let isRecording: () -> Bool
    private let separateSpeakers: (
        Set<SourceTrack>,
        @escaping @Sendable (SpeakerSeparationProgress) -> Void
    ) async throws -> Void
    private var rows: [Row] = []
    private var speakerActionButtons: [NSButton] = []
    private var focusEntries: [FocusEntry] = []
    private weak var transcriptTextView: NSTextView?
    private var separationState = SeparationState.idle
    private var lastSeparationTracks: Set<SourceTrack> = [.system]
    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    private var nextSampleIndex: [String: Int] = [:]
    private weak var activePlayButton: NSButton?
    private var activeVoiceID: String?

    var sessionURL: URL { session }

    init(
        session: URL,
        isRecording: @escaping () -> Bool,
        separateSpeakers: @escaping (
            Set<SourceTrack>,
            @escaping @Sendable (SpeakerSeparationProgress) -> Void
        ) async throws -> Void,
        appearance: NSAppearance? = nil
    ) throws {
        self.session = session
        transcript = try TranscriptStore(session: session).read()
        self.isRecording = isRecording
        self.separateSpeakers = separateSpeakers
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.title = "Transcript"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.closeButton)?.isEnabled = true
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        setInitialFocus()
        window.center()
    }

    convenience init(
        session: URL,
        isRecording: @escaping () -> Bool,
        separateSpeakers: @escaping () async throws -> Void,
        appearance: NSAppearance? = nil
    ) throws {
        try self.init(
            session: session,
            isRecording: isRecording,
            separateSpeakers: { _, _ in try await separateSpeakers() },
            appearance: appearance
        )
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let initialFirstResponder = window?.initialFirstResponder {
            window?.makeFirstResponder(initialFirstResponder)
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopPlayback()
        NSApp.setActivationPolicy(.accessory)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if case .separating = separationState { return false }
        guard hasUnsavedNames else { return true }
        let alert = NSAlert()
        alert.messageText = "Save speaker names?"
        alert.informativeText = "Your changes have not been saved to the transcript."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveNames(refresh: false)
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    private func buildContent() -> NSView {
        rows = []
        speakerActionButtons = []
        let root = TranscriptReviewRootView()
        let title = NSTextField(labelWithString: "Transcript")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let sessionLabel = NSTextField(labelWithString: SessionName.dated(session))
        sessionLabel.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, sessionLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        let markdown = NSButton(title: "Open Transcript File", target: self, action: #selector(openMarkdownClicked))
        markdown.bezelStyle = .rounded
        let finder = NSButton(title: "Show in Finder", target: self, action: #selector(showFolderClicked))
        finder.bezelStyle = .rounded
        let fileActions = NSStackView(views: [finder, markdown])
        fileActions.orientation = .horizontal
        fileActions.spacing = 8

        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        if case .separating = separationState { close.isEnabled = false }
        var reviewButtons = [close]
        if !transcript.voiceIDs.isEmpty {
            let save = NSButton(title: "Save Names", target: self, action: #selector(saveClicked))
            save.bezelStyle = .rounded
            save.keyEquivalent = "\r"
            if case .separating = separationState { save.isEnabled = false }
            reviewButtons.append(save)
        }
        let reviewActions = NSStackView(views: reviewButtons)
        reviewActions.orientation = .horizontal
        reviewActions.spacing = 8

        let transcriptScroll = makeTranscriptScrollView()
        let sidebar = makeSpeakerSidebar()
        let divider = NSBox()
        divider.boxType = .separator
        for view in [heading, transcriptScroll, divider, sidebar, fileActions, reviewActions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            transcriptScroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 22),
            transcriptScroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: fileActions.topAnchor, constant: -18),
            transcriptScroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -24),
            divider.topAnchor.constraint(equalTo: transcriptScroll.topAnchor),
            divider.bottomAnchor.constraint(equalTo: transcriptScroll.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            sidebar.topAnchor.constraint(equalTo: transcriptScroll.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 24),
            sidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: transcriptScroll.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 286),
            fileActions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            fileActions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            reviewActions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            reviewActions.bottomAnchor.constraint(equalTo: fileActions.bottomAnchor),
        ])
        focusEntries = [transcriptTextView].compactMap { view in
            view.map { FocusEntry(id: "transcript", view: $0) }
        }
        focusEntries += rows.flatMap { row in
            [
                FocusEntry(id: "name:\(row.voiceID)", view: row.field),
                FocusEntry(id: "play:\(row.voiceID)", view: row.playButton),
            ]
        }
        focusEntries += speakerActionButtons.enumerated().map {
            FocusEntry(id: "speaker-action:\($0.offset)", view: $0.element)
        }
        focusEntries += [
            FocusEntry(id: "show-in-finder", view: finder),
            FocusEntry(id: "open-transcript", view: markdown),
        ]
        focusEntries += reviewButtons.map {
            FocusEntry(id: "review-action:\($0.title)", view: $0)
        }
        configureKeyViewLoop()
        configureNameFieldHelp()
        return root
    }

    private func makeTranscriptScrollView() -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(transcriptText())
        textView.setAccessibilityLabel("Transcript text")
        transcriptTextView = textView
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        return scroll
    }

    private func transcriptText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 15
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let speaker: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let time: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for segment in transcript.segments {
            result.append(NSAttributedString(string: "\(Self.clock(segment.start_ms))  ", attributes: time))
            result.append(NSAttributedString(string: segment.speaker, attributes: speaker))
            if
                transcript.diarizer != nil,
                let voiceID = segment.voice_id,
                let voice = transcript.voices[voiceID]
            {
                result.append(NSAttributedString(
                    string: "   \(Self.sourceTag(for: voice))",
                    attributes: time
                ))
            }
            result.append(NSAttributedString(string: "\n\(segment.text)\n", attributes: body))
        }
        if result.length == 0 {
            result.append(NSAttributedString(
                string: "No spoken text was found in this recording.",
                attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        return result
    }

    private func makeSpeakerSidebar() -> NSView {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Speakers")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let keyboardHint = NSTextField(
            wrappingLabelWithString: "Return moves to the next name and saves from the last."
        )
        keyboardHint.font = .systemFont(ofSize: 11)
        keyboardHint.textColor = .secondaryLabelColor
        keyboardHint.isHidden = transcript.voiceIDs.isEmpty
        let header = NSStackView(views: [heading, keyboardHint])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        let content = transcript.diarizer == nil ? makeBaselineReview() : makeSeparatedReview()
        header.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        return root
    }

    private func makeBaselineReview() -> NSView {
        guard case .idle = separationState else { return makeSeparationPrompt() }
        let voices = makeVoiceList(showSource: false, minimumHeight: 230)
        let prompt = makeSeparationPrompt()
        let stack = NSStackView(views: [voices, prompt])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        voices.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        prompt.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeSeparatedReview() -> NSView {
        let voices = makeVoiceList(showSource: true, minimumHeight: 220)
        guard TranscriptStore(session: session).canRestoreBeforeSpeakerSeparation else {
            return voices
        }
        let detail = NSTextField(
            wrappingLabelWithString: "Restore the original Me and Them transcript."
        )
        detail.textColor = .secondaryLabelColor
        let restore = NSButton(
            title: "Undo Voice Separation",
            target: self,
            action: #selector(restoreSeparationClicked)
        )
        restore.bezelStyle = .rounded
        speakerActionButtons.append(restore)
        let action = NSStackView(views: [detail, restore])
        action.orientation = .vertical
        action.alignment = .leading
        action.spacing = 8
        let stack = NSStackView(views: [voices, action])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        voices.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        action.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeSeparationPrompt() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        switch separationState {
        case .idle:
            let detail = NSTextField(wrappingLabelWithString: sourceAudioAvailable
                ? "More than two people?\nThe model supports up to four voices per audio track."
                : "Source audio is no longer available, so voices cannot be separated."
            )
            detail.font = .systemFont(ofSize: 12, weight: .semibold)
            detail.textColor = .secondaryLabelColor
            stack.addArrangedSubview(detail)
            if sourceAvailable(for: .system) {
                stack.addArrangedSubview(separationButton(
                    title: "Separate Remote Voices",
                    tracks: [.system]
                ))
            }
            if sourceAvailable(for: .microphone) {
                stack.addArrangedSubview(separationButton(
                    title: "Separate Local Voices",
                    tracks: [.microphone]
                ))
            }
        case .separating(let detailText):
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let status = NSTextField(labelWithString: "Separating speakers…")
            status.font = .systemFont(ofSize: 13, weight: .semibold)
            let row = NSStackView(views: [spinner, status])
            row.spacing = 8
            row.alignment = .centerY
            let detail = NSTextField(wrappingLabelWithString: detailText)
            detail.textColor = .secondaryLabelColor
            stack.addArrangedSubview(row)
            stack.addArrangedSubview(detail)
        case .failed(let message):
            let status = NSTextField(labelWithString: "Couldn’t separate speakers")
            status.font = .systemFont(ofSize: 13, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: "The transcript is unchanged.\n\(message)")
            detail.textColor = .secondaryLabelColor
            let retry = separationButton(title: "Retry", tracks: lastSeparationTracks)
            stack.addArrangedSubview(status)
            stack.addArrangedSubview(detail)
            stack.addArrangedSubview(retry)
        }
        return stack
    }

    private func separationButton(title: String, tracks: Set<SourceTrack>) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(separateClicked(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(
            tracks.map(\.rawValue).sorted().joined(separator: ",")
        )
        speakerActionButtons.append(button)
        return button
    }

    private func makeVoiceList(
        showSource: Bool,
        minimumHeight: CGFloat = 250
    ) -> NSView {
        let voiceStack = NSStackView()
        voiceStack.orientation = .vertical
        voiceStack.alignment = .leading
        voiceStack.spacing = 10
        voiceStack.translatesAutoresizingMaskIntoConstraints = false
        for id in transcript.voiceIDs {
            guard let voice = transcript.voices[id] else { continue }
            let row = makeRow(id: id, voice: voice, showSource: showSource)
            voiceStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: voiceStack.widthAnchor).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = voiceStack.arrangedSubviews.count > 3
        scroll.drawsBackground = false
        scroll.documentView = voiceStack
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
        voiceStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    private func makeRow(
        id: String,
        voice: TranscriptDocument.Voice,
        showSource: Bool
    ) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 9
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        let voiceLabel = NSTextField(labelWithString: voice.machine_label)
        voiceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        var headerViews: [NSView] = [voiceLabel]
        if showSource {
            let sourceLabel = NSTextField(labelWithString: Self.sourceTag(for: voice))
            sourceLabel.font = .systemFont(ofSize: 11)
            sourceLabel.textColor = .secondaryLabelColor
            headerViews.append(sourceLabel)
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 7
        let context = Self.context(for: id, voice: voice, showSource: showSource)
        let field = NSTextField(string: voice.name ?? "")
        field.placeholderString = "Name this voice"
        field.setAccessibilityLabel("Name for \(context)")
        field.delegate = self
        let play = NSButton(title: "Play Sample", target: self, action: #selector(playClicked(_:)))
        play.bezelStyle = .rounded
        play.controlSize = .small
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        play.imagePosition = .imageLeading
        play.identifier = NSUserInterfaceItemIdentifier(id)
        let sampleAvailable = voice.samples.first != nil && sourceURL(for: voice) != nil
        play.isEnabled = sampleAvailable
        play.title = sampleAvailable ? Self.initialPlayTitle(voice) : "Sample Unavailable"
        play.toolTip = sampleAvailable ? "Play a short sample" : "Source audio is unavailable"
        play.setAccessibilityLabel(
            sampleAvailable ? "Play sample for \(context)" : "Sample unavailable for \(context)"
        )
        rows.append(Row(voiceID: id, field: field, playButton: play))
        let stack = NSStackView(views: [header, field, play])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return card
    }

    private var sourceAudioAvailable: Bool {
        transcript.voices.values.contains { sourceURL(for: $0) != nil }
    }

    private func sourceAvailable(for track: SourceTrack) -> Bool {
        transcript.voices.values.contains {
            $0.source == track.rawValue && sourceURL(for: $0) != nil
        }
    }

    private func refreshContent() {
        let focusedID = currentFocusID()
        let separating: Bool
        if case .separating = separationState { separating = true } else { separating = false }
        window?.standardWindowButton(.closeButton)?.isEnabled = !separating
        window?.contentView = buildContent()
        setInitialFocus()
        restoreFocus(focusedID)
    }

    private func configureKeyViewLoop() {
        guard !focusEntries.isEmpty else { return }
        for index in focusEntries.indices {
            focusEntries[index].view.nextKeyView = focusEntries[(index + 1) % focusEntries.count].view
        }
    }

    private func configureNameFieldHelp() {
        for (index, row) in rows.enumerated() {
            row.field.setAccessibilityHelp(
                index + 1 < rows.count
                    ? "Press Return to move to the next speaker name."
                    : "Press Return to save speaker names."
            )
        }
    }

    private func setInitialFocus() {
        window?.initialFirstResponder = rows.first?.field ?? transcriptTextView
    }

    private func currentFocusID() -> String? {
        guard let responder = window?.firstResponder else { return nil }
        return focusEntries.first { entry in
            responder === entry.view
                || (entry.view as? NSTextField)?.currentEditor() === responder
        }?.id
    }

    private func restoreFocus(_ id: String?) {
        guard
            window?.isVisible == true,
            let id,
            let view = focusEntries.first(where: { $0.id == id })?.view
        else { return }
        window?.makeFirstResponder(view)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard
            commandSelector == #selector(NSResponder.insertNewline(_:)),
            let field = control as? NSTextField,
            let index = rows.firstIndex(where: { $0.field === field })
        else { return false }

        if index + 1 < rows.count {
            window?.makeFirstResponder(rows[index + 1].field)
        } else {
            _ = saveNames()
        }
        return true
    }

    @objc private func separateClicked(_ sender: NSButton) {
        let tracks = Set(
            (sender.identifier?.rawValue ?? "")
                .split(separator: ",")
                .compactMap { SourceTrack(rawValue: String($0)) }
        )
        guard !tracks.isEmpty else { return }
        if isRecording() {
            let alert = NSAlert()
            alert.messageText = "Finish the recording first"
            alert.informativeText = "Speaker analysis will be available when the current recording ends."
            alert.runModal()
            return
        }
        if hasUnsavedNames, !saveNames(refresh: false) { return }
        lastSeparationTracks = tracks
        separationState = .separating("Preparing the speaker model…")
        refreshContent()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await separateSpeakers(tracks) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateSeparationProgress(progress)
                    }
                }
                transcript = try TranscriptStore(session: session).read()
                separationState = .idle
                refreshContent()
            } catch {
                separationState = .failed(error.localizedDescription)
                if window?.isVisible == true { refreshContent() }
            }
        }
    }

    private func updateSeparationProgress(_ progress: SpeakerSeparationProgress) {
        guard case .separating = separationState else { return }
        if let source = progress.source {
            let name = source == .microphone ? "Local audio" : "Remote audio"
            separationState = .separating(
                "\(progress.percentage)% complete. \(name), source \(min(progress.completedSources + 1, progress.totalSources)) of \(progress.totalSources). The model does not report progress within a source."
            )
        } else {
            separationState = .separating("Preparing the speaker model…")
        }
        if window?.isVisible == true { refreshContent() }
    }

    @objc private func restoreSeparationClicked() {
        guard !isRecording() else { return }
        let alert = NSAlert()
        alert.messageText = "Undo voice separation?"
        alert.informativeText = "This restores the original Me and Them transcript and removes separated voice names."
        alert.addButton(withTitle: "Undo Separation")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try TranscriptStore(session: session).restoreBeforeSpeakerSeparation()
            transcript = try TranscriptStore(session: session).read()
            separationState = .idle
            refreshContent()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func playClicked(_ sender: NSButton) {
        guard !isRecording() else {
            let alert = NSAlert()
            alert.messageText = "Finish the recording first"
            alert.informativeText = "Playing a sample now would become part of the recording."
            alert.runModal()
            return
        }
        guard let id = sender.identifier?.rawValue, let voice = transcript.voices[id],
              !voice.samples.isEmpty, let source = sourceURL(for: voice) else { return }
        if activePlayButton === sender, player?.isPlaying == true { stopPlayback(); return }
        let index = nextSampleIndex[id, default: 0] % voice.samples.count
        let sample = voice.samples[index]
        nextSampleIndex[id] = index + 1
        do {
            stopPlayback()
            let player = try AVAudioPlayer(contentsOf: source)
            player.currentTime = TimeInterval(sample.start_ms) / 1000
            player.prepareToPlay()
            player.play()
            self.player = player
            activePlayButton = sender
            activeVoiceID = id
            sender.title = "Stop"
            sender.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
            sender.setAccessibilityLabel("Stop sample for \(Self.context(for: id, voice: voice))")
            let duration = max(0.5, min(8, TimeInterval(sample.end_ms - sample.start_ms) / 1000))
            stopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
                [weak self] _ in MainActor.assumeIsolated { self?.stopPlayback() }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Sample could not be played"
            alert.runModal()
        }
    }

    @objc private func saveClicked() {
        _ = saveNames()
    }

    @objc private func closeClicked() {
        window?.performClose(nil)
    }

    private func saveNames(refresh: Bool = true) -> Bool {
        stopPlayback()
        do {
            try transcript.applyVoiceNames(Dictionary(uniqueKeysWithValues: rows.map {
                ($0.voiceID, enteredName(in: $0))
            }))
            try TranscriptStore(session: session).write(transcript)
            if refresh { refreshContent() }
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @objc private func openMarkdownClicked() {
        NSWorkspace.shared.open(SessionFiles.transcriptMarkdown(session))
    }

    @objc private func showFolderClicked() {
        NSWorkspace.shared.activateFileViewerSelecting([SessionFiles.transcriptMarkdown(session)])
    }

    private func sourceURL(for voice: TranscriptDocument.Voice) -> URL? {
        let url = session.appendingPathComponent(voice.audio_file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func stopPlayback() {
        stopTimer?.invalidate()
        stopTimer = nil
        player?.stop()
        player = nil
        if let id = activeVoiceID, let voice = transcript.voices[id], let button = activePlayButton {
            let next = nextSampleIndex[id, default: 0] % max(voice.samples.count, 1)
            button.title = voice.samples.count > 1 ? "Next Sample \(next + 1) of \(voice.samples.count)" : "Replay Sample"
            button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            button.setAccessibilityLabel(
                voice.samples.count > 1
                    ? "Play sample \(next + 1) of \(voice.samples.count) for \(Self.context(for: id, voice: voice))"
                    : "Replay sample for \(Self.context(for: id, voice: voice))"
            )
        }
        activePlayButton = nil
        activeVoiceID = nil
    }

    private static func context(
        for id: String,
        voice: TranscriptDocument.Voice,
        showSource: Bool = true
    ) -> String {
        showSource
            ? "\(voice.machine_label) · \(sourceTag(for: voice))"
            : voice.machine_label
    }

    private static func sourceTag(for voice: TranscriptDocument.Voice) -> String {
        voice.source == "mic" ? "local" : "remote"
    }

    private var hasUnsavedNames: Bool {
        rows.contains { row in
            normalized(enteredName(in: row)) != normalized(transcript.voices[row.voiceID]?.name ?? "")
        }
    }

    private func enteredName(in row: Row) -> String {
        row.field.currentEditor()?.string ?? row.field.stringValue
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func initialPlayTitle(_ voice: TranscriptDocument.Voice) -> String {
        voice.samples.count > 1 ? "Play Sample 1 of \(voice.samples.count)" : "Play Sample"
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
