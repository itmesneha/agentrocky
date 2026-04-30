//
//  ClaudeSession.swift
//  agentrocky
//

import Foundation
import Combine
import Darwin

enum AgentProvider: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"

    private static let defaultProviderKey = "rocky.defaultAgentProvider"

    var id: String { rawValue }

    static var savedDefault: AgentProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultProviderKey),
                  let provider = AgentProvider(rawValue: raw) else {
                return .claude
            }
            return provider
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultProviderKey)
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: return "sonnet"
        case .codex: return "gpt-5.5"
        }
    }

    var modelSuggestions: [String] {
        switch self {
        case .claude:
            return ["sonnet", "opus", "claude-sonnet-4-6"]
        case .codex:
            return ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.3-codex-spark"]
        }
    }

    var thinkingOptions: [AgentThinking] {
        switch self {
        case .claude: return [.low, .medium, .high, .xhigh, .max]
        case .codex: return [.low, .medium, .high, .xhigh]
        }
    }
}

enum AgentThinking: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }
}

class AgentSession: ObservableObject {
    @Published var lines: [OutputLine] = []
    @Published var isReady: Bool = false
    @Published var isRunning: Bool = false
    @Published var provider: AgentProvider
    @Published var model: String
    @Published var thinking: AgentThinking = .high

    let workingDirectory: String

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readBuffer = Data()
    private var conversationHistory: [ConversationTurn] = []
    private let queue = DispatchQueue(label: "rocky.session", qos: .userInitiated)

