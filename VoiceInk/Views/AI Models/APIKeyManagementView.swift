import LLMkit
import SwiftUI

struct APIKeyManagementView: View {
    @EnvironmentObject private var aiService: AIService
    @ObservedObject private var customAIProviderManager = CustomAIProviderManager.shared
    @State private var apiKey: String = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isVerifying = false
    @State private var ollamaBaseURL: String =
        UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
    @State private var ollamaModels: [OllamaModel] = []
    @State private var selectedOllamaModel: String =
        UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "mistral"
    @State private var isCheckingOllama = false
    @State private var isEditingURL = false
    @State private var localCLICommandTemplate: String = ""
    @State private var localCLITimeoutSeconds: Double = LocalCLIService.defaultTimeoutSeconds
    @State private var isSyncingLocalCLIState = false

    private var providerOptions: [AIProvider] {
        AIProvider.allCases.filter { provider in
            guard provider.supportsEnhancement else { return false }
            guard provider != .voiceInkRefine else { return false }
            if provider == .custom {
                return customAIProviderManager.hasConfiguredModels
            }
            return true
        }
    }

    var body: some View {
        Section("AI Provider Integration") {
            HStack {
                Picker("Provider", selection: $aiService.selectedProvider) {
                    ForEach(providerOptions, id: \.self) { provider in
                        Text(providerTitle(provider)).tag(provider)
                    }
                }
                .pickerStyle(.automatic)
                .tint(AppTheme.Status.infoStrong)

                if aiService.selectedProvider == .openAI {
                    Spacer()
                    let isConnected = aiService.openAIAuthMode == .oauth
                        ? aiService.isOAuthAuthenticated
                        : aiService.isAPIKeyValid
                    if isConnected {
                        Circle()
                            .fill(AppTheme.Status.positive)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else if aiService.isAPIKeyValid && aiService.selectedProvider != .ollama {
                    Spacer()
                    Circle()
                        .fill(AppTheme.Status.positive)
                        .frame(width: 8, height: 8)
                    Text("Connected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else if aiService.selectedProvider == .ollama {
                    Spacer()
                    if isCheckingOllama {
                        ProgressView()
                            .controlSize(.small)
                    } else if !ollamaModels.isEmpty {
                        Circle()
                            .fill(AppTheme.Status.positive)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Circle()
                            .fill(AppTheme.Status.error)
                            .frame(width: 8, height: 8)
                        Text("Disconnected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onAppear {
                syncSelectedProviderAvailability()
                syncSelectedCustomModelIfNeeded()
            }
            .onChange(of: aiService.selectedProvider) { oldValue, newValue in
                if aiService.selectedProvider == .ollama {
                    checkOllamaConnection(showError: false)
                }
                if aiService.selectedProvider == .localCLI {
                    syncLocalCLIStateFromService()
                }
                syncSelectedCustomModelIfNeeded()
            }
            .onChange(of: customAIProviderManager.providers) { _, _ in
                syncSelectedProviderAvailability()
                syncSelectedCustomModelIfNeeded()
            }

            VStack(alignment: .leading, spacing: 12) {
                // Model Selection
                if aiService.selectedProvider == .openRouter {
                    if aiService.availableModels.isEmpty {
                        HStack {
                            Text("No models loaded")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                Task {
                                    await aiService.fetchOpenRouterModels()
                                }
                            }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                    } else {
                        HStack {
                            Picker(
                                "Model",
                                selection: Binding(
                                    get: { aiService.currentModel },
                                    set: { aiService.selectModel($0) }
                                )
                            ) {
                                ForEach(aiService.availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }

                            Spacer()

                            Button(action: {
                                Task {
                                    await aiService.fetchOpenRouterModels()
                                }
                            }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                    }

                } else if !aiService.availableModels.isEmpty && aiService.selectedProvider != .ollama {
                    Picker(
                        "Model",
                        selection: Binding(
                            get: { aiService.currentModel },
                            set: { aiService.selectModel($0) }
                        )
                    ) {
                        ForEach(aiService.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                if aiService.selectedProvider == .ollama {
                    if isEditingURL {
                        HStack {
                            TextField("Base URL", text: $ollamaBaseURL)
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                aiService.updateOllamaBaseURL(ollamaBaseURL)
                                checkOllamaConnection()
                                isEditingURL = false
                            }
                        }
                    } else {
                        HStack {
                            Text(String(format: String(localized: "Server: %@"), ollamaBaseURL))
                            Spacer()
                            Button("Edit") { isEditingURL = true }
                            Button(action: {
                                ollamaBaseURL = "http://localhost:11434"
                                aiService.updateOllamaBaseURL(ollamaBaseURL)
                                checkOllamaConnection()
                            }) {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .help("Reset to default")
                        }
                    }

                    if !ollamaModels.isEmpty {
                        Divider()

                        Picker("Model", selection: $selectedOllamaModel) {
                            ForEach(ollamaModels) { model in
                                Text(model.name).tag(model.name)
                            }
                        }
                        .onChange(of: selectedOllamaModel) { oldValue, newValue in
                            aiService.updateSelectedOllamaModel(newValue)
                        }
                    }

                } else if aiService.selectedProvider == .localCLI {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Command")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Menu("Load Template") {
                                ForEach(LocalCLITemplate.allCases) { template in
                                    Button(template.displayName) {
                                        aiService.loadLocalCLITemplate(template)
                                        syncLocalCLIStateFromService()
                                    }
                                }
                            }
                        }

                        TextEditor(text: $localCLICommandTemplate)
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .frame(minHeight: 100)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(AppTheme.Border.subtle, lineWidth: 1)
                            )
                            .onChange(of: localCLICommandTemplate) { _, newValue in
                                guard !isSyncingLocalCLIState else { return }
                                if newValue != aiService.localCLICommandTemplate {
                                    aiService.updateLocalCLICommandTemplate(newValue)
                                }
                            }
                    }

                    Picker("Timeout", selection: $localCLITimeoutSeconds) {
                        Text("15s").tag(15.0)
                        Text("30s").tag(30.0)
                        Text("45s").tag(45.0)
                        Text("60s").tag(60.0)
                        Text("90s").tag(90.0)
                        Text("120s").tag(120.0)
                        Text("180s").tag(180.0)
                        Text("300s").tag(300.0)
                    }
                    .onChange(of: localCLITimeoutSeconds) { _, newValue in
                        aiService.updateLocalCLITimeoutSeconds(newValue)
                    }

                    Text(
                        "Environment variables available: VOICEINK_SYSTEM_PROMPT, VOICEINK_USER_PROMPT, VOICEINK_FULL_PROMPT. VoiceInk also writes VOICEINK_FULL_PROMPT to stdin for every command."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)

                    if !aiService.isAPIKeyValid {
                        Text("Load a template or enter a command to enable Local CLI enhancement.")
                            .font(.caption)
                            .foregroundColor(AppTheme.Status.warningStrong)
                    }
                } else if aiService.selectedProvider == .custom {
                    Text("Manage custom enhancement models in the Custom tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if aiService.selectedProvider == .openAI {
                    OpenAIAuthView(
                        aiService: aiService,
                        apiKey: $apiKey,
                        isVerifying: $isVerifying,
                        alertMessage: $alertMessage,
                        showAlert: $showAlert
                    )
                } else {
                    if aiService.isAPIKeyValid {
                        HStack {
                            Text("API Key")
                            Spacer()
                            Text("••••••••")
                                .foregroundColor(.secondary)
                            Button("Remove", role: .destructive) {
                                aiService.clearAPIKey()
                            }
                        }
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            if let url = getAPIKeyURL() {
                                Link(destination: url) {
                                    HStack {
                                        Image(systemName: "key.fill")
                                        Text("Get API Key")
                                    }
                                    .font(.caption)
                                    .foregroundColor(AppTheme.Status.infoStrong)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(AppTheme.Status.infoStrong.opacity(0.10))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer()

                            Button(action: {
                                isVerifying = true
                                aiService.saveAPIKey(apiKey) { success, errorMessage in
                                    isVerifying = false
                                    if !success {
                                        alertMessage =
                                            errorMessage
                                            ?? String(
                                                localized: "Could not verify this API key. Check the key and try again."
                                            )
                                        showAlert = true
                                    }
                                    apiKey = ""
                                }
                            }) {
                                HStack {
                                    if isVerifying {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text("Verify and Save")
                                }
                            }
                            .disabled(apiKey.isEmpty)
                        }
                    }
                }
            }
        }
        .alert("Error", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            if aiService.selectedProvider == .ollama {
                checkOllamaConnection(showError: false)
            }
            if aiService.selectedProvider == .localCLI {
                syncLocalCLIStateFromService()
            }
        }
    }

    private func providerTitle(_ provider: AIProvider) -> String {
        provider == .custom ? String(localized: "Custom Models") : provider.rawValue
    }

    private func syncSelectedProviderAvailability() {
        guard !providerOptions.contains(aiService.selectedProvider),
            let fallbackProvider = providerOptions.first
        else {
            return
        }

        aiService.selectedProvider = fallbackProvider
    }

    private func syncSelectedCustomModelIfNeeded() {
        guard aiService.selectedProvider == .custom else { return }

        let models = aiService.availableModels
        if models.contains(aiService.currentModel) {
            aiService.selectModel(aiService.currentModel)
        } else if let defaultModel = models.first {
            aiService.selectModel(defaultModel)
        }
    }

    private func syncLocalCLIStateFromService() {
        isSyncingLocalCLIState = true
        localCLICommandTemplate = aiService.localCLICommandTemplate
        localCLITimeoutSeconds = aiService.localCLITimeoutSeconds
        DispatchQueue.main.async {
            isSyncingLocalCLIState = false
        }
    }

    private func checkOllamaConnection(showError: Bool = true) {
        isCheckingOllama = true
        Task { @MainActor in
            let result = await aiService.refreshOllamaAvailability()

            ollamaModels = result.models
            isCheckingOllama = false

            if let errorMessage = result.errorMessage, showError {
                alertMessage = errorMessage
                showAlert = true
            }
        }
    }

    private func getAPIKeyURL() -> URL? {
        switch aiService.selectedProvider {
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://makersuite.google.com/app/apikey")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .elevenLabs: return URL(string: "https://elevenlabs.io/speech-synthesis")
        case .deepgram: return URL(string: "https://console.deepgram.com/api-keys")
        case .soniox: return URL(string: "https://console.soniox.com/")
        case .speechmatics: return URL(string: "https://portal.speechmatics.com/manage-access/")
        case .assemblyAI: return URL(string: "https://www.assemblyai.com/dashboard/api-keys")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .cerebras: return URL(string: "https://cloud.cerebras.ai/")
        default: return nil
        }
    }
}

// MARK: - OpenAI Auth View

struct OpenAIAuthView: View {
    @ObservedObject var aiService: AIService
    @Binding var apiKey: String
    @Binding var isVerifying: Bool
    @Binding var alertMessage: String
    @Binding var showAlert: Bool

    @State private var isAuthenticating = false
    @State private var showModelInfo = false
    @State private var selectedModelForInfo: CodexModelMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Auth Mode Picker
            Picker("Authentication", selection: $aiService.openAIAuthMode) {
                ForEach(OpenAIAuthMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            if aiService.openAIAuthMode == .oauth {
                // OAuth Mode UI
                oauthSection
            } else {
                // API Key Mode UI
                apiKeySection
            }
        }
    }

    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Info tip
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("Use your existing ChatGPT Plus or Pro subscription")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

            if aiService.isOAuthAuthenticated {
                // Authenticated state
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Signed in")
                            .font(.subheadline)

                        if let accountId = aiService.oauthAccountId {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(accountId)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("Sign Out", role: .destructive) {
                            do {
                                try aiService.signOutOAuth()
                            } catch {
                                alertMessage = "Failed to sign out: \(error.localizedDescription)"
                                showAlert = true
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    // Model picker with metadata
                    modelPicker
                }
            } else {
                // Not authenticated state
                Button(action: {
                    Task {
                        isAuthenticating = true
                        do {
                            try await aiService.initiateOAuthFlow()
                        } catch {
                            alertMessage = "OAuth failed: \(error.localizedDescription)"
                            showAlert = true
                        }
                        isAuthenticating = false
                    }
                }) {
                    HStack {
                        if isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Image(systemName: "person.circle.fill")
                        Text("Sign in with ChatGPT")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAuthenticating)
            }
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if aiService.isAPIKeyValid {
                HStack {
                    Text("API Key")
                    Spacer()
                    Text("••••••••")
                        .foregroundColor(.secondary)
                    Button("Remove", role: .destructive) {
                        aiService.clearAPIKey()
                    }
                }
            } else {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    // Get API Key Link
                    if let url = URL(string: "https://platform.openai.com/api-keys") {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "key.fill")
                                Text("Get API Key")
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button(action: {
                        isVerifying = true
                        aiService.saveAPIKey(apiKey) { success, errorMessage in
                            isVerifying = false
                            if !success {
                                alertMessage = errorMessage ?? "Verification failed"
                                showAlert = true
                            }
                            apiKey = ""
                        }
                    }) {
                        HStack {
                            if isVerifying {
                                ProgressView().controlSize(.small)
                            }
                            Text("Verify and Save")
                        }
                    }
                    .disabled(apiKey.isEmpty)
                }
            }
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }

            ForEach(CodexModels.sortedForPicker, id: \.id) { model in
                modelRow(for: model)
            }
        }
    }

    private func modelRow(for model: CodexModelMetadata) -> some View {
        Button(action: {
            aiService.openAIOAuthModel = model.id
        }) {
            HStack(spacing: 8) {
                // Selection indicator
                Image(systemName: aiService.openAIOAuthModel == model.id ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(aiService.openAIOAuthModel == model.id ? .blue : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(.body, design: .monospaced))

                        if model.isRecommended {
                            Text("⭐️")
                                .font(.caption)
                        }

                        // Tier badge
                        Text(model.tier.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tierColor(model.tier).opacity(0.2))
                            .foregroundColor(tierColor(model.tier))
                            .cornerRadius(4)

                        // Status badge
                        if model.status != .current {
                            Text(model.status.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(statusColor(model.status).opacity(0.2))
                                .foregroundColor(statusColor(model.status))
                                .cornerRadius(4)
                        }
                    }

                    Text(model.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // Info button
                Button(action: {
                    selectedModelForInfo = model
                    showModelInfo = true
                }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(aiService.openAIOAuthModel == model.id ? Color.blue.opacity(0.05) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showModelInfo) {
            if let model = selectedModelForInfo {
                ModelInfoSheet(model: model, isPresented: $showModelInfo)
            }
        }
    }

    private func tierColor(_ tier: SubscriptionTier) -> Color {
        switch tier {
        case .plus: return .blue
        case .pro: return .purple
        case .api: return .gray
        }
    }

    private func statusColor(_ status: ModelStatus) -> Color {
        switch status {
        case .current: return .green
        case .preview: return .orange
        case .legacy: return .gray
        case .deprecated: return .red
        }
    }
}

// MARK: - Model Info Sheet

struct ModelInfoSheet: View {
    let model: CodexModelMetadata
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text(model.displayName)
                    .font(.title2)
                    .bold()
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Badges
            HStack(spacing: 8) {
                tierBadge
                statusBadge
                if model.isRecommended {
                    Text("⭐️ Recommended")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.yellow.opacity(0.2))
                        .foregroundColor(.primary)
                        .cornerRadius(6)
                }
                Spacer()
            }

            // Description
            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.headline)
                Text(model.description)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Details
            VStack(alignment: .leading, spacing: 8) {
                Text("Details")
                    .font(.headline)

                HStack {
                    Text("Release Date:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(model.releaseDate)
                }

                HStack {
                    Text("Subscription Tier:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(model.tier.rawValue)
                }

                HStack {
                    Text("Status:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(model.status.rawValue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // Learn More button
            if let url = URL(string: model.documentationURL) {
                Link(destination: url) {
                    HStack {
                        Image(systemName: "arrow.up.forward.circle.fill")
                        Text("Learn More")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400, height: 500)
    }

    private var tierBadge: some View {
        Text(model.tier.rawValue)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tierColor.opacity(0.2))
            .foregroundColor(tierColor)
            .cornerRadius(6)
    }

    private var statusBadge: some View {
        Text(model.status.rawValue)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.2))
            .foregroundColor(statusColor)
            .cornerRadius(6)
    }

    private var tierColor: Color {
        switch model.tier {
        case .plus: return .blue
        case .pro: return .purple
        case .api: return .gray
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .current: return .green
        case .preview: return .orange
        case .legacy: return .gray
        case .deprecated: return .red
        }
    }
}
