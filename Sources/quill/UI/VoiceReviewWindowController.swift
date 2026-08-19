import AppKit
import AVFAudio

private final class VoiceReviewStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class VoiceReviewRootView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

@MainActor
final class VoiceReviewWindowController: NSWindowController, NSWindowDelegate {
    private struct Row {
        let voiceID: String
        let field: NSTextField
    }

    private let session: URL
    private var transcript: TranscriptDocument
    private let isRecording: () -> Bool
    private var rows: [Row] = []
    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    private var nextSampleIndex: [String: Int] = [:]
    private weak var activePlayButton: NSButton?
    private var activeVoiceID: String?

    var sessionURL: URL { session }

    init(
        session: URL,
        isRecording: @escaping () -> Bool,
        appearance: NSAppearance? = nil
    ) throws {
        self.session = session
        self.transcript = try TranscriptStore(session: session).read()
        self.isRecording = isRecording

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.title = "Identify Voices"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        rows.first?.field.window?.makeFirstResponder(rows.first?.field)
    }

    func windowWillClose(_ notification: Notification) { stopPlayback() }

    private func buildContent() -> NSView {
        let root = VoiceReviewRootView()

        let title = NSTextField(labelWithString: transcript.unidentifiedVoiceIDs.isEmpty
            ? "Edit voice names"
            : "Who is speaking?")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let detail = NSTextField(
            wrappingLabelWithString: "\(SessionName.dated(session))\nPlay a sample, then add the name you want in the transcript."
        )
        detail.textColor = .secondaryLabelColor

        let voiceStack = VoiceReviewStackView()
        voiceStack.orientation = .vertical
        voiceStack.spacing = 10
        voiceStack.alignment = .leading
        voiceStack.translatesAutoresizingMaskIntoConstraints = false

        for id in transcript.voiceIDs {
            guard let voice = transcript.voices[id] else { continue }
            voiceStack.addArrangedSubview(makeRow(id: id, voice: voice))
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = voiceStack.arrangedSubviews.count > 4
        scroll.drawsBackground = false
        scroll.documentView = voiceStack
        scroll.contentView.scroll(to: .zero)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save Names", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded

        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        for view in [title, detail, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -20),
            voiceStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
        ])
        return root
    }

    private func makeRow(id: String, voice: TranscriptDocument.Voice) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 10
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = voice.source == "mic" ? .systemIndigo : .systemGreen
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.setAccessibilityElement(false)

        let context = NSTextField(labelWithString: Self.context(for: id, voice: voice))
        context.font = .systemFont(ofSize: 11, weight: .medium)
        context.textColor = .secondaryLabelColor

        let field = NSTextField(string: voice.name ?? "")
        field.placeholderString = "Name this voice"
        field.font = .systemFont(ofSize: 15)
        field.setAccessibilityLabel("Name for \(context.stringValue)")
        rows.append(Row(voiceID: id, field: field))

        let play = NSButton(
            title: "Play Sample",
            target: self,
            action: #selector(playClicked(_:))
        )
        play.bezelStyle = .rounded
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        play.imagePosition = .imageLeading
        play.identifier = NSUserInterfaceItemIdentifier(id)
        let sampleAvailable = voice.samples.first != nil && sourceURL(for: voice) != nil
        play.isEnabled = sampleAvailable
        play.title = sampleAvailable ? Self.initialPlayTitle(voice) : "Sample Unavailable"
        play.toolTip = sampleAvailable ? "Play a short sample of this voice" : "Source audio is unavailable"
        play.setAccessibilityLabel("Play sample for \(context.stringValue)")

        let textStack = NSStackView(views: [context, field])
        textStack.orientation = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let row = NSStackView(views: [icon, textStack, play])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 76),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 235),
        ])
        return card
    }

    @objc private func playClicked(_ sender: NSButton) {
        guard !isRecording() else {
            let alert = NSAlert()
            alert.messageText = "Finish the recording first"
            alert.informativeText = "Playing a sample now would become part of the recording."
            alert.runModal()
            return
        }
        guard
            let id = sender.identifier?.rawValue,
            let voice = transcript.voices[id],
            !voice.samples.isEmpty,
            let source = sourceURL(for: voice)
        else { return }

        if activePlayButton === sender, player?.isPlaying == true {
            stopPlayback()
            return
        }

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
        stopPlayback()
        do {
            try transcript.applyVoiceNames(Dictionary(uniqueKeysWithValues: rows.map {
                ($0.voiceID, $0.field.stringValue)
            }))
            try TranscriptStore(session: session).write(transcript)
            close()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func cancelClicked() {
        stopPlayback()
        close()
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
        if
            let id = activeVoiceID,
            let voice = transcript.voices[id],
            let button = activePlayButton
        {
            let next = nextSampleIndex[id, default: 0] % max(voice.samples.count, 1)
            button.title = voice.samples.count > 1
                ? "Next Sample \(next + 1) of \(voice.samples.count)"
                : "Replay Sample"
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

    private static func context(for id: String, voice: TranscriptDocument.Voice) -> String {
        let number = id.split(separator: ":").last.map(String.init) ?? ""
        let place = voice.source == "mic" ? "In the room" : "On the call"
        return "\(place) · Voice \(number)"
    }

    private static func initialPlayTitle(_ voice: TranscriptDocument.Voice) -> String {
        voice.samples.count > 1 ? "Play Sample 1 of \(voice.samples.count)" : "Play Sample"
    }
}
