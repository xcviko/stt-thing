import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: TranslationSettings
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("Translation") {
                Toggle("Translate the transcript", isOn: $settings.enabled)
                Picker("From", selection: $settings.sourceLanguage) {
                    ForEach(Languages.source) { Text($0.name).tag($0.code) }
                }
                Picker("To", selection: $settings.targetLanguage) {
                    ForEach(Languages.target) { Text($0.name).tag($0.code) }
                }
                Text("Speech recognition is parakeet v3: it understands the 25 European languages in the From list and detects the language itself. From only tells the translator what to expect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Provider") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if settings.provider == .openRouter {
                    SecureField("API key", text: $settings.openRouterKey, prompt: Text("sk-or-…"))
                    LabeledContent("Model", value: "\(TranslationSettings.model), minimal thinking")
                    LabeledContent(
                        "Price",
                        value: "$\(fmt(TranslationSettings.defaultInputPrice)) in / $\(fmt(TranslationSettings.defaultOutputPrice)) out per 1M tokens"
                    )
                } else {
                    TextField("Base URL", text: $settings.customBaseURL, prompt: Text("https://host/v1"))
                    HStack {
                        SecureField("API key", text: $settings.customKey, prompt: Text("empty = vertex-proxy key file"))
                        Button("From vertex-proxy") {
                            testResult = settings.importVertexProxyKey()
                                ? "Key taken from \(TranslationSettings.vertexProxyKeyFile)"
                                : "No key in \(TranslationSettings.vertexProxyKeyFile)"
                        }
                        .help("Use the key from \(TranslationSettings.vertexProxyKeyFile)")
                    }
                    TextField("Model", text: $settings.customModel)
                    Toggle("Send reasoning_effort: minimal", isOn: $settings.customMinimalReasoning)
                    HStack {
                        TextField("Input $ / 1M", value: $settings.customInputPrice, format: .number)
                        TextField("Output $ / 1M", value: $settings.customOutputPrice, format: .number)
                    }
                    Text("The app calls {Base URL}/chat/completions. Cost comes from usage.cost in the response (vertex-proxy and OpenRouter send it); otherwise it is counted from the token prices above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top) {
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .disabled(testing)
                    Text(testResult)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private func runTest() {
        testing = true
        testResult = ""
        Task {
            let result = await Translator.test(settings: settings)
            await MainActor.run {
                testResult = result
                testing = false
            }
        }
    }
}
