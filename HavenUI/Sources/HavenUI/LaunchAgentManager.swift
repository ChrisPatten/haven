import Foundation

actor LaunchAgentManager {
    private let launchAgentLabel = "com.haven.hostagent"
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    
    private var launchAgentPath: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents/com.haven.hostagent.plist")
    }
    
    private let hostagentBinaryPath = "/usr/local/bin/hostagent"
    private let havenConfigPath = "~/.haven/hostagent.yaml"
    
    // MARK: - Status Check
    
    func isRunning() async -> Bool {
        do {
            let result = try await executeShellCommand(
                "/bin/launchctl",
                arguments: ["list", launchAgentLabel]
            )
            return !result.isEmpty
        } catch {
            return false
        }
    }
    
    func getProcessState() async -> ProcessState {
        if await isRunning() {
            return .running
        } else {
            return .stopped
        }
    }
    
    // MARK: - Installation
    
    func installLaunchAgent() async throws {
        // Create directory if needed
        try FileManager.default.createDirectory(
            at: launchAgentPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        // Generate plist content
        let plistContent = generatePlist()
        
        // Write plist file
        try plistContent.write(to: launchAgentPath, atomically: true, encoding: .utf8)
        
        // Set permissions
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: launchAgentPath.path
        )
        
        // Bootstrap the agent
        _ = try await executeShellCommand(
            "/bin/launchctl",
            arguments: [
                "bootstrap",
                "gui/\(getUID())",
                launchAgentPath.path
            ]
        )
    }
    
    func uninstallLaunchAgent() async throws {
        // Bootout the agent
        do {
            _ = try await executeShellCommand(
                "/bin/launchctl",
                arguments: [
                    "bootout",
                    "gui/\(getUID())",
                    launchAgentPath.path
                ]
            )
        } catch {
            // Agent might not be loaded, continue anyway
        }
        
        // Remove plist file
        if FileManager.default.fileExists(atPath: launchAgentPath.path) {
            try FileManager.default.removeItem(at: launchAgentPath)
        }
    }
    
    // MARK: - Process Control
    
    func startHostAgent() async throws {
        // Ensure LaunchAgent is installed
        if !FileManager.default.fileExists(atPath: launchAgentPath.path) {
            try await installLaunchAgent()
        }
        
        // Kickstart the service
        _ = try await executeShellCommand(
            "/bin/launchctl",
            arguments: [
                "kickstart",
                "-k",
                "gui/\(getUID())/\(launchAgentLabel)"
            ]
        )
    }
    
    func stopHostAgent() async throws {
        _ = try await executeShellCommand(
            "/bin/launchctl",
            arguments: [
                "kill",
                "TERM",
                "gui/\(getUID())/\(launchAgentLabel)"
            ]
        )
    }
    
    // MARK: - Plist Generation
    
    private func generatePlist() -> String {
        let homeDir = homeDirectory.path
        let configPath = (havenConfigPath as NSString).expandingTildeInPath
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchAgentLabel)</string>
            
            <key>ProgramArguments</key>
            <array>
                <string>\(hostagentBinaryPath)</string>
                <string>--config</string>
                <string>\(configPath)</string>
            </array>
            
            <key>RunAtLoad</key>
            <true/>
            
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            
            <key>StandardOutPath</key>
            <string>\(homeDir)/Library/Logs/Haven/hostagent.log</string>
            
            <key>StandardErrorPath</key>
            <string>\(homeDir)/Library/Logs/Haven/hostagent-error.log</string>
            
            <key>WorkingDirectory</key>
            <string>\(homeDir)</string>
            
            <key>EnvironmentVariables</key>
            <dict>
                <key>HAVEN_LOG_LEVEL</key>
                <string>info</string>
            </dict>
            
            <key>ProcessType</key>
            <string>Interactive</string>
            
            <key>Nice</key>
            <integer>0</integer>
            
            <key>ThrottleInterval</key>
            <integer>10</integer>
        </dict>
        </plist>
        """
    }
    
    // MARK: - Shell Execution
    
    private func executeShellCommand(_ command: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw LaunchAgentError.commandFailed(
                command: command,
                exitCode: Int(process.terminationStatus),
                output: output
            )
        }
        
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func getUID() -> Int {
        return Int(getuid())
    }
    
    // MARK: - Error Types
    
    enum LaunchAgentError: LocalizedError {
        case commandFailed(command: String, exitCode: Int, output: String)
        case fileOperationFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .commandFailed(let command, let exitCode, let output):
                return "Command '\(command)' failed with exit code \(exitCode): \(output)"
            case .fileOperationFailed(let message):
                return "File operation failed: \(message)"
            }
        }
    }
}
