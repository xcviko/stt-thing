import Foundation

struct Language: Hashable, Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

enum Languages {
    static let auto = Language(code: "auto", name: "Auto-detect")

    /// Languages parakeet-tdt-0.6b-v3 transcribes (it detects the language itself).
    static let speech: [Language] = [
        Language(code: "en", name: "English"),
        Language(code: "ru", name: "Russian"),
        Language(code: "uk", name: "Ukrainian"),
        Language(code: "de", name: "German"),
        Language(code: "fr", name: "French"),
        Language(code: "es", name: "Spanish"),
        Language(code: "it", name: "Italian"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "pl", name: "Polish"),
        Language(code: "nl", name: "Dutch"),
        Language(code: "sv", name: "Swedish"),
        Language(code: "da", name: "Danish"),
        Language(code: "fi", name: "Finnish"),
        Language(code: "cs", name: "Czech"),
        Language(code: "sk", name: "Slovak"),
        Language(code: "sl", name: "Slovenian"),
        Language(code: "hr", name: "Croatian"),
        Language(code: "bg", name: "Bulgarian"),
        Language(code: "ro", name: "Romanian"),
        Language(code: "hu", name: "Hungarian"),
        Language(code: "el", name: "Greek"),
        Language(code: "et", name: "Estonian"),
        Language(code: "lv", name: "Latvian"),
        Language(code: "lt", name: "Lithuanian"),
        Language(code: "mt", name: "Maltese"),
    ]

    static let source: [Language] = [auto] + speech

    static let target: [Language] = speech.filter { $0.code != "mt" } + [
        Language(code: "tr", name: "Turkish"),
        Language(code: "zh", name: "Chinese (Simplified)"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "ar", name: "Arabic"),
        Language(code: "he", name: "Hebrew"),
        Language(code: "hi", name: "Hindi"),
        Language(code: "ka", name: "Georgian"),
        Language(code: "kk", name: "Kazakh"),
        Language(code: "uz", name: "Uzbek"),
    ]

    static func name(_ code: String) -> String {
        (source + target).first { $0.code == code }?.name ?? code
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
    static let vertexProxyKeyFile = "~/.config/vertex-proxy/key"
    /// OpenRouter list price for the model, USD per 1M tokens. Used only when
    /// a response has no `usage.cost`.
    static let defaultInputPrice = 0.30
    static let defaultOutputPrice = 2.50

    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "tr.enabled") } }
    @Published var sourceLanguage: String { didSet { d.set(sourceLanguage, forKey: "tr.from") } }
    @Published var targetLanguage: String { didSet { d.set(targetLanguage, forKey: "tr.to") } }
    @Published var provider: Provider { didSet { d.set(provider.rawValue, forKey: "tr.provider") } }
    @Published var customBaseURL: String { didSet { d.set(customBaseURL, forKey: "tr.customURL") } }
    @Published var customModel: String { didSet { d.set(customModel, forKey: "tr.customModel") } }
    @Published var customInputPrice: Double { didSet { d.set(customInputPrice, forKey: "tr.customIn") } }
    @Published var customOutputPrice: Double { didSet { d.set(customOutputPrice, forKey: "tr.customOut") } }
    @Published var customMinimalReasoning: Bool { didSet { d.set(customMinimalReasoning, forKey: "tr.customReasoning") } }
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
        ])
        enabled = d.bool(forKey: "tr.enabled")
        sourceLanguage = d.string(forKey: "tr.from") ?? "en"
        targetLanguage = d.string(forKey: "tr.to") ?? "ru"
        provider = Provider(rawValue: d.string(forKey: "tr.provider") ?? "") ?? .openRouter
        customBaseURL = d.string(forKey: "tr.customURL") ?? Self.defaultCustomURL
        customModel = d.string(forKey: "tr.customModel") ?? Self.defaultCustomModel
        customInputPrice = d.double(forKey: "tr.customIn")
        customOutputPrice = d.double(forKey: "tr.customOut")
        customMinimalReasoning = d.bool(forKey: "tr.customReasoning")
        openRouterKey = KeyStore.get(account: "openrouter") ?? ""
        customKey = KeyStore.get(account: "custom") ?? ""
    }

    /// Reads the vertex-proxy key file into the custom key. Returns false when
    /// the file is missing or empty.
    func importVertexProxyKey() -> Bool {
        guard let key = Self.readVertexProxyKey() else { return false }
        customKey = key
        return true
    }

    static func readVertexProxyKey() -> String? {
        let path = (vertexProxyKeyFile as NSString).expandingTildeInPath
        guard let key = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
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
            // No key typed in and the URL is the vertex-proxy: use its key file.
            var key = customKey
            if key.isEmpty, url.host?.contains("vertex-proxy") == true {
                key = Self.readVertexProxyKey() ?? ""
            }
            return .success(Endpoint(
                chatURL: url, key: key, model: model.isEmpty ? Self.defaultCustomModel : model,
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
