import Foundation
import Vision
import CoreGraphics
import ImageIO

@main
struct Imdesc {
    static func main() throws {
        // Parse command-line arguments
        var imagePath: String?
        var formatJson = false
        
        var i = 1
        while i < CommandLine.arguments.count {
            let arg = CommandLine.arguments[i]
            if arg == "--format" && i + 1 < CommandLine.arguments.count {
                let format = CommandLine.arguments[i + 1]
                if format == "json" {
                    formatJson = true
                }
                i += 2
            } else {
                imagePath = arg
                i += 1
            }
        }
        
        guard let imagePath = imagePath else {
            FileHandle.standardError.write(Data("Usage: imdesc [--format json] <image_path>\n".utf8))
            exit(1)
        }

        let imageURL = URL(fileURLWithPath: imagePath)

        // Validate image dimensions before processing
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let width = imageProperties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = imageProperties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0 && height > 0 else {
            // Return empty result for invalid/zero-dimension images
            let emptyPayload: [String: Any] = [
                "text": "",
                "boxes": [],
                "entities": [
                    "dates": [],
                    "phones": [],
                    "urls": [],
                    "addresses": [],
                ],
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: emptyPayload, options: [])
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
            return
        }

        var lines: [String] = []
        var boxes: [[String: Double]] = []

        let textRequest = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                lines.append(candidate.string)

                let rect = observation.boundingBox
                boxes.append([
                    "x": Double(rect.origin.x),
                    "y": Double(rect.origin.y),
                    "w": Double(rect.size.width),
                    "h": Double(rect.size.height),
                ])
            }
        }

        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        let handler = try VNImageRequestHandler(url: imageURL)
        try handler.perform([textRequest])

        let joinedText = lines.joined(separator: "\n")

        var entities: [String: [String]] = [
            "dates": [],
            "phones": [],
            "urls": [],
            "addresses": [],
        ]

        if !joinedText.isEmpty {
            let types: [(NSTextCheckingResult.CheckingType, String)] = [
                (.date, "dates"),
                (.phoneNumber, "phones"),
                (.link, "urls"),
                (.address, "addresses"),
            ]

            for (type, key) in types {
                do {
                    let detector = try NSDataDetector(types: type.rawValue)
                    let matches = detector.matches(in: joinedText, options: [], range: NSRange(joinedText.startIndex..., in: joinedText))
                    entities[key] = matches.map { (joinedText as NSString).substring(with: $0.range) }
                } catch {
                    continue
                }
            }
        }

        let payload: [String: Any] = [
            "text": joinedText,
            "boxes": boxes,
            "entities": entities,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
    }
}
