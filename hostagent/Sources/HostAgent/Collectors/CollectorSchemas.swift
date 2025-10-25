import Foundation

/// Simple accessor for embedded collector schemas. Prefer loading the on-disk schema if present
/// (useful in dev), otherwise fall back to an embedded copy.
public enum CollectorSchemas {
    public static func collectorRunRequestSchemaData() -> Data {
        // 1) Developer override via environment variable (useful for editing a
        // schema outside the package layout without rebuilding).
        if let devPath = ProcessInfo.processInfo.environment["HAVEN_DEV_SCHEMA_PATH"], !devPath.isEmpty {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: devPath)) {
                return d
            }
        }

        // 2) Prefer the packaged resource via Bundle.module. This requires the
        // resource to be declared in Package.swift for the target (done).
        #if canImport(BundleModule)
        // `Bundle.module` is available when the file is compiled as part of
        // a SwiftPM target that declares resources.
        if let url = Bundle.module.url(forResource: "collector_run_request.schema", withExtension: "json", subdirectory: "Collectors/schemas") {
            if let d = try? Data(contentsOf: url) {
                return d
            }
        }
        #endif

        // 3) As a last-resort fallback keep a minimal embedded schema so runtime
        // callers won't crash; tests should never hit this if resources are wired.
        let embedded = """
        { "title": "CollectorRunRequest", "type": "object", "additionalProperties": false }
        """
        return Data(embedded.utf8)
    }
}
