import PackagePlugin
import Foundation

@main
struct GenerateBuildInfo: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        // Only generate for HavenCore target
        guard target.name == "HavenCore" else {
            return []
        }
        
        let outputPath = context.pluginWorkDirectory.appending("BuildInfo.swift")
        let scriptPath = context.package.directory.appending("Scripts/generate-build-info.sh")
        
        return [
            .prebuildCommand(
                displayName: "Generate Build Info",
                executable: Path("/bin/bash"),
                arguments: [scriptPath.string, outputPath.string],
                outputFilesDirectory: context.pluginWorkDirectory
            )
        ]
    }
}
