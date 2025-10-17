import Foundation

public enum HostAgentVersion {
    public static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}

public enum PermissionChecker {
    public static func hasFullDiskAccess() -> Bool {
        // TCC status not programmatically accessible without private APIs; we approximate by checking read access to chat.db
        let messagesDB = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath
        return FileManager.default.isReadableFile(atPath: messagesDB)
    }
}
