import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: TranslationSettings
    @ObservedObject var prefs: AppPreferences
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("App") {
                Toggle("Show in the Dock", isOn: $prefs.showInDock)
                    .disabled(prefs.showInDock && !prefs.showInMenuBar)
                Toggle("Show in the menu bar", isOn: $prefs.showInMenuBar)
                    .disabled(prefs.showInMenuBar && !prefs.showInDock)
                Text("One of them stays on, so the menu is always one click away. ⌥⌘T shows or hides the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Translation") {
                Toggle("Translate the transcript", isOn: $settings.enabled)
                Picker("From", selection: $settings.sourceLanguage) {
                    ForEach(Languages.source) { Text($0.name).tag($0.code) }
                }
                Picker("To", selection: $settings.targetLanguage) {
                    ForEach(Languages.target) { Text($0.name).tag($0.code) }
                }
                Text("Translation goes between English and Russian. Speech recognition hears 25 European languages by itself.")
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
                    SecureField("API key", text: $settings.customKey, prompt: Text("paste the key for this app"))
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

                Toggle("Send each sentence twice, show the faster answer", isOn: $settings.raceRequests)
                Text("Slow answers come about 0.3 s sooner, typical ones about 0.1 s. Twice the requests: on OpenRouter that is twice the cost, on a subscription proxy twice the quota.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
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
