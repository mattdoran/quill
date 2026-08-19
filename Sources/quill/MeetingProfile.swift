import Foundation

enum MeetingProfile: String, CaseIterable, Codable, Sendable {
    case neither
    case onTheCall = "on_the_call"
    case inTheRoom = "in_the_room"
    case both

    var title: String {
        switch self {
        case .neither: "Off"
        case .onTheCall: "On the call"
        case .inTheRoom: "In the room"
        case .both: "Both"
        }
    }

    func voiceSettings(for track: String) -> VoiceSettings {
        let isMicrophone = track == "mic"
        let separatesVoices: Bool
        switch self {
        case .neither:
            separatesVoices = false
        case .onTheCall:
            separatesVoices = !isMicrophone
        case .inTheRoom:
            separatesVoices = isMicrophone
        case .both:
            separatesVoices = true
        }
        return VoiceSettings(
            separatesVoices: separatesVoices,
            soloLabel: isMicrophone ? "me" : "them",
            sharedLabel: isMicrophone ? "room" : "them"
        )
    }
}

struct VoiceSettings: Equatable, Sendable {
    let separatesVoices: Bool
    let soloLabel: String
    let sharedLabel: String
}
