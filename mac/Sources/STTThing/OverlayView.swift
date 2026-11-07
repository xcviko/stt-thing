import AppKit
import SwiftUI

/// Height of the top bar. The rest of the panel lets clicks through unless
/// the transcript is paused.
let topBarHeight: CGFloat = 26

enum PanelKind {
    case original
    case translation
}

/// One floating panel: the recognized text or its translation. Both panels
/// share the transcript, so pause and scrolling work the same in each.
struct OverlayView: View {
    let kind: PanelKind
    @ObservedObject var transcript: Transcript
    @ObservedObject var settings: TranslationSettings
    @ObservedObject var usage: UsageStore
    var onTogglePause: () -> Void
    var onMenu: () -> Void

    private let textColor = Color(red: 0.957, green: 0.957, blue: 0.945)
    private let live = Color(red: 0.373, green: 0.827, blue: 0.553)
    private let paused = Color(red: 1.0, green: 0.78, blue: 0.35)
    private let errorColor = Color(red: 1.0, green: 0.478, blue: 0.42)
    /// Accent of the translation panel.
    private let accent = Color(red: 0.49, green: 0.71, blue: 1.0)

    private var isTranslation: Bool { kind == .translation }

    private var background: Color {
        isTranslation
            ? Color(red: 0.05, green: 0.08, blue: 0.16) // deep blue
            : Color(red: 0.07, green: 0.07, blue: 0.08)
    }

    private var border: Color {
        if transcript.paused { return paused.opacity(0.45) }
        return isTranslation ? accent.opacity(0.28) : Color.white.opacity(0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            textArea
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(background.opacity(transcript.opacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: top bar (drag handle + controls)

    private var topBar: some View {
        HStack(spacing: 7) {
            if isTranslation {
                Text(languagePair)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(background)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(accent))
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }
            Text(statusText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(statusIsError ? errorColor : textColor.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if isTranslation {
                Text(Money.format(usage.conversationCost))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(accent.opacity(0.85))
                    .help("Translation cost in this conversation")
            }
            BarButton(
                symbol: transcript.paused ? "play.fill" : "pause.fill",
                help: transcript.paused ? "Resume listening" : "Pause listening",
                tint: transcript.paused ? paused : textColor.opacity(0.55),
                action: onTogglePause
            )
            BarButton(symbol: "ellipsis", help: "Menu", tint: textColor.opacity(0.55), action: onMenu)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: topBarHeight)
        .background(WindowDragArea())
    }

    private var languagePair: String {
        let from = settings.sourceLanguage == "auto" ? "AUTO" : settings.sourceLanguage.uppercased()
        return "\(from) → \(settings.targetLanguage.uppercased())"
    }

    private var statusText: String {
        if isTranslation {
            if let err = transcript.translationError { return err }
            if transcript.paused { return "paused" }
            return Languages.name(settings.targetLanguage)
        }
        if transcript.paused { return "paused · not listening · scroll to read" }
        return transcript.status
    }

    private var statusIsError: Bool {
        isTranslation ? transcript.translationError != nil : transcript.isError
    }

    private var dotColor: Color {
        if transcript.isError { return errorColor }
        return transcript.speech ? live : textColor.opacity(0.42)
    }

    // MARK: text

    private var visibleLines: [Line] {
        guard isTranslation else { return transcript.lines }
        return transcript.lines.filter { !$0.translation.isEmpty || waiting($0) }
    }

    private func waiting(_ line: Line) -> Bool {
        line.translationPending || (!line.final && !line.committed.isEmpty)
    }

    private var placeholder: String {
        if isTranslation { return "Translation into \(Languages.name(settings.targetLanguage)) appears here" }
        return transcript.ready ? "Listening on \(transcript.device)…" : "Loading model…"
    }

    private var textArea: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: transcript.paused) {
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer(minLength: 0)
                        let lines = visibleLines
                        if lines.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 15))
                                .foregroundColor(textColor.opacity(0.42))
                        } else {
                            ForEach(lines) { line in
                                (isTranslation ? translationText(line) : lineText(line))
                                    .font(.system(size: transcript.fontSize))
                                    .lineSpacing(transcript.fontSize * 0.18)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    // Short text sits at the bottom, like subtitles.
                    .frame(minHeight: geo.size.height, alignment: .bottom)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: transcript.lines) {
                    if !transcript.paused { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: transcript.fontSize) {
                    if !transcript.paused { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: transcript.paused) { _, isPaused in
                    if !isPaused {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: transcript.paused ? .black : .clear, location: 0),
                        .init(color: .black, location: min(0.3, 22 / max(geo.size.height, 1))),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
    }

    private func translationText(_ line: Line) -> Text {
        let done = line.final && !line.translationPending
        let dots = Text(line.translation.isEmpty ? "…" : " …").foregroundColor(textColor.opacity(0.4))
        let main = Text(line.translation).foregroundColor(done ? textColor.opacity(0.62) : textColor)
        return waiting(line) ? main + dots : main
    }

    private func lineText(_ line: Line) -> Text {
        let main = Text(line.committed)
            .foregroundColor(line.final ? textColor.opacity(0.62) : textColor)
        guard !line.tentative.isEmpty else { return main }
        let sep = line.committed.isEmpty ? "" : " "
        return main + Text(sep + line.tentative).foregroundColor(textColor.opacity(0.5))
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(hover ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// Mouse down here drags the window (only the top bar uses it).
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
