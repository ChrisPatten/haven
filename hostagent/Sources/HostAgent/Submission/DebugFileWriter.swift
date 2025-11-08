import Foundation
import HavenCore

/// Shared utility for writing debug output to JSONL files
/// Centralizes all debug-to-file functionality
public actor DebugFileWriter {
    private let outputPath: String
    private let logger = HavenLogger(category: "debug-file-writer")
    private let encoder: JSONEncoder
    private var fileHandle: FileHandle?
    
    public init(outputPath: String) {
        // Expand tilde in path
        let expandedPath = (outputPath as NSString).expandingTildeInPath
        self.outputPath = expandedPath
        
        // Configure encoder for JSON output (compact format for JSONL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]  // No pretty printing for JSONL format
        self.encoder = encoder
        
        // Create directory if it doesn't exist
        let fileURL = URL(fileURLWithPath: expandedPath)
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            logger.debug("Created debug output directory", metadata: ["directory": directoryURL.path])
        } catch {
            logger.error("Failed to create debug output directory", metadata: ["directory": directoryURL.path, "error": error.localizedDescription])
        }
        
        // Open file handle for appending
        if FileManager.default.fileExists(atPath: expandedPath) {
            // File exists, open for appending
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                self.fileHandle = handle
                handle.seekToEndOfFile()
                logger.info("Opened existing debug file for appending", metadata: ["path": expandedPath])
            } catch {
                logger.error("Failed to open existing debug file for writing", metadata: ["path": expandedPath, "error": error.localizedDescription])
            }
        } else {
            // File doesn't exist, create it
            do {
                let created = FileManager.default.createFile(atPath: expandedPath, contents: nil, attributes: nil)
                if created {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    self.fileHandle = handle
                    logger.info("Created new debug file", metadata: ["path": expandedPath])
                } else {
                    logger.error("Failed to create debug file", metadata: ["path": expandedPath])
                }
            } catch {
                logger.error("Failed to create debug file", metadata: ["path": expandedPath, "error": error.localizedDescription])
            }
        }
        
        if fileHandle != nil {
            logger.info("Debug file writer initialized successfully", metadata: ["output_path": expandedPath])
        } else {
            logger.error("Debug file writer initialized but file handle is nil", metadata: ["output_path": expandedPath])
        }
    }
    
    deinit {
        try? fileHandle?.close()
    }
    
    /// Write a JSON-serializable object to the debug file as a JSONL line
    public func writeJSONLine<T: Encodable>(_ object: T) throws {
        guard let handle = fileHandle else {
            logger.error("File handle not available for debug output")
            throw DebugFileWriterError.fileHandleNotAvailable
        }
        
        let jsonData = try encoder.encode(object)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            let line = jsonString + "\n"
            if let lineData = line.data(using: .utf8) {
                // Use write(contentsOf:) instead of deprecated write(_:)
                // This ensures the data is actually written to disk
                try handle.write(contentsOf: lineData)
                try handle.synchronizeFile()
            } else {
                logger.warning("Failed to convert JSON string to data", metadata: [
                    "json_length": String(jsonString.count)
                ])
                throw DebugFileWriterError.stringConversionFailed
            }
        } else {
            logger.warning("Failed to convert JSON data to string", metadata: [
                "data_length": String(jsonData.count)
            ])
            throw DebugFileWriterError.dataConversionFailed
        }
    }
    
    /// Write a dictionary to the debug file as a JSONL line
    public func writeDictionary(_ dict: [String: Any]) throws {
        guard let handle = fileHandle else {
            logger.error("File handle not available for debug output")
            throw DebugFileWriterError.fileHandleNotAvailable
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [])
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            let line = jsonString + "\n"
            if let lineData = line.data(using: .utf8) {
                // Use write(contentsOf:) instead of deprecated write(_:)
                // This ensures the data is actually written to disk
                try handle.write(contentsOf: lineData)
                try handle.synchronizeFile()
            } else {
                logger.warning("Failed to convert JSON string to data", metadata: [
                    "json_length": String(jsonString.count)
                ])
                throw DebugFileWriterError.stringConversionFailed
            }
        } else {
            logger.warning("Failed to convert JSON data to string", metadata: [
                "data_length": String(jsonData.count)
            ])
            throw DebugFileWriterError.dataConversionFailed
        }
    }
}

public enum DebugFileWriterError: Error {
    case fileHandleNotAvailable
    case stringConversionFailed
    case dataConversionFailed
}

