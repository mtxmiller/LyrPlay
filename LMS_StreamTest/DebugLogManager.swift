// File: DebugLogManager.swift
// Debug log capture and export functionality
import Foundation
import os.log
import UIKit

class DebugLogManager: ObservableObject {
    static let shared = DebugLogManager()
    
    private let logger = OSLog(subsystem: "com.lmsstream", category: "DebugLogManager")
    private let logQueue = DispatchQueue(label: "com.lmsstream.debuglog", qos: .utility)
    
    @Published var isLoggingEnabled: Bool = false
    @Published var logFileSize: String = "0 KB"
    
    private var logFileURL: URL
    private let maxLogSize: Int = 10 * 1024 * 1024 // 10MB max
    
    private init() {
        // Create logs directory in Documents
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logsDirectory = documentsPath.appendingPathComponent("Logs")
        
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true, attributes: nil)
        
        self.logFileURL = logsDirectory.appendingPathComponent("lms_debug.log")
        
        updateLogFileSize()
        setupLogCapture()
    }
    
    // MARK: - Log Capture
    
    private func setupLogCapture() {
        // Start with session header
        writeSessionHeader()
    }
    
    func enableLogging(_ enabled: Bool) {
        isLoggingEnabled = enabled
        
        if enabled {
            writeToLog("🟢 Debug logging ENABLED")
            os_log(.info, log: logger, "Debug logging enabled")
        } else {
            writeToLog("🔴 Debug logging DISABLED")
            os_log(.info, log: logger, "Debug logging disabled")
        }
    }
    
    private func writeSessionHeader() {
        let sessionInfo = """
        
        ========================================
        LMS StreamTest Debug Log Session
        ========================================
        Date: \(DateFormatter.logFormatter.string(from: Date()))
        Device: \(UIDevice.current.model) (\(UIDevice.current.systemName) \(UIDevice.current.systemVersion))
        App Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
        Build: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")
        ========================================
        
        """
        
        logQueue.async {
            self.appendToLogFile(sessionInfo)
        }
    }
    
    func writeToLog(_ message: String, level: LogLevel = .info) {
        guard isLoggingEnabled else { return }
        
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let logEntry = "[\(timestamp)] \(level.prefix) \(message)\n"
        
        logQueue.async {
            self.appendToLogFile(logEntry)
            self.checkLogSizeAndRotate()
            
            DispatchQueue.main.async {
                self.updateLogFileSize()
            }
        }
    }
    
    private func appendToLogFile(_ content: String) {
        guard let data = content.data(using: .utf8) else { return }
        
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }
    
    private func checkLogSizeAndRotate() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attributes[.size] as? Int else { return }
        
        if fileSize > maxLogSize {
            rotateLogFile()
        }
    }
    
    private func rotateLogFile() {
        let oldLogURL = logFileURL.appendingPathExtension("old")
        
        // Remove old backup if it exists
        try? FileManager.default.removeItem(at: oldLogURL)
        
        // Move current log to backup
        try? FileManager.default.moveItem(at: logFileURL, to: oldLogURL)
        
        // Start fresh log
        writeSessionHeader()
        
        os_log(.info, log: logger, "Log file rotated (exceeded %d MB)", maxLogSize / 1024 / 1024)
    }
    
    private func updateLogFileSize() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attributes[.size] as? Int else {
            logFileSize = "0 KB"
            return
        }
        
        logFileSize = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
    
    // MARK: - Export Functionality
    
    func exportLogs() -> URL? {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else {
            os_log(.error, log: logger, "No log file exists to export")
            return nil
        }
        
        // Create export file with timestamp
        let timestamp = DateFormatter.exportFormatter.string(from: Date())
        let exportFileName = "LMS_Debug_\(timestamp).log"
        
        let tempDirectory = FileManager.default.temporaryDirectory
        let exportURL = tempDirectory.appendingPathComponent(exportFileName)
        
        do {
            // Copy log file to temp directory with descriptive name
            try FileManager.default.copyItem(at: logFileURL, to: exportURL)
            
            // Add export header
            var exportContent = """
            LMS StreamTest Debug Log Export
            Generated: \(DateFormatter.logFormatter.string(from: Date()))
            File Size: \(logFileSize)
            
            ========================================
            
            """
            
            if let existingContent = try? String(contentsOf: exportURL) {
                exportContent += existingContent
            }
            
            try exportContent.write(to: exportURL, atomically: true, encoding: .utf8)
            
            os_log(.info, log: logger, "Debug log exported to: %{public}s", exportURL.path)
            return exportURL
            
        } catch {
            os_log(.error, log: logger, "Failed to export debug log: %{public}s", error.localizedDescription)
            return nil
        }
    }
    
    func clearLogs() {
        logQueue.async {
            try? FileManager.default.removeItem(at: self.logFileURL)
            self.writeSessionHeader()
            
            DispatchQueue.main.async {
                self.updateLogFileSize()
                os_log(.info, log: self.logger, "Debug logs cleared")
            }
        }
    }
    
    // MARK: - Public Logging Methods
    
    func logInfo(_ message: String) {
        writeToLog(message, level: .info)
    }
    
    func logDebug(_ message: String) {
        writeToLog(message, level: .debug)
    }
    
    func logError(_ message: String) {
        writeToLog(message, level: .error)
    }
    
    func logWarning(_ message: String) {
        writeToLog(message, level: .warning)
    }
}

// MARK: - Supporting Types

enum LogLevel {
    case info, debug, warning, error
    
    var prefix: String {
        switch self {
        case .info: return "ℹ️ INFO"
        case .debug: return "🔍 DEBUG"
        case .warning: return "⚠️ WARN"
        case .error: return "❌ ERROR"
        }
    }
}

// MARK: - Date Formatters

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    static let exportFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}