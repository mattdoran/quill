import AppKit

func scheduleInteractiveTimer(_ timer: Timer) {
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    RunLoop.main.add(timer, forMode: .modalPanel)
}
