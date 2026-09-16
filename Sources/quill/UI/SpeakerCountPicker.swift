import AppKit

/// One count per source, so a hybrid meeting need not have equal-sized groups.
@MainActor
final class SpeakerCountPicker: NSStackView {
    private var pickers: [SourceTrack: NSPopUpButton] = [:]

    init(selections: [SourceTrack: SpeakerCountSelection]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        for track in SourceTrack.allCases {
            guard let selection = selections[track] else { continue }
            let source = track == .microphone ? "Local" : "Remote"
            let label = NSTextField(labelWithString: "\(source) speakers")
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 270, height: 28))
            picker.identifier = NSUserInterfaceItemIdentifier(track.rawValue)
            picker.setAccessibilityLabel("Number of \(source.lowercased()) speakers")
            for count in 1...20 {
                picker.addItem(withTitle: count == 1 ? "1 speaker" : "\(count) speakers")
                picker.lastItem?.tag = count
            }
            picker.menu?.addItem(.separator())
            picker.addItem(withTitle: "Detect automatically (less reliable)")
            picker.lastItem?.tag = 0
            switch selection {
            case .exact(let count) where (1...20).contains(count):
                picker.selectItem(withTag: count)
            default:
                picker.selectItem(withTag: 0)
            }
            pickers[track] = picker
            addArrangedSubview(label)
            addArrangedSubview(picker)
        }
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) { nil }

    static func makeAlert(
        selections: [SourceTrack: SpeakerCountSelection],
        replacingSeparatedTracks: Bool
    ) -> (alert: NSAlert, choices: SpeakerCountPicker) {
        let alert = NSAlert()
        alert.messageText = "How many people spoke?"
        alert.informativeText = "Count the people who actually spoke on each selected track. Local includes everyone near this Mac; remote includes people on the call."
        if replacingSeparatedTracks {
            alert.informativeText += " Selected tracks are replaced only after analysis succeeds. Names on other tracks are kept."
        }
        let choices = SpeakerCountPicker(selections: selections)
        alert.accessoryView = choices
        alert.addButton(withTitle: "Separate Voices")
        alert.addButton(withTitle: "Cancel")
        return (alert, choices)
    }

    var selections: [SourceTrack: SpeakerCountSelection] {
        pickers.mapValues { $0.selectedTag() == 0 ? .automatic : .exact($0.selectedTag()) }
    }
}
