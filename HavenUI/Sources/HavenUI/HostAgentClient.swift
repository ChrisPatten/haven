import Foundation

actor HostAgentClient {
    private let baseURL = URL(string: "http://localhost:7090")!
    private let session: URLSession

    private let healthEndpoint = "/v1/health"
    private let modulesEndpoint = "/v1/modules"
    private let timeoutInterval: TimeInterval = 5.0

    // Add auth header configuration
    private let authHeader = "x-auth"
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

        // Add authentication header
        request.setValue(authSecret, forHTTPHeaderField: authHeader)

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
    }
    
    // MARK: - Modules
    
    func getModules() async throws -> ModulesResponse {
        let url = baseURL.appendingPathComponent(modulesEndpoint)
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
        let modulesResponse = try decoder.decode(ModulesResponse.self, from: data)
        return modulesResponse
    }
    
    // MARK: - Collector Run
    
    func runCollector(_ collector: String, request: CollectorRunRequest? = nil) async throws -> RunResponse {
        let url = baseURL.appendingPathComponent("/v1/collectors/\(collector):run")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(authSecret, forHTTPHeaderField: authHeader)
        
        // Use empty dict if no request provided
        let bodyRequest = request ?? CollectorRunRequest()
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(bodyRequest)
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
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
