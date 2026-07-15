import AppKit
import SwiftUI

struct ProviderDetailPanel: View {
    let descriptor: ProviderDescriptor
    let onClose: () -> Void

    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager

    @State private var apiKey = ""
    @State private var isVerifying = false
    @State private var isRefreshingOpenRouterModels = false
    @State private var verificationMessage: String?
    @State private var verificationDetailMessage: String?
    @State private var verificationSucceeded = false
    @State private var isShowingRemoveAPIKeyConfirmation = false
    @State private var isShowingOAuthSignOutConfirmation = false
    @State private var oauthErrorMessage: String?
    @State private var activeDescriptorID = ""

    private var hasAPIKey: Bool {
        APIKeyManager.shared.hasAPIKey(forProvider: descriptor.providerKey)
    }

    private var isOpenAI: Bool {
        descriptor.aiProvider == .openAI
    }

    private var iconName: String {
        if descriptor.hasTranscription && descriptor.hasEnhancement { return "rectangle.2.swap" }
        if descriptor.hasTranscription { return "captions.bubble.fill" }
        return "sparkles"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionSection

                    if descriptor.hasTranscription {
                        transcriptionModelsSection
                    }

                    if descriptor.hasEnhancement {
                        enhancementModelsSection
                    }
                }
                .padding(20)
            }
        }
        .onAppear {
            loadSavedAPIKey()
            if isOpenAI {
                aiService.refreshOpenAIAuthenticationStatus()
                refreshChatGPTSessionIfNeeded()
            }
        }
        .onChange(of: descriptor.id) { _, _ in
            resetProviderState()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ProviderBrandIcon(
                descriptor: descriptor,
                fallbackSystemImage: iconName,
                isSelected: false,
                size: 38,
                iconSize: 18
            )

            Text(descriptor.displayName)
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(AppTheme.Surface.card)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var connectionSection: some View {
        if isOpenAI {
            openAIConnectionSection
        } else {
            apiKeySection
        }
    }

    private var apiKeySection: some View {
        ProviderConfigurationGroup(title: "Connection") {
            VStack(alignment: .leading, spacing: 8) {
                if hasAPIKey {
                    verifiedAPIKeyRow
                } else {
                    apiKeyInputRow
                }

                verificationStatusMessage
            }
        }
    }

    private var openAIConnectionSection: some View {
        ProviderConfigurationGroup(title: "Connections") {
            VStack(alignment: .leading, spacing: 10) {
                oauthConnectionCard

                if hasAPIKey {
                    verifiedAPIKeyRow
                } else {
                    apiKeyInputRow
                }

                verificationStatusMessage
            }
        }
    }

    private var oauthConnectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                providerDetailIcon("person.crop.circle.badge.checkmark")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("ChatGPT Subscription (OAuth)")
                            .font(.system(size: 13, weight: .semibold))

                        Text("BETA")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppTheme.Status.warningStrong)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AppTheme.Status.warningStrong.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text("Codex-backed enhancement using your ChatGPT account. Model access depends on your account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            if aiService.hasOAuthSession {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Status.positive)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(aiService.isOAuthAuthenticated ? "Connected" : "Connected — refresh pending")
                            .font(.system(size: 12, weight: .medium))

                        if let accountID = aiService.oauthAccountId, !accountID.isEmpty {
                            Text(accountID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .privacySensitive()
                        }
                    }

                    Spacer()

                    if !aiService.isOAuthAuthenticated {
                        Button("Reconnect") {
                            signInWithChatGPT()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(aiService.isOAuthAuthenticating)
                    }

                    Button("Sign Out", role: .destructive) {
                        isShowingOAuthSignOutConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button {
                    signInWithChatGPT()
                } label: {
                    HStack(spacing: 7) {
                        if aiService.isOAuthAuthenticating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                        Text(aiService.oauthDisconnectionReason == nil ? "Sign in with ChatGPT" : "Reconnect ChatGPT")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(aiService.isOAuthAuthenticating)
            }

            if let reason = aiService.oauthDisconnectionReason ?? oauthErrorMessage {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(ProviderSurface(cornerRadius: 8))
        .alert("Sign Out of ChatGPT?", isPresented: $isShowingOAuthSignOutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                do {
                    try aiService.signOutOAuth()
                } catch {
                    oauthErrorMessage = String(localized: "Could not remove the ChatGPT connection.")
                }
            }
        } message: {
            Text("Modes using this connection will keep their selection but enhancement will remain unavailable until you reconnect.")
        }
    }

    @ViewBuilder
    private var verificationStatusMessage: some View {
        if let verificationMessage {
            VStack(alignment: .leading, spacing: 3) {
                Text(verificationMessage)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(verificationSucceeded ? AppTheme.Status.positive : AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)

                if let verificationDetailMessage, !verificationSucceeded {
                    Text(verificationDetailMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Status.error.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var verifiedAPIKeyRow: some View {
        HStack(spacing: 12) {
            providerDetailIcon("checkmark.seal.fill")

            VStack(alignment: .leading, spacing: 3) {
                Text("Key verified")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                if let obfuscatedKey {
                    Text(obfuscatedKey)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                isShowingRemoveAPIKeyConfirmation = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("Remove API key")
        }
        .padding(12)
        .background(ProviderSurface(cornerRadius: 8))
        .alert("Remove API Key?", isPresented: $isShowingRemoveAPIKeyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                removeAPIKey()
            }
        } message: {
            Text(
                String(
                    format: String(localized: "This will remove your %@ API key. You can add it again later."),
                    descriptor.displayName))
        }
    }

    private var apiKeyInputRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                providerDetailIcon("key.fill")

                VStack(alignment: .leading, spacing: 3) {
                    Text("API Key")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }

            HStack(spacing: 8) {
                SecureField("Paste API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(isVerifying)
                    .onChange(of: apiKey) { _, newValue in
                        guard !newValue.isEmpty else { return }
                        verificationMessage = nil
                        verificationDetailMessage = nil
                    }

                Button {
                    verifyAndSaveAPIKey()
                } label: {
                    HStack(spacing: 5) {
                        if isVerifying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.seal")
                        }
                        Text(isVerifying ? LocalizedStringKey("Verifying") : LocalizedStringKey("Verify"))
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying)
                .opacity(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying ? 0.55 : 1)
            }

            if let consoleURL = descriptor.apiConsoleURL {
                Link(destination: consoleURL) {
                    HStack(spacing: 7) {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .semibold))

                        Text(String(format: String(localized: "Get %@ API Key"), descriptor.displayName))
                            .font(.system(size: 12, weight: .medium))

                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(neutralLinkButtonBackground)
                }
                .buttonStyle(.plain)
                .help(String(format: String(localized: "Open %@ API key page"), descriptor.displayName))
            }
        }
        .padding(12)
        .background(ProviderSurface(cornerRadius: 8))
    }

    private func providerDetailIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppTheme.Surface.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
                    )
            )
    }

    private var neutralLinkButtonBackground: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(AppTheme.Surface.control)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
            )
    }

    private var transcriptionModelsSection: some View {
        let models = descriptor.transcriptionModels

        return ProviderModelListSection(title: "Available Transcription Models") {
            ForEach(Array(models.prefix(8).enumerated()), id: \.element.id) { index, model in
                modelRow(
                    title: model.displayName,
                    subtitle: nil,
                    trailing: nil,
                    systemImage: "captions.bubble.fill"
                )

                if index < min(models.count, 8) - 1 {
                    Divider()
                }
            }

            if models.count > 8 {
                Divider()
                Text("More transcription models available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var enhancementModelsSection: some View {
        if let provider = descriptor.aiProvider {
            if provider == .openAI {
                openAIEnhancementModelsSection
            } else {
                let models = aiService.availableModels(for: provider)

                ProviderModelListSection(title: "Available Enhancement Models") {
                    if provider == .openRouter {
                        HStack(spacing: 12) {
                            Text(openRouterModelAvailabilityText(for: models.count))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(models.isEmpty ? .secondary : .primary)

                            Spacer()

                            Button {
                                refreshOpenRouterModels()
                            } label: {
                                HStack(spacing: 5) {
                                    if isRefreshingOpenRouterModels {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    Text(
                                        isRefreshingOpenRouterModels
                                            ? LocalizedStringKey("Refreshing") : LocalizedStringKey("Refresh"))
                                }
                                .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isRefreshingOpenRouterModels)
                            .opacity(isRefreshingOpenRouterModels ? 0.55 : 1)
                        }
                        .padding(.vertical, 8)
                    } else if models.isEmpty {
                        Text("No models listed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        modelRows(models)

                        if models.count > 8 {
                            Divider()
                            Text("More enhancement models available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }

    private var openAIEnhancementModelsSection: some View {
        let oauthModels = aiService.models(for: .openAI, authMode: .oauth)
        let apiModels = aiService.models(for: .openAI, authMode: .apiKey)

        return VStack(alignment: .leading, spacing: 14) {
            ProviderModelListSection(title: "ChatGPT OAuth Models — Beta (\(oauthModels.count))") {
                Text("Candidate models for Codex-backed enhancement. Availability depends on your ChatGPT account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)

                Divider()
                modelRows(oauthModels, showsOAuthMetadata: true)

                if oauthModels.count > 8 {
                    Divider()
                    Text("More OAuth models available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }

            ProviderModelListSection(title: "OpenAI API Models (\(apiModels.count))") {
                modelRows(apiModels)
            }
        }
    }

    @ViewBuilder
    private func modelRows(_ models: [String], showsOAuthMetadata: Bool = false) -> some View {
        if models.isEmpty {
            Text("No models listed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ForEach(Array(models.prefix(8).enumerated()), id: \.offset) { index, model in
                let metadata = showsOAuthMetadata ? CodexModels.metadata(for: model) : nil
                modelRow(
                    title: metadata?.displayName ?? model,
                    subtitle: metadata?.id,
                    trailing: metadata?.isRecommended == true ? "Recommended" : metadata?.status.rawValue,
                    systemImage: "sparkles"
                )

                if index < min(models.count, 8) - 1 {
                    Divider()
                }
            }
        }
    }

    private func openRouterModelAvailabilityText(for count: Int) -> String {
        if count == 0 {
            return String(localized: "No models loaded.")
        }

        return String(localized: "\(count) models available")
    }

    private func modelRow(title: String, subtitle: String?, trailing: String?, systemImage: String) -> some View {
        HStack(spacing: 10) {
            modelTypeIcon(systemImage)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func modelTypeIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.Surface.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
                    )
            )
    }

    private var obfuscatedKey: String? {
        guard let savedKey = APIKeyManager.shared.getAPIKey(forProvider: descriptor.providerKey) else {
            return nil
        }

        let trimmedKey = savedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        if trimmedKey.count <= 8 {
            return String(repeating: "\u{2022}", count: trimmedKey.count)
        }

        return
            "\(trimmedKey.prefix(4))\(String(repeating: "\u{2022}", count: max(4, trimmedKey.count - 8)))\(trimmedKey.suffix(4))"
    }

    private func loadSavedAPIKey() {
        resetProviderState()
    }

    private func resetProviderState() {
        activeDescriptorID = descriptor.id
        verificationSucceeded = hasAPIKey
        apiKey = ""
        isVerifying = false
        isRefreshingOpenRouterModels = false
        verificationMessage = nil
        verificationDetailMessage = nil
        isShowingRemoveAPIKeyConfirmation = false
        isShowingOAuthSignOutConfirmation = false
        oauthErrorMessage = nil
    }

    private func verificationModel(for provider: AIProvider) -> String {
        let authMode: OpenAIAuthMode? = provider == .openAI ? .apiKey : nil
        let selectedModel = aiService.selectedModel(for: provider, authMode: authMode)
        let models = aiService.models(for: provider, authMode: authMode)

        if models.contains(selectedModel) {
            return selectedModel
        }

        return models.first ?? selectedModel
    }

    private func verifyAndSaveAPIKey() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        isVerifying = true
        verificationMessage = nil
        verificationDetailMessage = nil
        let providerID = descriptor.id

        Task {
            let result: (isValid: Bool, errorMessage: String?)
            if let cloudProvider = descriptor.cloudProvider {
                result = await cloudProvider.verifyAPIKey(trimmedKey)
            } else if let provider = descriptor.aiProvider {
                result = await aiService.verifyAPIKey(
                    trimmedKey,
                    for: provider,
                    model: verificationModel(for: provider)
                )
            } else {
                result = (false, String(localized: "Provider is not supported"))
            }

            await MainActor.run {
                guard activeDescriptorID == providerID else { return }

                isVerifying = false
                verificationSucceeded = result.isValid

                if result.isValid {
                    APIKeyManager.shared.saveAPIKey(trimmedKey, forProvider: descriptor.providerKey)
                    if let provider = descriptor.aiProvider, aiService.selectedProvider == provider {
                        aiService.apiKey = trimmedKey
                        aiService.isAPIKeyValid = true
                    }
                    apiKey = ""
                    verificationMessage = nil
                    verificationDetailMessage = nil
                    transcriptionModelManager.refreshAllAvailableModels()
                    NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
                } else {
                    verificationMessage = String(
                        localized: "Could not verify this API key. Check the key and try again.")
                    verificationDetailMessage = result.errorMessage
                }
            }
        }
    }

    private func removeAPIKey() {
        APIKeyManager.shared.deleteAPIKey(forProvider: descriptor.providerKey)
        apiKey = ""
        verificationSucceeded = false
        verificationMessage = nil
        verificationDetailMessage = nil
        transcriptionModelManager.refreshAllAvailableModels()
        NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
    }

    private func refreshOpenRouterModels() {
        guard !isRefreshingOpenRouterModels else { return }
        isRefreshingOpenRouterModels = true

        Task {
            await aiService.fetchOpenRouterModels()
            await MainActor.run {
                isRefreshingOpenRouterModels = false
            }
        }
    }

    private func signInWithChatGPT() {
        oauthErrorMessage = nil
        Task {
            do {
                try await aiService.initiateOAuthFlow()
            } catch {
                oauthErrorMessage = error.localizedDescription
            }
        }
    }

    private func refreshChatGPTSessionIfNeeded() {
        guard aiService.hasOAuthSession else { return }

        Task {
            do {
                try await aiService.refreshOAuthTokenIfNeeded(authMode: .oauth)
            } catch {
                // The service owns session invalidation. Transient refresh failures are
                // intentionally left retryable without exposing backend error details.
            }
            await MainActor.run {
                aiService.refreshOpenAIAuthenticationStatus()
            }
        }
    }

}
