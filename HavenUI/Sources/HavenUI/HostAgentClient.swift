import Foundation

actor HostAgentClient {
    private let baseURL = URL(string: "http://localhost:7090")!
    private let session: URLSession

    private let healthEndpoint = "/v1/health"
    private let modulesEndpoint = "/v1/modules"
    private let timeoutInterval: TimeInterval = 3.0  // Reduced from 5s to 3s for faster failure when hostagent isn't running
    private let collectorRunTimeout: TimeInterval = 3600.0  // 1 hour for collector runs (effectively no timeout)

    // Add auth header configuration
    // Note: The server lowercases the header, so "X-Haven-Key" becomes "x-haven-key"
    // Default config uses "X-Haven-Key" but we should match the config file
    private let authHeader = "X-Haven-Key"  // Will be lowercased by server
    private let authSecret = "changeme"  // Match your hostagent config

    init(session: URLSession = URLSession.shared) {
        self.session = session
    }
    
    // MARK: - Health Check

    func getHealth() async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent(healthEndpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Add authentication header (server lowercases it)
        request.setValue(authSecret, forHTTPHeaderField: authHeader)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw ClientError.httpError(statusCode: httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            let healthResponse = try decoder.decode(HealthResponse.self, from: data)
            return healthResponse
        } catch let error as URLError {
            // Handle network errors (connection refused, timeout, etc.)
            if error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                throw ClientError.networkError(error)
            } else if error.code == .timedOut {
                throw ClientError.networkError(error)
            }
            throw ClientError.networkError(error)
        } catch {
            if let clientError = error as? ClientError {
                throw clientError
            }
            throw ClientError.networkError(error)
        }
    }
    
    // MARK: - Modules
    
    func getModules() async throws -> ModulesResponse {
        let url = baseURL.appendingPathComponent(modulesEndpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authSecret, forHTTPHeaderField: authHeader)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                throw ClientError.httpError(statusCode: httpResponse.statusCode)
            }
            
            let decoder = JSONDecoder()
            do {
                let modulesResponse = try decoder.decode(ModulesResponse.self, from: data)
                return modulesResponse
            } catch {
                throw ClientError.decodingError(error)
            }
        } catch let error as URLError {
            // Handle network errors (connection refused, timeout, etc.)
            if error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                throw ClientError.networkError(error)
            } else if error.code == .timedOut {
                throw ClientError.networkError(error)
            }
            throw ClientError.networkError(error)
        } catch {
            if let clientError = error as? ClientError {
                throw clientError
            }
            throw ClientError.networkError(error)
        }
    }
    
    // MARK: - Collector Run
    
    func runCollector(_ collector: String, request: CollectorRunRequest? = nil) async throws -> RunResponse {
        let url = baseURL.appendingPathComponent("/v1/collectors/\(collector):run")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = collectorRunTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(authSecret, forHTTPHeaderField: authHeader)
        
        // Use empty dict if no request provided
        let bodyRequest = request ?? CollectorRunRequest()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        urlRequest.httpBody = try encoder.encode(bodyRequest)
        
        // Debug logging
        let requestBody = String(data: urlRequest.httpBody ?? Data(), encoding: .utf8) ?? "Unable to encode"
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔵 HostAgentClient: Sending collector run request")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📍 URL: \(url.absoluteString)")
        print("🔧 Method: POST")
        print("📋 Headers:")
        print("   Content-Type: application/json")
        print("   Accept: application/json")
        print("   \(authHeader): [REDACTED]")
        print("📦 Request Body:")
        print(requestBody)
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ HostAgentClient: Invalid response type")
            throw ClientError.invalidResponse
        }
        
        let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode"
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🟢 HostAgentClient: Received response")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📊 Status Code: \(httpResponse.statusCode)")
        print("📦 Response Body:")
        print(responseBody)
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard (200...299).contains(httpResponse.statusCode) else {
            print("❌ HostAgentClient: HTTP error \(httpResponse.statusCode)")
            throw ClientError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let runResponse = try decoder.decode(RunResponse.self, from: data)
        return runResponse
    }
    
    func runCollectorWithPayload(_ collector: String, jsonPayload: String) async throws -> RunResponse {
        let url = baseURL.appendingPathComponent("/v1/collectors/\(collector):run")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = collectorRunTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(authSecret, forHTTPHeaderField: authHeader)
        
        // Use the provided JSON payload directly
        urlRequest.httpBody = jsonPayload.data(using: .utf8)
        
        // Debug logging with formatted output
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔵 HostAgentClient: Sending collector run request with payload")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📍 URL: \(url.absoluteString)")
        print("🔧 Method: POST")
        print("📋 Headers:")
        print("   Content-Type: application/json")
        print("   Accept: application/json")
        print("   \(authHeader): [REDACTED]")
        print("📦 Request Body:")
        
        // Try to format JSON for better readability
        if let jsonData = jsonPayload.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []),
           let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            print(prettyString)
        } else {
            print(jsonPayload)
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ HostAgentClient: Invalid response type")
            throw ClientError.invalidResponse
        }
        
        let responseBody = String(data: data, encoding: .utf8) ?? "Unable to decode"
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🟢 HostAgentClient: Received response")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📊 Status Code: \(httpResponse.statusCode)")
        print("📦 Response Body:")
        
        // Try to format JSON response for better readability
        if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
           let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            print(prettyString)
        } else {
            print(responseBody)
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard (200...299).contains(httpResponse.statusCode) else {
            print("❌ HostAgentClient: HTTP error \(httpResponse.statusCode)")
            throw ClientError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let runResponse = try decoder.decode(RunResponse.self, from: data)
        return runResponse
    }
    
    // MARK: - Collector State
    
    func getCollectorState(_ collector: String) async throws -> CollectorStateResponse {
        let url = baseURL.appendingPathComponent("/v1/collectors/\(collector)/state")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authSecret, forHTTPHeaderField: authHeader)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ClientError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stateResponse = try decoder.decode(CollectorStateResponse.self, from: data)
        return stateResponse
    }
    
    // MARK: - Error Types
    
    enum ClientError: LocalizedError {
        case invalidResponse
        case httpError(statusCode: Int)
        case decodingError(Error)
        case networkError(Error)
        
        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response from server"
            case .httpError(let statusCode):
                return "HTTP error: \(statusCode)"
            case .decodingError(let error):
                return "Failed to decode response: \(error.localizedDescription)"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            }
        }
    }
}
