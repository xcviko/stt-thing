import Foundation

/// One translation request.
struct UsageRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let conversation: UUID
    let provider: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cost: Double // USD
    let costIsEstimate: Bool // computed from token prices, not reported by the API
    let latencyMs: Int
}

/// A conversation starts when the app starts or on "New conversation".
struct ConversationInfo: Codable, Identifiable {
    let id: UUID
    let started: Date
}

/// Keeps translation costs in ~/Library/Application Support/STT Thing.
final class UsageStore: ObservableObject {
    @Published private(set) var records: [UsageRecord] = []
    @Published private(set) var conversations: [ConversationInfo] = []
    @Published private(set) var current: ConversationInfo

    private let recordsURL: URL
    private let conversationsURL: URL
    private let encoder = JSONEncoder()

    init() {
        let dir = ProcessInfo.processInfo.environment["STT_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("STT Thing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        recordsURL = dir.appendingPathComponent("usage.jsonl")
        conversationsURL = dir.appendingPathComponent("conversations.jsonl")
        encoder.dateEncodingStrategy = .iso8601
        current = ConversationInfo(id: UUID(), started: Date())
        records = Self.load(recordsURL)
        conversations = Self.load(conversationsURL)
        startConversation()
    }

    func startConversation() {
        // Drop the current conversation from history if nothing was spent in it.
        if !records.contains(where: { $0.conversation == current.id }),
           let i = conversations.firstIndex(where: { $0.id == current.id }) {
            conversations.remove(at: i)
            rewrite(conversations, to: conversationsURL)
        }
        current = ConversationInfo(id: UUID(), started: Date())
        conversations.append(current)
        append(current, to: conversationsURL)
    }

    func add(_ record: UsageRecord) {
        records.append(record)
        append(record, to: recordsURL)
    }

    // MARK: totals

    var conversationCost: Double { cost(records.filter { $0.conversation == current.id }) }
    var conversationRequests: Int { records.filter { $0.conversation == current.id }.count }

    var todayCost: Double {
        let start = Calendar.current.startOfDay(for: Date())
        return cost(records.filter { $0.date >= start })
    }

    var totalCost: Double { cost(records) }

    func cost(_ list: [UsageRecord]) -> Double { list.reduce(0) { $0 + $1.cost } }

    // MARK: files

    private static func load<T: Decodable>(_ url: URL) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    private func append<T: Encodable>(_ item: T, to url: URL) {
        guard var data = try? encoder.encode(item) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func rewrite<T: Encodable>(_ items: [T], to url: URL) {
        var data = Data()
        for item in items {
            if let line = try? encoder.encode(item) { data.append(line); data.append(0x0A) }
        }
        try? data.write(to: url)
    }
}

enum Money {
    /// $0.0042 for small amounts, $1.23 for big ones.
    static func format(_ usd: Double) -> String {
        if usd == 0 { return "$0" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        if usd < 1 { return String(format: "$%.3f", usd) }
        return String(format: "$%.2f", usd)
    }

    /// Axis labels: enough decimals for the largest value on the axis, the
    /// same for every tick ($0.00050, $0.00100, $0.00150).
    static func axis(_ usd: Double, max: Double) -> String {
        if usd == 0 { return "$0" }
        let decimals = max > 0 ? Swift.min(7, Swift.max(2, Int(ceil(-log10(max))) + 2)) : 2
        return String(format: "$%.\(decimals)f", usd)
    }
}
