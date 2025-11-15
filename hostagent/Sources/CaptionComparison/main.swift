import Foundation
import Caption
import HavenCore
import Yams

/// Configuration for caption comparison script
struct Config: Codable {
    var ollama: OllamaConfig?
    var openai: OpenAIConfig?
    
    struct OllamaConfig: Codable {
        var url: String?
        var model: String?
        var timeoutMs: Int?
    }
    
    struct OpenAIConfig: Codable {
        var apiKey: String?
        var model: String?
    }
}

/// Result of caption generation
struct CaptionResult {
    let foundation: String?
    let ollama: String?
    let openai: String?
    let openaiTokens: OpenAITokenUsage?
    let foundationError: String?
    let ollamaError: String?
    let openaiError: String?
    
    struct OpenAITokenUsage {
        let input: Int
        let output: Int
        let total: Int
    }
}

/// Helper function to get OpenAI caption and token usage in a single API call
func getOpenAICaptionWithTokens(imageData: Data, apiKey: String, model: String, filename: String) async throws -> (caption: String, tokens: CaptionResult.OpenAITokenUsage) {
    // File is already on files.chrispatten.dev, construct URL directly
    let imageUrl = "https://files.chrispatten.dev/\(filename)"
    
    let prompt = "Describe the image scene and contents. Provide a short, concise caption."
    
    var inputs: [[String: Any]] = []
    inputs.append([
        "role": "user",
        "content": [
            [
                "type": "input_image",
                "image_url": imageUrl
            ],
            [
                "type": "input_text",
                "text": prompt
            ]
        ]
    ])
    
    let payload: [String: Any] = [
        "model": model,
        "input": inputs
    ]
    
    guard let url = URL(string: "https://api.openai.com/v1/responses") else {
        throw NSError(domain: "OpenAIError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 60.0
    
    guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
        throw NSError(domain: "OpenAIError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode payload"])
    }
    request.httpBody = jsonData
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        throw NSError(domain: "OpenAIError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode): \(body.prefix(200))"])
    }
    
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "OpenAIError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
    }
    
    // Extract caption
    var caption: String? = nil
    if let output = json["output"] as? [[String: Any]] {
        for block in output {
            if let content = block["content"] as? [[String: Any]] {
                for item in content {
                    if let type = item["type"] as? String,
                       type == "output_text",
                       let text = item["text"] as? String, !text.isEmpty {
                        caption = text
                        break
                    }
                }
                if caption != nil {
                    break
                }
            }
        }
    }
    
    guard let captionText = caption else {
        throw NSError(domain: "OpenAIError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No caption in response"])
    }
    
    // Extract token usage
    let usage = json["usage"] as? [String: Any]
    let inputTokens = usage?["input_tokens"] as? Int ?? usage?["prompt_tokens"] as? Int ?? 0
    let outputTokens = usage?["output_tokens"] as? Int ?? usage?["completion_tokens"] as? Int ?? 0
    
    let truncated = captionText.count > 200 ? String(captionText.prefix(200)) + "…" : captionText
    
    return (
        caption: truncated.trimmingCharacters(in: .whitespacesAndNewlines),
        tokens: CaptionResult.OpenAITokenUsage(
            input: inputTokens,
            output: outputTokens,
            total: inputTokens + outputTokens
        )
    )
}

/// Main script entry point
@main
struct CaptionComparison {
    static func main() async {
        // Parse command line arguments
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: \(args[0]) <directory>")
            exit(1)
        }
        
        let directoryPath = args[1]
        
