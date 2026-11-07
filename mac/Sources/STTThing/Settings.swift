import Foundation
import Security

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

/// Translation settings. Plain values live in UserDefaults, API keys in the
/// Keychain.
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
    @Published var showOriginal: Bool { didSet { d.set(showOriginal, forKey: "tr.showOriginal") } }
    @Published var provider: Provider { didSet { d.set(provider.rawValue, forKey: "tr.provider") } }
    @Published var customBaseURL: String { didSet { d.set(customBaseURL, forKey: "tr.customURL") } }
    @Published var customModel: String { didSet { d.set(customModel, forKey: "tr.customModel") } }
    @Published var customInputPrice: Double { didSet { d.set(customInputPrice, forKey: "tr.customIn") } }
    @Published var customOutputPrice: Double { didSet { d.set(customOutputPrice, forKey: "tr.customOut") } }
    @Published var customMinimalReasoning: Bool { didSet { d.set(customMinimalReasoning, forKey: "tr.customReasoning") } }
    @Published var openRouterKey: String { didSet { Keychain.set(openRouterKey, account: "openrouter") } }
    @Published var customKey: String { didSet { Keychain.set(customKey, account: "custom") } }

    init() {
        d.register(defaults: [
            "tr.enabled": false,
            "tr.from": "en",
            "tr.to": "ru",
            "tr.showOriginal": true,
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
        showOriginal = d.bool(forKey: "tr.showOriginal")
        provider = Provider(rawValue: d.string(forKey: "tr.provider") ?? "") ?? .openRouter
        customBaseURL = d.string(forKey: "tr.customURL") ?? Self.defaultCustomURL
        customModel = d.string(forKey: "tr.customModel") ?? Self.defaultCustomModel
        customInputPrice = d.double(forKey: "tr.customIn")
        customOutputPrice = d.double(forKey: "tr.customOut")
        customMinimalReasoning = d.bool(forKey: "tr.customReasoning")
        openRouterKey = Keychain.get(account: "openrouter") ?? ""
        customKey = Keychain.get(account: "custom") ?? ""
    }

    /// Reads the vertex-proxy key file into the custom key. Returns false when
    /// the file is missing or empty.
    func importVertexProxyKey() -> Bool {
        let path = (Self.vertexProxyKeyFile as NSString).expandingTildeInPath
        guard let key = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return false }
        customKey = key
        return true
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

enum Keychain {
    private static let service = "com.xcviko.stt-thing"

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
