import SwiftUI

struct OverlayView: View {
    @ObservedObject var transcript: Transcript

    private let textColor = Color(red: 0.957, green: 0.957, blue: 0.945)
    private let live = Color(red: 0.373, green: 0.827, blue: 0.553)
    private let errorColor = Color(red: 1.0, green: 0.478, blue: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            textArea
            statusBar
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.08).opacity(transcript.opacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var textArea: some View {
        // Newest text sits at the bottom; older lines scroll out of the top
        // and fade.
        GeometryReader { geo in
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
                    }
                }
            }
            .frame(width: geo.size.width - 32, height: geo.size.height - 12, alignment: .bottomLeading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: min(0.3, 28 / max(geo.size.height, 1)))],
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

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(transcript.isError ? errorColor : (transcript.speech ? live : textColor.opacity(0.42)))
                .frame(width: 7, height: 7)
            Text(transcript.status)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(transcript.isError ? errorColor : textColor.opacity(0.42))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 22)
        .padding(.bottom, 4)
    }
}