        // Check if directory exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            print("Error: Directory does not exist: \(directoryPath)")
            exit(1)
        }
        
        let directoryURL = URL(fileURLWithPath: directoryPath)
        
        // Load config file if it exists
        let configURL = directoryURL.appendingPathComponent("caption-config.yaml")
        var config = Config()
        
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let configString = try String(contentsOf: configURL, encoding: .utf8)
                guard let node = try? Yams.compose(yaml: configString) else {
                    print("Warning: Failed to parse YAML config file")
                    return
                }
                
                // Manually parse YAML structure
                var ollamaConfig: Config.OllamaConfig? = nil
                var openaiConfig: Config.OpenAIConfig? = nil
                
                if case .mapping(let rootMapping) = node {
                    // Find "ollama" key in root mapping
                    var ollamaNode: Yams.Node? = nil
                    for (key, value) in rootMapping {
                        if case .scalar(let scalar) = key, scalar.string == "ollama" {
                            ollamaNode = value
                            break
                        }
                    }
                    
                    if let ollamaNode = ollamaNode,
                       case .mapping(let ollamaMapping) = ollamaNode {
                        
                        var url: String? = nil
                        var model: String? = nil
                        var timeoutMs: Int? = nil
                        
                        // Extract values from ollama mapping
                        for (key, value) in ollamaMapping {
                            if case .scalar(let keyScalar) = key {
                                switch keyScalar.string {
                                case "url":
                                    if case .scalar(let valScalar) = value {
                                        url = valScalar.string
                                    }
                                case "model":
                                    if case .scalar(let valScalar) = value {
                                        model = valScalar.string
                                    }
                                case "timeoutMs":
                                    if case .scalar(let valScalar) = value,
                                       let timeoutVal = Int(valScalar.string) {
                                        timeoutMs = timeoutVal
                                    }
                                default:
                                    break
                                }
                            }
                        }
                    
                        if url != nil || model != nil || timeoutMs != nil {
                            ollamaConfig = Config.OllamaConfig(url: url, model: model, timeoutMs: timeoutMs)
                        }
                    }
                    
                    // Parse OpenAI config
                    var openaiNode: Yams.Node? = nil
                    for (key, value) in rootMapping {
                        if case .scalar(let scalar) = key, scalar.string == "openai" {
                            openaiNode = value
                            break
                        }
                    }
                    
                    if let openaiNode = openaiNode,
                       case .mapping(let openaiMapping) = openaiNode {
                        var apiKey: String? = nil
                        var model: String? = nil
                        
                        for (key, value) in openaiMapping {
                            if case .scalar(let keyScalar) = key {
                                switch keyScalar.string {
                                case "apiKey":
                                    if case .scalar(let valScalar) = value {
                                        apiKey = valScalar.string
                                    }
                                case "model":
                                    if case .scalar(let valScalar) = value {
                                        model = valScalar.string
                                    }
                                default:
                                    break
                                }
                            }
                        }
                        
                        if apiKey != nil || model != nil {
                            openaiConfig = Config.OpenAIConfig(apiKey: apiKey, model: model)
                        }
                    }
                }
                
                if ollamaConfig != nil || openaiConfig != nil {
                    config = Config(ollama: ollamaConfig, openai: openaiConfig)
                    print("Loaded configuration from caption-config.yaml")
                }
            } catch {
                print("Warning: Failed to load config file: \(error.localizedDescription)")
            }
        }
        
        // Get Ollama settings from config
        let ollamaUrl = config.ollama?.url ?? ProcessInfo.processInfo.environment["OLLAMA_API_URL"] ?? "http://localhost:11434/api/generate"
        let ollamaModel = config.ollama?.model ?? ProcessInfo.processInfo.environment["OLLAMA_VISION_MODEL"] ?? "llava:7b"
        let ollamaTimeoutMs = config.ollama?.timeoutMs ?? 60000
        
        // Get OpenAI settings from config
        let openaiApiKey = config.openai?.apiKey ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        let openaiModel = config.openai?.model ?? ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-4o"
        
        // Set Ollama URL via environment variable (CaptionService reads from env)
        // Must be set before creating CaptionService instances
        setenv("OLLAMA_API_URL", ollamaUrl, 1)
        
        print("Ollama configuration:")
        print("  URL: \(ollamaUrl)")
        print("  Model: \(ollamaModel)")
        print("  Timeout: \(ollamaTimeoutMs)ms")
        print()
        
        if let apiKey = openaiApiKey {
            print("OpenAI configuration:")
            print("  Model: \(openaiModel)")
            print("  API Key: \(apiKey.prefix(10))...")
            print()
        }
        
        // Find image files in directory
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"]
        let imageFiles = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return imageExtensions.contains(ext)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        
        guard let imageFiles = imageFiles, !imageFiles.isEmpty else {
            print("Error: No image files found in directory")
            exit(1)
        }
        
        print("Found \(imageFiles.count) image file(s)")
        print()
        
        // Initialize caption services (Ollama URL is now set in environment)
        // Foundation captioning disabled - API not yet available
        let ollamaService = CaptionService(method: "ollama", timeoutMs: ollamaTimeoutMs, model: ollamaModel)
        let openaiService = openaiApiKey != nil ? CaptionService(method: "openai", timeoutMs: 60000, openaiApiKey: openaiApiKey, openaiModel: openaiModel) : nil
        
        // Process each image
        var results: [(filename: String, result: CaptionResult)] = []
        
        for (index, imageURL) in imageFiles.enumerated() {
            let filename = imageURL.lastPathComponent
            print("[\(index + 1)/\(imageFiles.count)] Processing: \(filename)")
            
            // Load image data
            guard let imageData = try? Data(contentsOf: imageURL) else {
                print("  Warning: Failed to load image data")
                results.append((filename: filename, result: CaptionResult(
                    foundation: nil,
                    ollama: nil,
                    openai: nil,
                    openaiTokens: nil,
                    foundationError: nil,
                    ollamaError: "Failed to load image data",
                    openaiError: "Failed to load image data"
                )))
                continue
            }
            
            // Foundation captioning disabled - API not yet available
            
            // Generate Ollama caption
            var ollamaCaption: String? = nil
            var ollamaError: String? = nil
            do {
                ollamaCaption = try await ollamaService.generateCaption(imageData: imageData)
            } catch {
                ollamaError = error.localizedDescription
                print("  Ollama error: \(error.localizedDescription)")
            }
            
            // Generate OpenAI caption (single API call gets both caption and token usage)
            var openaiCaption: String? = nil
            var openaiError: String? = nil
            var openaiTokens: CaptionResult.OpenAITokenUsage? = nil
            if let openaiService = openaiService, let apiKey = openaiApiKey {
                do {
                    // Make a single API call to get both caption and token usage
                    // File is already on files.chrispatten.dev, so pass filename directly
                    let result = try await getOpenAICaptionWithTokens(imageData: imageData, apiKey: apiKey, model: openaiModel, filename: filename)
                    openaiCaption = result.caption
                    openaiTokens = result.tokens
                } catch {
                    openaiError = error.localizedDescription
                    print("  OpenAI error: \(error.localizedDescription)")
                }
            }
            
            print("  Ollama: \(ollamaCaption ?? "(none)")")
            if openaiService != nil {
                print("  OpenAI: \(openaiCaption ?? "(none)")")
            }
            print()
            
            results.append((filename: filename, result: CaptionResult(
                foundation: nil,
                ollama: ollamaCaption,
                openai: openaiCaption,
                openaiTokens: openaiTokens,
                foundationError: nil,
                ollamaError: ollamaError,
                openaiError: openaiError
            )))
        }
        
        // Generate markdown output
        let markdownURL = directoryURL.appendingPathComponent("caption-comparison.md")
        var markdown = ""
        
        for (filename, result) in results {
            markdown += "# \(filename)\n\n"
            
            // Foundation captioning disabled - API not yet available
            // if let foundation = result.foundation {
            //     markdown += "**Foundation Caption:**\n\(foundation)\n\n"
            // }
            
            // Ollama caption
            if let ollama = result.ollama {
                markdown += "**Ollama Caption:**\n\(ollama)\n\n"
            } else {
                markdown += "**Ollama Caption:** *(failed: \(result.ollamaError ?? "unknown error"))*\n\n"
            }
            
            // OpenAI caption
            if let openai = result.openai {
                markdown += "**OpenAI Caption:**\n\(openai)\n\n"
                if let tokens = result.openaiTokens {
                    markdown += "*Tokens: \(tokens.input) input, \(tokens.output) output (total: \(tokens.total))*\n\n"
                }
            } else if openaiService != nil {
                markdown += "**OpenAI Caption:** *(failed: \(result.openaiError ?? "unknown error"))*\n\n"
            }
            
            markdown += "---\n\n"
        }
        
        // Write markdown file
        do {
            try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
            print("Results written to: \(markdownURL.path)")
        } catch {
            print("Error: Failed to write markdown file: \(error.localizedDescription)")
            exit(1)
        }
    }
}

