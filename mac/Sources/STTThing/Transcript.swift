import SwiftUI

struct Line: Identifiable, Equatable {
    let id: Int
    var committed: String
    var tentative: String
    var final: Bool
}

/// State shown in the overlay.
final class Transcript: ObservableObject {
    static let maxLines = 30

    @Published var lines: [Line] = []
    @Published var status = "starting"
    @Published var isError = false
    @Published var speech = false
    @Published var ready = false
    /// Paused: the backend ignores audio, there is no auto-scroll and the
    /// text area takes the mouse so it can be scrolled.
    @Published var paused = false
    @Published var device = ""
    @Published var fontSize: CGFloat
    @Published var opacity: Double

    private var lastMs: Int?

    init(fontSize: CGFloat, opacity: Double) {
        self.fontSize = fontSize
        self.opacity = opacity
    }

    func loading(device: String) {
        ready = false
        self.device = device
        setStatus("loading model · \(device)")
    }

    func handle(_ event: BackendEvent) {
        switch event {
        case .ready(let device):
            ready = true
            self.device = device
            setStatus(statusLine())
        case .level(let speech):
            if !paused && self.speech != speech { self.speech = speech }
        case .paused(let isPaused):
            if isPaused { speech = false }
        case .update(let seg, let committed, let tentative, let final, let ms):
            if let i = lines.firstIndex(where: { $0.id == seg }) {
                if committed.isEmpty && tentative.isEmpty && final {
                    lines.remove(at: i)
                } else {
                    lines[i] = Line(id: seg, committed: committed, tentative: tentative, final: final)
                }
            } else if !(committed.isEmpty && tentative.isEmpty) {
                lines.append(Line(id: seg, committed: committed, tentative: tentative, final: final))
            }
            if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
            lastMs = ms
            setStatus(statusLine())
        case .error(let message):
            setStatus(message, error: true)
        case .stopped(let code):
            ready = false
            speech = false
            setStatus("backend stopped (code \(code)) · right-click → Restart backend", error: true)
        }
    }

    func clear() {
        lines.removeAll()
    }

    private func statusLine() -> String {
        var parts = [device.isEmpty ? "no device" : device]
        if let ms = lastMs { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }

    private func setStatus(_ text: String, error: Bool = false) {
        status = text
        isError = error
    }
}
