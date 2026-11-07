import AppKit
import SwiftUI

/// Height of the top bar. The rest of the panel lets clicks through unless
/// the transcript is paused.
let topBarHeight: CGFloat = 26

struct OverlayView: View {
    @ObservedObject var transcript: Transcript
    var onTogglePause: () -> Void
    var onMenu: () -> Void

    private let textColor = Color(red: 0.957, green: 0.957, blue: 0.945)
    private let live = Color(red: 0.373, green: 0.827, blue: 0.553)
    private let paused = Color(red: 1.0, green: 0.78, blue: 0.35)
    private let errorColor = Color(red: 1.0, green: 0.478, blue: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            textArea
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.08).opacity(transcript.opacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    transcript.paused ? paused.opacity(0.45) : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: top bar (drag handle + controls)

    private var topBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(transcript.paused ? "paused · scroll to read · \(transcript.status)" : transcript.status)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(transcript.isError ? errorColor : textColor.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            BarButton(
                symbol: transcript.paused ? "play.fill" : "pause.fill",
                help: transcript.paused ? "Resume (back to live)" : "Pause to scroll back",
                tint: transcript.paused ? paused : textColor.opacity(0.55),
                action: onTogglePause
            )
            BarButton(symbol: "ellipsis", help: "Menu", tint: textColor.opacity(0.55), action: onMenu)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: topBarHeight)
        .background(WindowDragArea())
    }

    private var dotColor: Color {
        if transcript.isError { return errorColor }
        return transcript.speech ? live : textColor.opacity(0.42)
    }

    // MARK: transcript

    private var textArea: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: transcript.paused) {
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer(minLength: 0)
                        if transcript.lines.isEmpty {
                            Text(transcript.ready ? "Listening on \(transcript.device)…" : "Loading model…")
                                .font(.system(size: 15))
                                .foregroundColor(textColor.opacity(0.42))
                        } else {
                            ForEach(transcript.lines) { line in
                                lineText(line)
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
