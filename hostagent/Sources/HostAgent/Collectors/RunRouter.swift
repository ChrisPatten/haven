import Foundation
import HavenCore
public enum RunRouterError: Error {
    case invalidJSON(String)
}

public struct RunRouter {
    /// Dispatch map maps collector name -> handler closure
    public static func handle(request: HTTPRequest, context: RequestContext, dispatchMap: [String: (HTTPRequest, RequestContext) async -> HTTPResponse]) async -> HTTPResponse {
        let prefix = "/v1/collectors/"
        let suffix = ":run"
        guard request.path.hasPrefix(prefix) && request.path.hasSuffix(suffix) else {
            return HTTPResponse.notFound()
        }

        let startIndex = request.path.index(request.path.startIndex, offsetBy: prefix.count)
        let endIndex = request.path.index(request.path.endIndex, offsetBy: -suffix.count)
        let collectorName = String(request.path[startIndex..<endIndex])

        // Strict decode into CollectorRunRequest to reject unknown fields.
        do {
            _ = try request.decodeJSON(CollectorRunRequest.self)
        } catch let decodingErr as DecodingError {
            return HTTPResponse.badRequest(message: "Invalid request JSON: \(decodingErr.localizedDescription)")
        } catch {
            return HTTPResponse.badRequest(message: "Invalid request JSON: \(error.localizedDescription)")
        }

        guard let handler = dispatchMap[collectorName] else {
            return HTTPResponse.notFound(message: "Unknown collector '\(collectorName)'")
        }

        // Create the RunResponse envelope before invoking the handler so we capture start time
        var runResp = RunResponse(collector: collectorName, runID: UUID().uuidString, startedAt: Date())

        // Call underlying handler and capture response
        let inner = await handler(request, context)

        // Attempt to parse the inner body as an adapter result payload and incorporate into runResp
        if let body = inner.body {
            // Try decode into a payload that conforms to RunResponse.AdapterResult
            struct AdapterPayload: Codable, RunResponse.AdapterResult {
                let scanned: Int
                let matched: Int
                let submitted: Int
                let skipped: Int
                let earliest_touched: String?
                let latest_touched: String?
                let warnings: [String]
                let errors: [String]

                // Convert the string timestamps to Date for the AdapterResult protocol
                var earliestTouched: Date? {
                    guard let s = earliest_touched else { return nil }
                    return AdapterPayload.parseISO8601(s)
                }
                var latestTouched: Date? {
                    guard let s = latest_touched else { return nil }
                    return AdapterPayload.parseISO8601(s)
                }

                private static func parseISO8601(_ s: String) -> Date? {
                    let fmt = ISO8601DateFormatter()
                    fmt.timeZone = TimeZone(secondsFromGMT: 0)
                    fmt.formatOptions = [.withInternetDateTime]
                    return fmt.date(from: s)
                }
            }

            do {
                let dec = JSONDecoder()
                let payload = try dec.decode(AdapterPayload.self, from: body)
                runResp.incorporateAdapterResult(payload)
            } catch {
                // If decode fails, and non-2xx, capture raw body text for visibility
                if !(200...299).contains(inner.statusCode), let s = String(data: body, encoding: .utf8) {
                    runResp.errors.append(s)
                }
            }
        }

        // Map inner status -> standard RunResponse.Status and finish
        let statusEnum: RunResponse.Status = (200...299).contains(inner.statusCode) ? .ok : .error
        runResp.finish(status: statusEnum, finishedAt: Date())

        // Serialize RunResponse to JSON and add helper fields (inner status/body) for visibility
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try enc.encode(runResp)
            if var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Ensure stats.earliest_touched and stats.latest_touched keys are present
                if var stats = obj["stats"] as? [String: Any] {
                    if stats["earliest_touched"] == nil {
                        stats["earliest_touched"] = NSNull()
                    }
                    if stats["latest_touched"] == nil {
                        stats["latest_touched"] = NSNull()
                    }
                    obj["stats"] = stats
                }

                obj["inner_status_code"] = inner.statusCode
                let finalData = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: finalData)
            }
        } catch {
            // Fall back to returning the RunResponse directly
        }

        return HTTPResponse.ok(json: runResp)
    }
}
