//
//  ChatView.swift
//  agentrocky
//

import SwiftUI

struct ChatView: View {
    @ObservedObject var session: AgentSession
    @State private var input: String = ""
    @State private var selectedProvider: AgentProvider = .claude
    @State private var selectedModel: String = AgentProvider.claude.defaultModel
    @State private var selectedThinking: AgentThinking = .high
    @State private var selectedDefaultProvider: AgentProvider = AgentProvider.savedDefault
    @State private var isSyncingSettings = false
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    private var promptLabel: String {
        URL(fileURLWithPath: session.workingDirectory).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsBar
            Divider().background(Color.green.opacity(0.3))

            // Terminal output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(session.lines) { line in
                            TerminalLine(line: line)
                        }
                        if session.isRunning {
                            Text("▋")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.green)
                                .opacity(0.8)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(10)
                }
                .onChange(of: session.lines.count) { _ in proxy.scrollTo("bottom") }
                .onChange(of: session.isRunning)   { _ in proxy.scrollTo("bottom") }
            }

            Divider().background(Color.green.opacity(0.3))

            // Input row
            HStack(spacing: 6) {
                Text(promptLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.head)

                Text("❯")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(session.isReady ? .green : .green.opacity(0.3))

                TextField("", text: $input)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.green)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.5))
        }
        .background(Color(red: 0.04, green: 0.04, blue: 0.04))
        .onAppear {
            syncSettingsFromSession()
            inputFocused = true
        }
    }

    private var settingsBar: some View {
        HStack(spacing: 8) {
            Button {
                syncSettingsFromSession()
                showSettings.toggle()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .frame(width: 112)
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                settingsPanel
            }
            .disabled(session.isRunning)

            Button {
                session.newSession()
                syncSettingsFromSession()
            } label: {
                Label("New", systemImage: "plus")
            }
            .frame(width: 84)
            .disabled(session.isRunning)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.58))
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent Settings")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 6) {
                Text("Default Agent")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green.opacity(0.58))

                Picker("", selection: $selectedDefaultProvider) {
                    ForEach(AgentProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
                .onChange(of: selectedDefaultProvider) { provider in
                    AgentProvider.savedDefault = provider
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Agent")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green.opacity(0.58))

                Picker("", selection: $selectedProvider) {
                    ForEach(AgentProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
                .onChange(of: selectedProvider) { provider in
                    isSyncingSettings = true
                    let nextThinking = provider.thinkingOptions.contains(selectedThinking) ? selectedThinking : .high
                    if !provider.thinkingOptions.contains(selectedThinking) {
                        selectedThinking = nextThinking
                    }
                    selectedModel = provider.defaultModel
                    isSyncingSettings = false
                    applySettingsIfChanged(provider: provider, model: provider.defaultModel, thinking: nextThinking)
                }
                .disabled(session.isRunning)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Thinking")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green.opacity(0.58))

                Picker("", selection: $selectedThinking) {
                    ForEach(selectedProvider.thinkingOptions) { thinking in
                        Text(thinking.rawValue).tag(thinking)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
                .onChange(of: selectedThinking) { thinking in
                    applySettingsIfChanged(provider: selectedProvider, model: selectedModel, thinking: thinking)
                }
                .disabled(session.isRunning)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green.opacity(0.58))

                Menu {
                    ForEach(selectedProvider.modelSuggestions, id: \.self) { model in
                        Button(model) {
                            selectedModel = model
                            applySettingsIfChanged(provider: selectedProvider, model: model, thinking: selectedThinking)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedModel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.78))
                    }
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.horizontal, 12)
                    .frame(width: 220, height: 38)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning)
            }

            Text("Changes apply immediately.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.green.opacity(0.46))
        }
        .padding(14)
        .frame(width: 260)
        .background(Color(red: 0.04, green: 0.04, blue: 0.04))
    }

    private func syncSettingsFromSession() {
        isSyncingSettings = true
        selectedProvider = session.provider
        selectedModel = session.model
        selectedThinking = session.thinking
        selectedDefaultProvider = AgentProvider.savedDefault
        isSyncingSettings = false
    }

    private func applySettings() {
        guard !isSyncingSettings else { return }
        session.applySettings(
            provider: selectedProvider,
            model: selectedModel,
            thinking: selectedThinking
        )
        syncSettingsFromSession()
        inputFocused = true
    }

    private func applySettingsIfChanged(provider: AgentProvider, model: String, thinking: AgentThinking) {
        guard !isSyncingSettings else { return }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = normalizedModel.isEmpty ? provider.defaultModel : normalizedModel
        let resolvedThinking = provider.thinkingOptions.contains(thinking) ? thinking : .high
        guard session.provider != provider ||
              session.model != resolvedModel ||
              session.thinking != resolvedThinking
        else { return }

        session.applySettings(provider: provider, model: resolvedModel, thinking: resolvedThinking)
        syncSettingsFromSession()
        inputFocused = true
    }

    private func sendMessage() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !session.isRunning else { return }
        session.lines.append(.init(text: "\(promptLabel) ❯ \(trimmed)", kind: .system))
        input = ""
        session.send(prompt: trimmed)
        inputFocused = true
    }
}

struct TerminalLine: View {
    let line: AgentSession.OutputLine

    var body: some View {
        Text(line.text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var color: Color {
        switch line.kind {
        case .text:   return .green
        case .tool:   return Color(red: 0.4, green: 0.8, blue: 1.0)   // cyan for tool calls
        case .system: return .green.opacity(0.5)
        case .error:  return Color(red: 1.0, green: 0.4, blue: 0.4)   // red for errors
        }
    }
}
