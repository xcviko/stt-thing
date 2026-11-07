import SwiftUI

struct Line: Identifiable, Equatable {
    let id: Int
    var committed: String
    var tentative: String
    var final: Bool
    var translation: String = ""
    var translationPending = false
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
    /// Share of the text space the original gets when translation is on.
    @Published var split: CGFloat {
        didSet { UserDefaults.standard.set(Double(split), forKey: "split") }
    }
    /// Last translation problem, cleared after a few seconds.
    @Published var translationError: String?

    /// Called with (line id, committed text, final) on every transcript update.
    var onCommitted: ((Int, String, Bool) -> Void)?

    private var lastMs: Int?
    /// Segment ids restart at 1 when the backend restarts; this keeps line ids unique.
    private var generation = 0
    private var errorClearTask: DispatchWorkItem?

    init(fontSize: CGFloat, opacity: Double) {
        self.fontSize = fontSize
        self.opacity = opacity
        let saved = UserDefaults.standard.double(forKey: "split")
        self.split = saved > 0 ? CGFloat(saved) : 0.45
    }

    func loading(device: String) {
        ready = false
        generation += 1
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
            let id = generation * 1_000_000 + seg
            if let i = lines.firstIndex(where: { $0.id == id }) {
                if committed.isEmpty && tentative.isEmpty && final {
                    lines.remove(at: i)
                } else {
                    lines[i].committed = committed
                    lines[i].tentative = tentative
                    lines[i].final = final
                }
            } else if !(committed.isEmpty && tentative.isEmpty) {
                lines.append(Line(id: id, committed: committed, tentative: tentative, final: final))
            }
            if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
            lastMs = ms
            setStatus(statusLine())
            onCommitted?(id, committed, final)
        case .error(let message):
            setStatus(message, error: true)
        case .stopped(let code):
            ready = false
            speech = false
            setStatus("backend stopped (code \(code)) · right-click → Restart backend", error: true)
        }
    }

    func setTranslation(line id: Int, text: String, pending: Bool) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].translation = text
        lines[i].translationPending = pending
    }

    func showTranslationError(_ message: String) {
        translationError = message
        errorClearTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.translationError = nil }
        errorClearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
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
