import AppKit
import SwiftUI

/// Layout of the panel. The app uses the same numbers to decide where the
/// panel takes the mouse (top bar, divider, resize edges); the rest lets
/// clicks through unless the transcript is paused.
enum OverlayLayout {
    static let topBar: CGFloat = 26
    static let divider: CGFloat = 22
    static let resizeEdge: CGFloat = 6
    static let resizeCorner: CGFloat = 16
    static let minSize = NSSize(width: 280, height: 90)

    /// Height of the text space shared by both sections.
    static func textSpace(panelHeight: CGFloat) -> CGFloat {
        max(0, panelHeight - topBar - divider)
    }
}

/// One panel: recognized text on top, translation below (when translation is
/// on), divided by a bar that can be dragged to change the split.
struct OverlayView: View {
    @ObservedObject var transcript: Transcript
    @ObservedObject var settings: TranslationSettings
    @ObservedObject var usage: UsageStore
    var onTogglePause: () -> Void
    var onMenu: () -> Void

    private let textColor = Color(red: 0.957, green: 0.957, blue: 0.945)
    private let live = Color(red: 0.373, green: 0.827, blue: 0.553)
    private let paused = Color(red: 1.0, green: 0.78, blue: 0.35)
    private let errorColor = Color(red: 1.0, green: 0.478, blue: 0.42)
    private let accent = Color(red: 0.49, green: 0.71, blue: 1.0)
    private let originalBackground = Color(red: 0.07, green: 0.07, blue: 0.08)
    private let translationBackground = Color(red: 0.04, green: 0.08, blue: 0.19)

