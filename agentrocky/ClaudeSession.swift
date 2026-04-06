//
//  ClaudeSession.swift
//  agentrocky
//

import Foundation
import Combine
import Darwin

class ClaudeSession: ObservableObject {
    @Published var lines: [OutputLine] = []
    @Published var isReady: Bool = false
    @Published var isRunning: Bool = false

    let workingDirectory: String

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readBuffer = Data()
    private let queue = DispatchQueue(label: "rocky.session", qos: .userInitiated)

    struct OutputLine: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case text, tool, system, error }
    }

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        start()
    }

    deinit {
        process?.terminate()
    }

    // MARK: - Public

    func send(prompt: String) {
        guard !isRunning else { return }
        isRunning = true

        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": prompt]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        queue.async { [weak self] in
            self?.stdinHandle?.write(Data((json + "\n").utf8))
        }
    }

    // MARK: - Process lifecycle

    private func start() {
        guard let claudePath = findClaude() else {
            append("claude binary not found — checked:\n" + searchPaths().joined(separator: "\n"), kind: .error)
            return
        }

        let proc = Process()
        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = [
            "-p",
            "--output-format", "stream-json",
            "--input-format",  "stream-json",
            "--verbose",
            "--dangerously-skip-permissions"
        ]
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        proc.environment = env

        proc.standardInput  = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        stdinHandle = stdinPipe.fileHandleForWriting

        // Read stdout on dedicated queue
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.receive(data) }
        }

        // Show stderr in terminal (helps diagnose auth issues, etc.)
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async { self?.append(trimmed, kind: .error) }
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.isReady   = false
                self?.isRunning = false
                self?.append("Process exited (code \(p.terminationStatus))", kind: .system)
            }
        }

        do {
            try proc.run()
            self.process = proc
            append("Starting claude…", kind: .system)

            // Fallback: if init event never arrives, mark ready after 4s
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, !self.isReady else { return }
                self.isReady = true
                self.append("Ready (fallback)", kind: .system)
            }
        } catch {
            append("Failed to launch claude: \(error.localizedDescription)", kind: .error)
        }
    }

    // MARK: - Output parsing

    private func receive(_ data: Data) {
        readBuffer.append(data)
        while let idx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<idx]
            readBuffer.removeSubrange(readBuffer.startIndex...idx)
            guard let str = String(data: lineData, encoding: .utf8),
                  !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            parse(str)
        }
    }

    private func parse(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Show unparseable lines so we can debug
            DispatchQueue.main.async { [weak self] in
                self?.append("[raw] \(raw)", kind: .system)
            }
            return
        }

        let type    = json["type"]    as? String ?? ""
        let subtype = json["subtype"] as? String ?? ""

        DispatchQueue.main.async { [weak self] in
            switch type {

            case "system" where subtype == "init":
                self?.isReady = true
                self?.append("Session ready", kind: .system)

            case "assistant":
                guard let message = json["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { return }
                for block in content { self?.renderBlock(block) }

            case "result":
                self?.isRunning = false
                self?.append("", kind: .text)

            default: break
            }
        }
    }

    private func renderBlock(_ block: [String: Any]) {
        switch block["type"] as? String ?? "" {

        case "text":
            if let text = block["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append(text, kind: .text)
            }

        case "tool_use":
            let name  = block["name"] as? String ?? "tool"
            let input = block["input"] as? [String: Any] ?? [:]
            let detail: String
            if      let cmd  = input["command"]     as? String { detail = cmd }
            else if let path = input["path"]        as? String { detail = path }
            else if let desc = input["description"] as? String { detail = desc }
            else { detail = input.keys.joined(separator: ", ") }
            append("[\(name)] \(detail)", kind: .tool)

        default: break
        }
    }

    // MARK: - Helpers

    private func append(_ text: String, kind: OutputLine.Kind) {
        DispatchQueue.main.async { [weak self] in
            self?.lines.append(OutputLine(text: text, kind: kind))
        }
    }

    private func findClaude() -> String? {
        searchPaths().first { FileManager.default.fileExists(atPath: $0) }
    }

    private func searchPaths() -> [String] {
        let home = realHome
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
    }

    private var realHome: String {
        getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) }
            ?? NSHomeDirectory()
    }
}
