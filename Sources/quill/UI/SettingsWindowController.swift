import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    var recordingsPath: (() -> String)?
    var onChangeRecordingsFolder: (() -> Void)?
    var onRetentionChanged: (() -> Void)?
    var onDownloadModels: (() -> Void)?
    var onRemoveModels: (() -> Void)?

    private let pathLabel = NSTextField(labelWithString: "")
    private let retention = NSPopUpButton()
    private let openAtLogin = NSButton(
        checkboxWithTitle: "Open at login",
        target: nil,
        action: nil
    )
    private let changeFolderButton = NSButton(title: "Change…", target: nil, action: nil)
    private let modelStatus = NSTextField(labelWithString: "")
    private let modelButton = NSButton(title: "", target: nil, action: nil)
    private let presence: ApplicationPresenceController

    init(presence: ApplicationPresenceController = ApplicationPresenceController()) {
        self.presence = presence
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quill Settings"
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        refresh()
        showWindow(nil)
        if let window {
            presence.present(window)
        }
        let initial = openAtLogin.isEnabled ? openAtLogin : changeFolderButton
        window?.initialFirstResponder = initial
        window?.makeFirstResponder(initial)
    }

    func refresh() {
        let path = recordingsPath?() ?? Config.defaultRoot.path
        pathLabel.stringValue = path
        pathLabel.toolTip = path
        retention.selectItem(withTitle: Config.audioRetention().title)
        openAtLogin.state = LoginItem.isEnabled ? .on : .off
        openAtLogin.isEnabled = LoginItem.isAvailable
        refreshModel()
    }

    func updateModelDownload(_ status: ModelDownload.Status) {
        switch status {
        case .idle:
            refreshModel()
        case .downloading(let fraction):
            modelStatus.stringValue = "Downloading - \(Int(fraction * 100))%"
            modelButton.isEnabled = false
        case .waitingForNetwork:
            refreshModel()
        case .failed:
            modelStatus.stringValue = "Download failed"
            modelButton.title = "Download"
            modelButton.isEnabled = true
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
        ])

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setAccessibilityLabel("Recordings folder")
        changeFolderButton.target = self
        changeFolderButton.action = #selector(changeFolderClicked)
        changeFolderButton.setAccessibilityLabel("Change recordings folder")
        stack.addArrangedSubview(section("General"))
        openAtLogin.target = self
        openAtLogin.action = #selector(loginChanged)
        stack.addArrangedSubview(row(label: "", controls: [openAtLogin]))
        stack.addArrangedSubview(row(label: "Folder", controls: [pathLabel, changeFolderButton]))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(section("Storage"))
        retention.addItems(withTitles: Config.AudioRetention.allCases.map(\.title))
        retention.target = self
        retention.action = #selector(retentionChanged)
        retention.setAccessibilityLabel("Source audio retention")
        stack.addArrangedSubview(row(label: "Source audio", controls: [retention]))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(section("Transcription"))
        let engine = NSTextField(labelWithString: "Parakeet TDT 0.6B v2")
        stack.addArrangedSubview(row(label: "Engine", controls: [engine]))

        modelButton.target = self
        modelButton.action = #selector(modelClicked)
        modelStatus.setAccessibilityLabel("Transcription models status")
        stack.addArrangedSubview(row(label: "Models", controls: [modelStatus, modelButton]))

        openAtLogin.nextKeyView = changeFolderButton
        changeFolderButton.nextKeyView = retention
        retention.nextKeyView = modelButton
        modelButton.nextKeyView = openAtLogin
    }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func row(label: String, controls: [NSView]) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [title] + controls)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: 512).isActive = true
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 512).isActive = true
        return box
    }

    private func refreshModel() {
        if ModelDownload.isCached {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            modelStatus.stringValue = "Downloaded (\(formatter.string(fromByteCount: ModelDownload.cachedBytes)))"
            modelButton.title = "Remove…"
            modelButton.setAccessibilityLabel("Remove transcription models")
        } else {
            modelStatus.stringValue = "Not downloaded (about 600 MB)"
            modelButton.title = "Download"
            modelButton.setAccessibilityLabel("Download transcription models")
        }
        modelButton.isEnabled = true
    }

    @objc private func changeFolderClicked() {
        onChangeRecordingsFolder?()
    }

    @objc private func retentionChanged() {
        guard
            let title = retention.selectedItem?.title,
            let selected = Config.AudioRetention.allCases.first(where: { $0.title == title })
        else { return }
        let current = Config.audioRetention()
        guard selected != current else { return }

        if selected != .indefinitely {
            let alert = NSAlert()
            if selected == .thirtyDays {
                alert.messageText = "Apply 30-day audio retention?"
                alert.informativeText = "Source audio from completed transcripts older than 30 days will be deleted now. Meeting audio and transcripts remain, but the transcript cannot be reprocessed and voice samples become unavailable."
                alert.addButton(withTitle: "Apply")
            } else {
                alert.messageText = "Delete transcribed audio?"
                alert.informativeText = "Source audio from every completed transcript will be deleted now. Meeting audio and transcripts remain, but the transcript cannot be reprocessed and voice samples become unavailable."
                alert.addButton(withTitle: "Delete Audio")
            }
            alert.addButton(withTitle: "Cancel")
            guard presence.runModal(alert) == .alertFirstButtonReturn else {
                retention.selectItem(withTitle: current.title)
                return
            }
        }

        Config.setAudioRetention(selected)
        onRetentionChanged?()
    }

    @objc private func loginChanged() {
        LoginItem.setEnabled(openAtLogin.state == .on)
        refresh()
    }

    @objc private func modelClicked() {
        if ModelDownload.isCached {
            let alert = NSAlert()
            alert.messageText = "Remove transcription models?"
            alert.informativeText = "This frees the downloaded model storage. Quill will need to download the models again before it can transcribe."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard presence.runModal(alert) == .alertFirstButtonReturn else { return }
            modelStatus.stringValue = "Removing…"
            modelButton.isEnabled = false
            onRemoveModels?()
        } else {
            modelStatus.stringValue = "Downloading - 0%"
            modelButton.isEnabled = false
            onDownloadModels?()
        }
    }
}
