import Foundation

struct Language: Hashable, Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

/// Translation goes between English and Russian only. (Speech recognition
/// itself still hears all 25 languages Parakeet Ultra knows.)
enum Languages {
    static let english = Language(code: "en", name: "English")
    static let russian = Language(code: "ru", name: "Russian")

    static let source: [Language] = [english, russian]
    static let target: [Language] = [russian, english]

    static func name(_ code: String) -> String {
        source.first { $0.code == code }?.name ?? code
    }

    /// A saved choice that is no longer offered falls back to the default.
    static func supported(_ code: String?, fallback: String) -> String {
        guard let code, source.contains(where: { $0.code == code }) else { return fallback }
        return code
    }
}

enum Provider: String, CaseIterable, Identifiable {
    case openRouter = "openrouter"
    case custom = "custom"
    var id: String { rawValue }
    var title: String { self == .openRouter ? "OpenRouter" : "Custom (OpenAI API)" }
}

/// Translation settings. Plain values live in UserDefaults, API keys in
/// keys.json (see KeyStore).
final class TranslationSettings: ObservableObject {
    static let openRouterURL = "https://openrouter.ai/api/v1"
    static let model = "google/gemini-3.5-flash-lite"
    /// The user's Vertex AI proxy (OpenAI surface). It returns usage.cost too.
    static let defaultCustomURL = "https://vertex-proxy-302q-a6klnxibxa-uc.a.run.app/v1"
    static let defaultCustomModel = "gemini-3.5-flash-lite"
    /// OpenRouter list price for the model, USD per 1M tokens. Used only when
    /// a response has no `usage.cost`.
    static let defaultInputPrice = 0.30
    static let defaultOutputPrice = 2.50

    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "tr.enabled") } }
    // With two languages, picking one side flips the other.
    @Published var sourceLanguage: String {
        didSet {
            d.set(sourceLanguage, forKey: "tr.from")
            if targetLanguage == sourceLanguage { targetLanguage = sourceLanguage == "en" ? "ru" : "en" }
        }
    }
    @Published var targetLanguage: String {
        didSet {
            d.set(targetLanguage, forKey: "tr.to")
            if sourceLanguage == targetLanguage { sourceLanguage = targetLanguage == "en" ? "ru" : "en" }
        }
    }
    @Published var provider: Provider { didSet { d.set(provider.rawValue, forKey: "tr.provider") } }
    @Published var customBaseURL: String { didSet { d.set(customBaseURL, forKey: "tr.customURL") } }
    @Published var customModel: String { didSet { d.set(customModel, forKey: "tr.customModel") } }
    @Published var customInputPrice: Double { didSet { d.set(customInputPrice, forKey: "tr.customIn") } }
    @Published var customOutputPrice: Double { didSet { d.set(customOutputPrice, forKey: "tr.customOut") } }
    @Published var customMinimalReasoning: Bool { didSet { d.set(customMinimalReasoning, forKey: "tr.customReasoning") } }
    /// Send each sentence twice and show the first answer.
    @Published var raceRequests: Bool { didSet { d.set(raceRequests, forKey: "tr.race") } }
    @Published var openRouterKey: String { didSet { KeyStore.set(openRouterKey, account: "openrouter") } }
    @Published var customKey: String { didSet { KeyStore.set(customKey, account: "custom") } }

    init() {
        d.register(defaults: [
            "tr.enabled": false,
            "tr.from": "en",
            "tr.to": "ru",
            "tr.provider": Provider.openRouter.rawValue,
            "tr.customURL": Self.defaultCustomURL,
            "tr.customModel": Self.defaultCustomModel,
            "tr.customIn": Self.defaultInputPrice,
            "tr.customOut": Self.defaultOutputPrice,
            "tr.customReasoning": true,
            "tr.race": false,
        ])
        enabled = d.bool(forKey: "tr.enabled")
        sourceLanguage = Languages.supported(d.string(forKey: "tr.from"), fallback: "en")
        targetLanguage = Languages.supported(d.string(forKey: "tr.to"), fallback: "ru")
        provider = Provider(rawValue: d.string(forKey: "tr.provider") ?? "") ?? .openRouter
        customBaseURL = d.string(forKey: "tr.customURL") ?? Self.defaultCustomURL
        customModel = d.string(forKey: "tr.customModel") ?? Self.defaultCustomModel
        customInputPrice = d.double(forKey: "tr.customIn")
        customOutputPrice = d.double(forKey: "tr.customOut")
        customMinimalReasoning = d.bool(forKey: "tr.customReasoning")
        raceRequests = d.bool(forKey: "tr.race")
        openRouterKey = KeyStore.get(account: "openrouter") ?? ""
        customKey = KeyStore.get(account: "custom") ?? ""
    }

    /// Everything a request needs, or a message saying what is missing.
    struct Endpoint {
        let chatURL: URL
        let key: String
        let model: String
        let isOpenRouter: Bool
        let minimalReasoning: Bool
        let inputPrice: Double // USD per 1M tokens
        let outputPrice: Double
    }

    func endpoint() -> Result<Endpoint, TranslationError> {
        switch provider {
        case .openRouter:
            guard !openRouterKey.isEmpty else { return .failure(.notConfigured("set the OpenRouter API key")) }
            return .success(Endpoint(
                chatURL: URL(string: Self.openRouterURL + "/chat/completions")!,
                key: openRouterKey, model: Self.model, isOpenRouter: true, minimalReasoning: true,
                inputPrice: Self.defaultInputPrice, outputPrice: Self.defaultOutputPrice
            ))
        case .custom:
            var base = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            if base.hasSuffix("/chat/completions") { base = String(base.dropLast("/chat/completions".count)) }
            guard !base.isEmpty, let url = URL(string: base + "/chat/completions"), url.scheme != nil else {
                return .failure(.notConfigured("set the custom endpoint URL"))
            }
            let model = customModel.trimmingCharacters(in: .whitespaces)
            return .success(Endpoint(
                chatURL: url, key: customKey, model: model.isEmpty ? Self.defaultCustomModel : model,
                isOpenRouter: false, minimalReasoning: customMinimalReasoning,
                inputPrice: customInputPrice, outputPrice: customOutputPrice
            ))
        }
    }
}

/// API keys in ~/Library/Application Support/stt-thing/keys.json, readable
/// only by the user (0600). Not the Keychain: with ad-hoc signing every
/// rebuild changes the app's signature and the Keychain asks for the
/// password again.
enum KeyStore {
    private static var url: URL {
        AppPaths.dataDir.appendingPathComponent("keys.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }

    static func get(account: String) -> String? {
        load()[account]
    }

    static func set(_ value: String, account: String) {
        var dict = load()
        if value.isEmpty { dict.removeValue(forKey: account) } else { dict[account] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        let path = url.path
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

/// Where the app shows itself besides its panel. At least one stays on, so
/// the menu is always reachable.
final class AppPreferences: ObservableObject {
    private let d = UserDefaults.standard

    @Published var showInDock: Bool {
        didSet {
            d.set(showInDock, forKey: "showInDock")
            if !showInDock && !showInMenuBar { showInMenuBar = true }
        }
    }

    @Published var showInMenuBar: Bool {
        didSet {
            d.set(showInMenuBar, forKey: "showInMenuBar")
            if !showInMenuBar && !showInDock { showInDock = true }
        }
    }

    init() {
        d.register(defaults: ["showInDock": true, "showInMenuBar": true])
        showInDock = d.bool(forKey: "showInDock")
        showInMenuBar = d.bool(forKey: "showInMenuBar")
    }
}
