import Foundation
import Darwin

final class DirectoryWatch {
    let id: String
    let path: String
    let glob: String
    let target: String
    let handoff: String
    let createdAt: Date

    private let queue: DispatchQueue
    private let callback: @Sendable (URL) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var debounceWorkItems: [String: DispatchWorkItem] = [:]
    private var processedFiles: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 1.5

    init(id: String, path: String, glob: String, target: String, handoff: String, queue: DispatchQueue, callback: @escaping @Sendable (URL) -> Void) {
        self.id = id
        self.path = path
        self.glob = glob
        self.target = target
        self.handoff = handoff
        self.queue = queue
        self.callback = callback
        self.createdAt = Date()
    }

    func start() throws {
        guard fileDescriptor == -1 else { return }
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Unable to watch \(path)"])
        }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: [.write, .extend, .attrib, .rename], queue: queue)
        source?.setEventHandler { [weak self] in
            self?.handleDirectoryEvent()
        }
        source?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }
        source?.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func handleDirectoryEvent() {
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: nil) else {
            return
        }

        for case let fileURL as URL in enumerator {
            guard matchesPattern(fileURL.lastPathComponent) else { continue }
            guard let attributes = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), attributes.isRegularFile == true else { continue }
            let lastModified = attributes.contentModificationDate ?? Date()
            if shouldProcess(path: fileURL.path, modified: lastModified) {
                scheduleDebouncedCallback(for: fileURL, modified: lastModified)
            }
        }
    }

    private func matchesPattern(_ name: String) -> Bool {
        fnmatch(glob, name, 0) == 0
    }

    private func shouldProcess(path: String, modified: Date) -> Bool {
        if let last = processedFiles[path], last >= modified.addingTimeInterval(-debounceInterval) {
            return false
        }
        return true
    }

    private func scheduleDebouncedCallback(for url: URL, modified: Date) {
        let path = url.path
        if let existing = debounceWorkItems[path] {
            existing.cancel()
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.processedFiles[path] = modified
            self.callback(url)
            self.debounceWorkItems.removeValue(forKey: path)
        }
        debounceWorkItems[path] = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
