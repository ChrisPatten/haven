import Foundation

actor HostAgentClient {
    private let baseURL = URL(string: "http://localhost:7090")!
    private let session: URLSession
    
    private let healthEndpoint = "/v1/health"
    private let timeoutInterval: TimeInterval = 5.0
    
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
