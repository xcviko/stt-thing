import Foundation

enum TranslationError: Error, LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case badResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return "translation: \(s)"
        case .http(let code, let body): return "translation HTTP \(code): \(body)"
        case .badResponse(let s): return "translation: bad response (\(s))"
        case .network(let s): return "translation: \(s)"
        }
    }
}

/// Calls an OpenAI-compatible chat completions endpoint.
enum TranslationClient {
    struct Reply {
        let text: String
        let inputTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
        let cost: Double
        let costIsEstimate: Bool
        let latencyMs: Int
    }

    static func translate(
        _ text: String, context: [String], from: String, to: String,
        endpoint ep: TranslationSettings.Endpoint
    ) async throws -> Reply {
        let source = from == "auto" ? "the language it is spoken in" : Languages.name(from)
        let target = Languages.name(to)
        let system = """
        You translate live interview subtitles from \(source) into \(target). \
        The text comes from speech recognition and may contain recognition errors: \
        translate the intended meaning. Keep technical terms, product names and code \
        identifiers as they are when that is natural in \(target). If the text is \
        already in \(target), return it unchanged. Reply with the translation only, \
        without quotes, notes or the original.
        """
        var user = ""
        if !context.isEmpty {
            user += "Previous lines, for context only (do not translate them):\n"
            user += context.joined(separator: "\n") + "\n\nTranslate:\n"
        }
        user += text

        var body: [String: Any] = [
            "model": ep.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.2,
            "max_tokens": 1024,
        ]
        if ep.isOpenRouter {
            body["reasoning"] = ["effort": "minimal", "exclude": true]
        } else if ep.minimalReasoning {
            body["reasoning_effort"] = "minimal"
        }

        var req = URLRequest(url: ep.chatURL, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !ep.key.isEmpty { req.setValue("Bearer \(ep.key)", forHTTPHeaderField: "Authorization") }
        if ep.isOpenRouter {
            req.setValue("https://github.com/xcviko/stt-thing", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("stt-thing", forHTTPHeaderField: "X-Title")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw TranslationError.network(error.localizedDescription)
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TranslationError.http(status, errorMessage(data))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw TranslationError.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        let content = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let usage = obj["usage"] as? [String: Any] ?? [:]
        let input = usage["prompt_tokens"] as? Int ?? 0
        let output = usage["completion_tokens"] as? Int ?? 0
        let reasoning = (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0
        let reported = (usage["cost"] as? NSNumber)?.doubleValue
        let estimate = (Double(input) * ep.inputPrice + Double(output) * ep.outputPrice) / 1_000_000
        return Reply(
            text: content, inputTokens: input, outputTokens: output, reasoningTokens: reasoning,
            cost: reported ?? estimate, costIsEstimate: reported == nil, latencyMs: latency
        )
    }

    private static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
            if let m = obj["message"] as? String { return m }
        }
        return String(data: data.prefix(160), encoding: .utf8) ?? ""
    }
}

/// Translates committed transcript text sentence by sentence.
///
/// A sentence is sent once its end punctuation is followed by another
/// committed word (the last committed word can still change its
/// punctuation). Long runs without a sentence end are cut at a comma.
/// When the segment ends, the rest is sent.
final class Translator {
    struct Chunk {
        let source: String
        var text: String?
        var failed = false
    }

    private struct LineState {
        var sentUpTo = 0 // UTF-16 offset in the committed text
        var chunks: [Chunk] = []
    }

    let settings: TranslationSettings
    let usage: UsageStore
    /// (line id, translation so far, still waiting for some chunk)
    var onUpdate: ((Int, String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    private var lines: [Int: LineState] = [:]
    private var recentSources: [String] = []

    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[.?!…]["'”’)\]]*\s"#)

    init(settings: TranslationSettings, usage: UsageStore) {
        self.settings = settings
        self.usage = usage
    }

    func reset() {
        lines.removeAll()
        recentSources.removeAll()
    }

    func process(line id: Int, committed: String, final: Bool) {
        guard settings.enabled else { return }
        // Not configured (no key yet): say so, but leave the text alone.
        if case .failure(let err) = settings.endpoint() {
            onError?(err.localizedDescription)
            return
        }
        var state = lines[id] ?? LineState()
        let ns = committed as NSString
        guard ns.length > state.sentUpTo else {
            lines[id] = state
            return
        }

        var cut: Int?
        if final {
            cut = ns.length
        } else {
            let range = NSRange(location: state.sentUpTo, length: ns.length - state.sentUpTo)
            if let m = Self.sentenceEnd.matches(in: committed, range: range).last {
                cut = m.range.location + m.range.length - 1 // keep the space out
            } else {
                let rest = ns.substring(with: range)
                if rest.split(separator: " ").count >= 28 {
                    let comma = (rest as NSString).range(of: ", ", options: .backwards)
                    if comma.location != NSNotFound,
                       (rest as NSString).substring(to: comma.location).split(separator: " ").count >= 10 {
                        cut = state.sentUpTo + comma.location + 1
                    }
                }
            }
        }

        if let cut, cut > state.sentUpTo {
            let source = ns.substring(with: NSRange(location: state.sentUpTo, length: cut - state.sentUpTo))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            state.sentUpTo = cut
            if !source.isEmpty {
                state.chunks.append(Chunk(source: source))
                let index = state.chunks.count - 1
                lines[id] = state
                send(source, line: id, index: index)
                return
            }
        }
        lines[id] = state
    }

    private func send(_ source: String, line id: Int, index: Int) {
        let endpoint: TranslationSettings.Endpoint
        switch settings.endpoint() {
        case .success(let ep): endpoint = ep
        case .failure(let err):
            mark(line: id, index: index, text: nil)
            onError?(err.localizedDescription)
            return
        }
        let context = Array(recentSources.suffix(2))
        recentSources.append(source)
        if recentSources.count > 8 { recentSources.removeFirst(recentSources.count - 8) }
        let from = settings.sourceLanguage
        let to = settings.targetLanguage
        let conversation = usage.current.id
        publish(id)

        Task {
            do {
                let reply = try await TranslationClient.translate(
                    source, context: context, from: from, to: to, endpoint: endpoint
                )
                await MainActor.run {
                    self.usage.add(UsageRecord(
                        date: Date(), conversation: conversation,
                        provider: endpoint.isOpenRouter ? "openrouter" : endpoint.chatURL.host ?? "custom",
                        model: endpoint.model, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens,
                        reasoningTokens: reply.reasoningTokens, cost: reply.cost,
                        costIsEstimate: reply.costIsEstimate, latencyMs: reply.latencyMs
                    ))
                    self.mark(line: id, index: index, text: reply.text)
                }
            } catch {
                await MainActor.run {
                    self.mark(line: id, index: index, text: nil)
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    private func mark(line id: Int, index: Int, text: String?) {
        guard var state = lines[id], index < state.chunks.count else { return }
        if let text { state.chunks[index].text = text } else { state.chunks[index].failed = true }
        lines[id] = state
        publish(id)
    }

    private func publish(_ id: Int) {
        guard let state = lines[id] else { return }
        let pending = state.chunks.contains { $0.text == nil && !$0.failed }
        // Show translations in order: stop at the first chunk still in flight.
        var shown: [String] = []
        for c in state.chunks {
            if let t = c.text { shown.append(t) } else if c.failed { shown.append("[…]") } else { break }
        }
        onUpdate?(id, shown.joined(separator: " "), pending)
    }

    /// One short request to check the settings.
    static func test(settings: TranslationSettings) async -> String {
        switch settings.endpoint() {
        case .failure(let err): return err.localizedDescription
        case .success(let ep):
            do {
                let r = try await TranslationClient.translate(
                    "Could you walk me through the last project you shipped?", context: [],
                    from: "en", to: settings.targetLanguage, endpoint: ep
                )
                return "OK · \(r.latencyMs) ms · \(Money.format(r.cost))\(r.costIsEstimate ? " (est.)" : "")\n\(r.text)"
            } catch {
                return error.localizedDescription
            }
        }
    }
}