    struct OutputLine: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case text, tool, system, error }
    }

    private struct ConversationTurn {
        let role: String
        let text: String
    }

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        let defaultProvider = AgentProvider.savedDefault
        self.provider = defaultProvider
        self.model = defaultProvider.defaultModel
        start()
    }

    deinit {
        stopActiveProcess()
    }

    // MARK: - Public

    func send(prompt: String) {
        guard !isRunning else { return }
        remember(role: "user", text: prompt)

        switch provider {
        case .claude:
            sendClaude(prompt: prompt)
        case .codex:
            runCodex(prompt: prompt)
        }
    }

    func newSession() {
        stopActiveProcess()
        readBuffer.removeAll()
        conversationHistory.removeAll()
        isRunning = false
        isReady = false
        lines.removeAll()
        start()
    }

    func applySettings(provider newProvider: AgentProvider, model newModel: String, thinking newThinking: AgentThinking) {
        guard !isRunning else {
            append("Wait for the current task to finish before changing agent settings.", kind: .system)
            return
        }

        let normalizedModel = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        provider = newProvider
        model = normalizedModel.isEmpty ? newProvider.defaultModel : normalizedModel
        thinking = newProvider.thinkingOptions.contains(newThinking) ? newThinking : .high
        newSession()
    }

    // MARK: - Lifecycle

    private func start() {
        switch provider {
        case .claude:
            startClaude()
        case .codex:
            isReady = findCodex() != nil
            if isReady {
                append("Codex ready. Rocky keeps conversation history.", kind: .system)
            } else {
                append("codex binary not found - checked:\n" + codexSearchPaths().joined(separator: "\n"), kind: .error)
            }
        }
    }

    // MARK: - Claude

    private func sendClaude(prompt: String) {
        guard isReady else {
            append("Claude is still starting. Try again in a moment.", kind: .system)
            return
        }

        isRunning = true
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": prompt]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            isRunning = false
            return
        }

        queue.async { [weak self] in
            self?.stdinHandle?.write(Data((json + "\n").utf8))
        }
    }

    private func startClaude() {
        guard let claudePath = findClaude() else {
            append("claude binary not found - checked:\n" + claudeSearchPaths().joined(separator: "\n"), kind: .error)
            return
        }

        let proc = Process()
        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = claudeArguments()
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        proc.environment = env

        proc.standardInput  = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        stdinHandle = stdinPipe.fileHandleForWriting

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.receiveClaude(data) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self?.append(trimmed, kind: .error)
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.stdinHandle = nil
                self.isReady = false
                self.isRunning = false
                self.append("Claude exited (code \(p.terminationStatus))", kind: .system)
            }
        }

        do {
            try proc.run()
            process = proc
            append("Claude starting with model \(model), thinking \(thinking.rawValue)...", kind: .system)

            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.provider == .claude, !self.isReady else { return }
                self.isReady = true
            }
        } catch {
            append("Failed to launch claude: \(error.localizedDescription)", kind: .error)
        }
    }

    private func claudeArguments() -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions"
        ]

        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--model", model]
        }

        args += ["--effort", thinking.rawValue]
        return args
    }

    private func receiveClaude(_ data: Data) {
        readBuffer.append(data)
        while let idx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<idx]
            readBuffer.removeSubrange(readBuffer.startIndex...idx)
            guard let str = String(data: lineData, encoding: .utf8),
                  !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            parseClaude(str)
        }
    }

    private func parseClaude(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            append("[raw] \(raw)", kind: .system)
            return
        }

        let type = json["type"] as? String ?? ""
        let subtype = json["subtype"] as? String ?? ""

        DispatchQueue.main.async { [weak self] in
            switch type {
            case "system" where subtype == "init":
                self?.isReady = true

            case "assistant":
                guard let message = json["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { return }
                for block in content { self?.renderClaudeBlock(block) }

            case "result":
                self?.isRunning = false
                self?.append("", kind: .text)

            default:
                break
            }
        }
    }

    private func renderClaudeBlock(_ block: [String: Any]) {
        switch block["type"] as? String ?? "" {
        case "text":
            if let text = block["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                remember(role: "assistant", text: text)
                append("\(provider.rawValue.lowercased()): \(text)", kind: .text)
            }

        case "tool_use":
            let name = block["name"] as? String ?? "tool"
            let input = block["input"] as? [String: Any] ?? [:]
            let detail: String
            if let cmd = input["command"] as? String { detail = cmd }
            else if let path = input["path"] as? String { detail = path }
            else if let desc = input["description"] as? String { detail = desc }
            else { detail = input.keys.joined(separator: ", ") }
            append("[\(name)] \(detail)", kind: .tool)

        default:
            break
        }
    }

    // MARK: - Codex

    private func runCodex(prompt: String) {
        guard let codexPath = findCodex() else {
            append("codex binary not found - checked:\n" + codexSearchPaths().joined(separator: "\n"), kind: .error)
            return
        }

        isRunning = true

        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: codexPath)
        proc.arguments = codexArguments()
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        proc.environment = ProcessInfo.processInfo.environment
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.receiveCodex(data) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !trimmed.contains("failed to record rollout items") else { return }
            guard !trimmed.contains("Reading additional input from stdin") else { return }
            self?.append(trimmed, kind: .error)
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.isRunning = false
                self.isReady = true
                if p.terminationStatus == 0 {
                    self.append("Codex done", kind: .system)
                } else {
                    self.append("Codex stopped (code \(p.terminationStatus))", kind: .error)
                }
            }
        }

        do {
            process = proc
            readBuffer.removeAll()
            append("Codex running with model \(model), thinking \(thinking.rawValue)...", kind: .system)
            try proc.run()
            stdinPipe.fileHandleForWriting.write(Data(codexPrompt(for: prompt).utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        } catch {
            process = nil
            isRunning = false
            append("Failed to launch codex: \(error.localizedDescription)", kind: .error)
        }
    }

    private func codexArguments() -> [String] {
        var args = [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "-C", workingDirectory,
            "--dangerously-bypass-approvals-and-sandbox"
        ]

        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-m", model]
        }

        args += ["-c", "model_reasoning_effort=\"\(thinking.rawValue)\""]
        args.append("-")
        return args
    }

    private func receiveCodex(_ data: Data) {
        readBuffer.append(data)
        while let idx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<idx]
            readBuffer.removeSubrange(readBuffer.startIndex...idx)
            guard let str = String(data: lineData, encoding: .utf8),
                  !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            parseCodex(str)
        }
    }

    private func parseCodex(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            append("[codex] \(raw)", kind: .system)
            return
        }

        let type = (json["type"] as? String ?? json["event"] as? String ?? "").lowercased()
        let text = extractText(from: json)
        let item = json["item"] as? [String: Any]
        let itemType = (item?["type"] as? String ?? "").lowercased()

        if itemType.contains("agent_message") {
            if !text.isEmpty {
                remember(role: "assistant", text: text)
                append("codex: \(text)", kind: .text)
            }
        } else if type.contains("error") {
            append(text.isEmpty ? "[codex error] \(json)" : text, kind: .error)
        } else if type.contains("message") || type.contains("response") || type.contains("final") || type.contains("answer") {
            if !text.isEmpty {
                remember(role: "assistant", text: text)
                append("codex: \(text)", kind: .text)
            }
        }
    }

    private func codexPrompt(for currentPrompt: String) -> String {
        let priorTurns = conversationHistory.dropLast().suffix(12)
        let history = priorTurns.map { turn in
            "\(turn.role): \(turn.text)"
        }.joined(separator: "\n\n")

        if history.isEmpty {
            return currentPrompt
        }

        return """
        Continue this conversation. Use the prior turns for context and answer the latest user message.

        Prior conversation:
        \(history)

        Latest user message:
        \(currentPrompt)
        """
    }

    private func extractText(from value: Any) -> String {
        if let string = value as? String {
            return string
        }

        if let dict = value as? [String: Any] {
            for key in ["message", "text", "content", "summary", "command", "cmd", "path", "output"] {
                if let text = dict[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }

            for key in ["item", "delta", "result", "data", "payload"] {
                if let nested = dict[key] {
                    let text = extractText(from: nested)
                    if !text.isEmpty { return text }
                }
            }
        }

        if let array = value as? [Any] {
            return array.map { extractText(from: $0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }

        return ""
    }

    // MARK: - Helpers

    private func append(_ text: String, kind: OutputLine.Kind) {
        DispatchQueue.main.async { [weak self] in
            self?.lines.append(OutputLine(text: text, kind: kind))
        }
    }

    private func remember(role: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversationHistory.append(ConversationTurn(role: role, text: trimmed))
        if conversationHistory.count > 40 {
            conversationHistory.removeFirst(conversationHistory.count - 40)
        }
    }

    private func stopActiveProcess() {
        let proc = process
        process = nil
        stdinHandle = nil
        if proc?.isRunning == true {
            proc?.terminate()
        }
    }

    private func findClaude() -> String? {
        claudeSearchPaths().first { FileManager.default.fileExists(atPath: $0) }
    }

    private func findCodex() -> String? {
        codexSearchPaths().first { FileManager.default.fileExists(atPath: $0) }
    }

    private func claudeSearchPaths() -> [String] {
        let home = realHome
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
    }

    private func codexSearchPaths() -> [String] {
        let home = realHome
        return [
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]
    }

    private var realHome: String {
        getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) }
            ?? NSHomeDirectory()
    }
}

typealias ClaudeSession = AgentSession