    var body: some View {
        GeometryReader { geo in
            let space = OverlayLayout.textSpace(panelHeight: geo.size.height)
            VStack(spacing: 0) {
                topBar
                if settings.enabled {
                    section(.original)
                        .frame(height: space * transcript.split)
                    dividerBar
                    section(.translation)
                        .frame(maxHeight: .infinity)
                        .background(translationBackground.opacity(transcript.opacity))
                } else {
                    section(.original)
                        .frame(maxHeight: .infinity)
                }
            }
            .background(originalBackground.opacity(transcript.opacity))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(transcript.paused ? paused.opacity(0.45) : Color.white.opacity(0.09), lineWidth: 1)
            )
            .overlay(alignment: .trailing) {
                ResizeArea(edges: [.right]).frame(width: OverlayLayout.resizeEdge).padding(.vertical, 16)
            }
            .overlay(alignment: .bottom) {
                ResizeArea(edges: [.bottom]).frame(height: OverlayLayout.resizeEdge).padding(.horizontal, 16)
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    ResizeArea(edges: [.right, .bottom])
                    GripGlyph().stroke(textColor.opacity(0.3), lineWidth: 1).frame(width: 8, height: 8)
                        .allowsHitTesting(false)
                }
                .frame(width: OverlayLayout.resizeCorner, height: OverlayLayout.resizeCorner)
            }
        }
    }

    // MARK: top bar (drag handle + controls)

    private var topBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(transcript.paused ? "paused · not listening · scroll to read" : transcript.status)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(transcript.isError ? errorColor : textColor.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if settings.enabled || usage.conversationCost > 0 {
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
        .frame(height: OverlayLayout.topBar)
        .background(WindowDragArea())
    }

    private var dotColor: Color {
        if transcript.isError { return errorColor }
        return transcript.speech ? live : textColor.opacity(0.42)
    }

    // MARK: divider (translation header, drag to change the split)

    private var dividerBar: some View {
        HStack(spacing: 7) {
            Text(languagePair)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(translationBackground)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(accent))
            Text(transcript.translationError ?? Languages.name(settings.targetLanguage))
                .font(.system(size: 11))
                .foregroundColor(transcript.translationError != nil ? errorColor : accent.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(accent.opacity(0.45))
                .padding(.trailing, 10)
        }
        .padding(.leading, 12)
        .frame(height: OverlayLayout.divider)
        .background(translationBackground.opacity(min(1, transcript.opacity + 0.1)))
        .overlay(alignment: .top) { Rectangle().fill(accent.opacity(0.3)).frame(height: 1) }
        .background(SplitDragArea(split: $transcript.split))
        .help("Drag to change the split")
    }

    private var languagePair: String {
        let from = settings.sourceLanguage == "auto" ? "AUTO" : settings.sourceLanguage.uppercased()
        return "\(from) → \(settings.targetLanguage.uppercased())"
    }

    // MARK: text sections

    private enum Kind { case original, translation }

    private func lines(_ kind: Kind) -> [Line] {
        guard kind == .translation else { return transcript.lines }
        return transcript.lines.filter { !$0.translation.isEmpty || waiting($0) }
    }

    private func waiting(_ line: Line) -> Bool {
        line.translationPending || (!line.final && !line.committed.isEmpty)
    }

    private func placeholder(_ kind: Kind) -> String {
        if kind == .translation { return "Translation into \(Languages.name(settings.targetLanguage)) appears here" }
        return transcript.ready ? "Listening on \(transcript.device)…" : "Loading model…"
    }

    private func section(_ kind: Kind) -> some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: transcript.paused) {
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer(minLength: 0)
                        let shown = lines(kind)
                        if shown.isEmpty {
                            Text(placeholder(kind))
                                .font(.system(size: 14))
                                .foregroundColor(textColor.opacity(0.4))
                        } else {
                            ForEach(shown) { line in
                                (kind == .translation ? translationText(line) : lineText(line))
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
                .onChange(of: transcript.split) {
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
                        .init(color: .black, location: min(0.3, 18 / max(geo.size.height, 1))),
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

/// Two short diagonal strokes in the bottom-right corner.
private struct GripGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}

/// Mouse down here drags the window (the top bar).
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

/// Dragging the divider changes how much of the text space the original gets.
private struct SplitDragArea: NSViewRepresentable {
    @Binding var split: CGFloat

    final class SplitView: NSView {
        var onSplit: ((CGFloat) -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let grabOffset = convert(event.locationInWindow, from: nil).y - bounds.midY
            while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if e.type == .leftMouseUp { break }
                // Window coordinates: origin bottom-left.
                let height = window.frame.height
                let space = OverlayLayout.textSpace(panelHeight: height)
                guard space > 0 else { continue }
                let fromTop = height - e.locationInWindow.y + grabOffset
                let original = fromTop - OverlayLayout.topBar - OverlayLayout.divider / 2
                onSplit?(min(0.85, max(0.15, original / space)))
            }
        }
    }

    func makeNSView(context: Context) -> SplitView {
        let v = SplitView()
        v.onSplit = { split = $0 }
        return v
    }

    func updateNSView(_ nsView: SplitView, context: Context) {
        nsView.onSplit = { split = $0 }
    }
}

/// Drag to resize the window by its right edge, bottom edge or the corner.
/// The top-left corner stays in place.
private struct ResizeArea: NSViewRepresentable {
    struct Edges: OptionSet {
        let rawValue: Int
        static let right = Edges(rawValue: 1)
        static let bottom = Edges(rawValue: 2)
    }

    let edges: Edges

    final class ResizeView: NSView {
        var edges: Edges = []
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            let cursor: NSCursor
            if edges == [.right] {
                cursor = .resizeLeftRight
            } else if edges == [.bottom] {
                cursor = .resizeUpDown
            } else if #available(macOS 15, *) {
                cursor = .frameResize(position: .bottomRight, directions: .all)
            } else {
                cursor = .crosshair
            }
            addCursorRect(bounds, cursor: cursor)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let start = window.frame
            let startMouse = NSEvent.mouseLocation
            let minSize = OverlayLayout.minSize
            while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if e.type == .leftMouseUp { break }
                let p = NSEvent.mouseLocation
                var f = start
                if edges.contains(.right) {
                    f.size.width = max(minSize.width, start.width + (p.x - startMouse.x))
                }
                if edges.contains(.bottom) {
                    let h = max(minSize.height, start.height - (p.y - startMouse.y))
                    f.origin.y = start.maxY - h
                    f.size.height = h
                }
                window.setFrame(f, display: true)
            }
        }
    }

    func makeNSView(context: Context) -> ResizeView {
        let v = ResizeView()
        v.edges = edges
        return v
    }

    func updateNSView(_ nsView: ResizeView, context: Context) {
        nsView.edges = edges
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}
