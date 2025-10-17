import Foundation

struct MultipartParser {
    struct FilePart {
        let filename: String?
        let data: Data
        let contentType: String?
    }

    struct Result {
        var filePart: FilePart?
        var languages: [String] = []
    }

    let boundary: String

    func parse(_ body: Data) throws -> Result {
        var result = Result()
        let boundaryData = Data("--\(boundary)".utf8)
        let closingBoundaryData = Data("--\(boundary)--".utf8)
        let delimiter = Data("\r\n\r\n".utf8)

        var searchRange = body.startIndex..<body.endIndex
        while let range = body.range(of: boundaryData, options: [], in: searchRange) {
            var partStart = range.upperBound
            if partStart < body.endIndex, body[partStart] == 13 { // \r
                let next = body.index(after: partStart)
                if next < body.endIndex, body[next] == 10 {
                    partStart = body.index(after: next)
                }
            }

            guard partStart < body.endIndex else { break }
            if body.distance(from: partStart, to: body.endIndex) >= 2 {
                let dash1 = body[partStart]
                let dash2 = body[body.index(after: partStart)]
                if dash1 == 45, dash2 == 45 { // "--"
                    break
                }
            }

            let nextBoundaryRange = body.range(of: boundaryData, options: [], in: partStart..<body.endIndex)
            let closingRange = body.range(of: closingBoundaryData, options: [], in: partStart..<body.endIndex)
            let endIndex = nextBoundaryRange?.lowerBound ?? closingRange?.lowerBound ?? body.endIndex

            if partStart >= endIndex {
                searchRange = endIndex..<body.endIndex
                continue
            }

            var part = body.subdata(in: partStart..<endIndex)
            let crlfData = Data("\r\n".utf8)
            if part.count >= crlfData.count && part.suffix(crlfData.count) == crlfData {
                part.removeLast(2)
            }

            guard let headerRange = part.range(of: delimiter) else {
                searchRange = endIndex..<body.endIndex
                continue
            }

            let headerData = part.subdata(in: part.startIndex..<headerRange.lowerBound)
            let bodyData = part.subdata(in: headerRange.upperBound..<part.endIndex)

            guard let headerString = String(data: headerData, encoding: .utf8) else {
                searchRange = endIndex..<body.endIndex
                continue
            }

            var filename: String?
            var name: String?
            var contentType: String?

            let headerLines = headerString.components(separatedBy: "\r\n")
            for line in headerLines {
                let lower = line.lowercased()
                if lower.hasPrefix("content-disposition") {
                    let segments = line.components(separatedBy: ";")
                    for segment in segments {
                        let trimmed = segment.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("name=") {
                            name = trimmed.replacingOccurrences(of: "name=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        } else if trimmed.hasPrefix("filename=") {
                            filename = trimmed.replacingOccurrences(of: "filename=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        }
                    }
                } else if lower.hasPrefix("content-type") {
                    contentType = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
                }
            }

            if name == "languages" {
                if let text = String(data: bodyData, encoding: .utf8) {
                    result.languages = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            } else if name == "file" || filename != nil {
                result.filePart = FilePart(filename: filename, data: bodyData, contentType: contentType)
            }

            if let next = nextBoundaryRange {
                searchRange = next.lowerBound..<body.endIndex
            } else {
                break
            }
        }
        return result
    }
}
