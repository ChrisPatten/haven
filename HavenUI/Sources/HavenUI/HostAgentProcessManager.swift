import Foundation

// Global PID tracking & atexit handler (cannot capture actor 'Self' in C atexit callback)
fileprivate var HavenUI_HostAgentCurrentPID: Int32? = nil
fileprivate var HavenUI_HostAgentAtexitRegistered: Bool = false
fileprivate var HavenUI_HostAgentSignalsRegistered: Bool = false
fileprivate func HavenUI_HostAgentAtexitHandler() {
    if let pid = HavenUI_HostAgentCurrentPID {
        // Attempt graceful then force
        kill(pid, SIGTERM)
        usleep(200_000)
        kill(pid, SIGKILL)
    }
}

@_cdecl("HavenUI_HostAgentSignalHandler")
private func HavenUI_HostAgentSignalHandler(_ sig: Int32) {
    // Kill hostagent if still running; ignore errors
    if let pid = HavenUI_HostAgentCurrentPID {
        kill(pid, SIGTERM)
        usleep(150_000)
        kill(pid, SIGKILL)
    }
    // Restore default handler then re-raise to terminate HavenUI normally
    signal(sig, SIG_DFL)
    raise(sig)
}

/// Manages hostagent as a child process of HavenUI
/// The hostagent process runs only while HavenUI is running
actor HostAgentProcessManager {
    private let hostagentBinaryPath = "/usr/local/bin/hostagent"
    private let havenConfigPath: String
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private static var atexitRegistered = false
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    
    init() {
        // Expand tilde in config path
        self.havenConfigPath = (NSString(string: "~/.haven/hostagent.yaml")).expandingTildeInPath
    }
    
    // MARK: - Status Check
    
    func isRunning() -> Bool {
        guard let process = process else {
            return false
        }
        return process.isRunning
    }
    
    func getProcessState() -> ProcessState {
        return isRunning() ? .running : .stopped
    }
    
    func getProcessId() -> Int32? {
        return process?.processIdentifier
    }
    
    // MARK: - Process Control
    
    func startHostAgent() throws {
        // Don't start if already running
        if isRunning() {
            print("⚠️ hostagent is already running")
            return
        }
        
        // Verify binary exists
        guard FileManager.default.fileExists(atPath: hostagentBinaryPath) else {
            throw HostAgentError.binaryNotFound(path: hostagentBinaryPath)
        }
        
        // Verify config exists
        guard FileManager.default.fileExists(atPath: havenConfigPath) else {
            throw HostAgentError.configNotFound(path: havenConfigPath)
        }
        
        // Ensure logs directory exists
        ensureLogsDirectory()
        
        // Create log file handles
        let logPath = homeDirectory.appendingPathComponent("Library/Logs/Haven/hostagent.log")
        let errorLogPath = homeDirectory.appendingPathComponent("Library/Logs/Haven/hostagent-error.log")
        
        // Create or open log files
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        FileManager.default.createFile(atPath: errorLogPath.path, contents: nil)
        
        guard let outputHandle = FileHandle(forWritingAtPath: logPath.path),
              let errorHandle = FileHandle(forWritingAtPath: errorLogPath.path) else {
            throw HostAgentError.logFileError
        }
        
        // Seek to end of files to append
        outputHandle.seekToEndOfFile()
        errorHandle.seekToEndOfFile()
        
        // Create and configure process
        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: hostagentBinaryPath)
        newProcess.arguments = ["--config", havenConfigPath]
        newProcess.standardOutput = outputHandle
        newProcess.standardError = errorHandle
        newProcess.currentDirectoryURL = homeDirectory
        
        // Set environment
        var env = ProcessInfo.processInfo.environment
        env["HAVEN_LOG_LEVEL"] = "info"
        env["NSUnbufferedIO"] = "YES"
        newProcess.environment = env
        
            // IMPORTANT: Don't create a new process group - keep hostagent in HavenUI's process group
            // This ensures hostagent gets signals when HavenUI terminates
            // (Process spawns children in the same process group by default, which is what we want)
        
        // Set termination handler
        newProcess.terminationHandler = { [weak self] process in
            Task { [weak self] in
                await self?.handleTermination(process)
            }
        }
        
        // Start the process
        try newProcess.run()
        self.process = newProcess
    self.stdoutHandle = outputHandle
    self.stderrHandle = errorHandle
    HavenUI_HostAgentCurrentPID = newProcess.processIdentifier
    registerAtexitSafeguardIfNeeded()
    registerSignalHandlersIfNeeded()
        
        print("✓ Started hostagent process (PID: \(newProcess.processIdentifier))")
    }
    
    func stopHostAgent() throws {
        guard let process = process, process.isRunning else {
            print("⚠️ hostagent is not running")
            return
        }
        
        let pid = process.processIdentifier
        print("🛑 Stopping hostagent process (PID: \(pid))")
        
        // Send SIGTERM for graceful shutdown
        process.terminate()
        
        // Wait a bit for graceful shutdown
        let timeout = Date().addingTimeInterval(2.0) // graceful window
        while process.isRunning && Date() < timeout {
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        // Force kill if still running
        if process.isRunning {
            print("⚠️ hostagent didn't stop gracefully, sending SIGKILL")
            kill(pid, SIGKILL)
        }
        
        // Close file handles
        closeFileHandles()
        self.process = nil
    HavenUI_HostAgentCurrentPID = nil
        print("✓ Stopped hostagent process")
    }

    /// Force stop without waiting (used by atexit or emergency scenarios)
    func forceStop() {
        guard let process = process else { return }
        let pid = process.processIdentifier
        if process.isRunning {
            print("⛔ Forcing hostagent stop (PID: \(pid))")
            kill(pid, SIGKILL)
        }
        closeFileHandles()
        self.process = nil
    }
    
    // MARK: - Private Helpers
    
    private func ensureLogsDirectory() {
        let logsPath = homeDirectory.appendingPathComponent("Library/Logs/Haven")
        try? FileManager.default.createDirectory(
            at: logsPath,
            withIntermediateDirectories: true
        )
    }
    
    private func handleTermination(_ process: Process) {
        let exitCode = process.terminationStatus
        let reason = process.terminationReason
        
        print("⚠️ hostagent process terminated (PID: \(process.processIdentifier), exit: \(exitCode), reason: \(reason.rawValue))")
        
        // Clear our reference if this is our process
        if self.process?.processIdentifier == process.processIdentifier {
            self.process = nil
            closeFileHandles()
            HavenUI_HostAgentCurrentPID = nil
        }
    }

    private func closeFileHandles() {
        if let h = stdoutHandle { try? h.close() }
        if let h = stderrHandle { try? h.close() }
        stdoutHandle = nil
        stderrHandle = nil
    }

    private func registerAtexitSafeguardIfNeeded() {
        guard !HavenUI_HostAgentAtexitRegistered else { return }
        HavenUI_HostAgentAtexitRegistered = true
        atexit(HavenUI_HostAgentAtexitHandler)
    }

    private func registerSignalHandlersIfNeeded() {
        guard !HavenUI_HostAgentSignalsRegistered else { return }
        HavenUI_HostAgentSignalsRegistered = true
        signal(SIGTERM, HavenUI_HostAgentSignalHandler)
        signal(SIGINT, HavenUI_HostAgentSignalHandler)
    }
    
    // MARK: - Error Types
    
    enum HostAgentError: LocalizedError {
        case binaryNotFound(path: String)
        case configNotFound(path: String)
        case logFileError
        case processError(String)
        
        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let path):
                return "hostagent binary not found at: \(path)"
            case .configNotFound(let path):
                return "hostagent config not found at: \(path)"
            case .logFileError:
                return "Failed to create or open log files"
            case .processError(let message):
                return "Process error: \(message)"
            }
        }
    }
}
