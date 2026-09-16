import AppKit

/// One count per source, so a hybrid meeting need not have equal-sized groups.
@MainActor
final class SpeakerCountPicker: NSStackView {
    private static let unchangedTag = -1
    private var pickers: [SourceTrack: NSPopUpButton] = [:]
    var onSelectionChanged: (() -> Void)?

    init(
        tracks: Set<SourceTrack>,
        selections: [SourceTrack: SpeakerCountSelection]
    ) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        for track in SourceTrack.allCases {
            guard tracks.contains(track) else { continue }
            let source = track == .microphone ? "Local" : "Remote"
            let label = NSTextField(labelWithString: "\(source) speakers")
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 270, height: 28))
            picker.identifier = NSUserInterfaceItemIdentifier(track.rawValue)
            picker.setAccessibilityLabel("Number of \(source.lowercased()) speakers")
            picker.addItem(withTitle: "Leave unchanged")
            picker.lastItem?.tag = Self.unchangedTag
            picker.menu?.addItem(.separator())
            for count in 1...20 {
                picker.addItem(withTitle: count == 1 ? "1 speaker" : "\(count) speakers")
                picker.lastItem?.tag = count
            }
            picker.menu?.addItem(.separator())
            picker.addItem(withTitle: "Detect automatically (less reliable)")
            picker.lastItem?.tag = 0
            switch selections[track] {
            case .exact(let count) where (1...20).contains(count):
                picker.selectItem(withTag: count)
            case .automatic:
                picker.selectItem(withTag: 0)
            default:
                picker.selectItem(withTag: Self.unchangedTag)
            }
            picker.target = self
            picker.action = #selector(selectionChanged)
            pickers[track] = picker
            addArrangedSubview(label)
            addArrangedSubview(picker)
        }
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func selectionChanged() {
        onSelectionChanged?()
    }

    static func makeAlert(
        tracks: Set<SourceTrack>,
        selections: [SourceTrack: SpeakerCountSelection],
        replacingSeparatedTracks: Bool
    ) -> (alert: NSAlert, choices: SpeakerCountPicker) {
        let alert = NSAlert()
        alert.messageText = "How many people spoke?"
        alert.informativeText = "Local means people near this Mac. Remote means people on the call."
        if replacingSeparatedTracks {
            alert.informativeText += " Reanalysing a source replaces its current speaker names."
        }
        let choices = SpeakerCountPicker(tracks: tracks, selections: selections)
        alert.accessoryView = choices
        alert.addButton(withTitle: "Separate Voices")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = !choices.selections.isEmpty
        choices.onSelectionChanged = { [weak alert, weak choices] in
            alert?.buttons.first?.isEnabled = choices?.selections.isEmpty == false
        }
        return (alert, choices)
    }

    var selections: [SourceTrack: SpeakerCountSelection] {
        pickers.reduce(into: [:]) { result, entry in
            let tag = entry.value.selectedTag()
            guard tag != Self.unchangedTag else { return }
            result[entry.key] = tag == 0 ? .automatic : .exact(tag)
        }
    }
}
