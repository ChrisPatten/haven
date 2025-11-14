import Foundation
import Entity
import HavenCore

/// Shared utility for merging enrichment data into documents across all collectors
/// Haven.app enrichment strategy:
/// 1. Include image data as inline text placeholders: [Image: <filename> | <caption> | <ocr_text>]
/// 2. Store captions and enrichment data in metadata.enrichment
/// 3. Don't send image files to gateway (business rule)
public struct EnrichmentMerger {
    
    /// Merge enrichment data from EnrichedDocument into a dictionary document
    /// - Parameters:
    ///   - baseDocument: The base document dictionary
    ///   - enrichedDocument: The enriched document with entities and image enrichment
    ///   - imageAttachments: Optional array of image attachment dictionaries (for filename extraction)
    /// - Returns: Updated document dictionary with enrichment data merged in
    public static func mergeEnrichmentIntoDocument(
        _ baseDocument: [String: Any],
        _ enrichedDocument: EnrichedDocument,
        imageAttachments: [[String: Any]]? = nil
    ) -> [String: Any] {
        var document = baseDocument
        var metadata = document["metadata"] as? [String: Any] ?? [:]
        var enrichmentData = (metadata["enrichment"] as? [String: Any]) ?? [:]
        
        // Build enrichment data combining entities and image enrichment
        var entitiesArray: [[String: Any]] = []
        var imageCaptions: [String] = []
        var imageEnrichments: [[String: Any]] = []
        
        // Add entity enrichment
        if let entities = enrichedDocument.documentEnrichment?.entities, !entities.isEmpty {
            for entity in entities {
                entitiesArray.append([
                    "type": entity.type.rawValue,
                    "text": entity.text,
                    "confidence": entity.confidence,
                    "range": entity.range  // Entity.range is [Int] (location, length)
                ])
            }
        }
        
        // Process image enrichments
        var imagePlaceholders: [String] = []
        if !enrichedDocument.imageEnrichments.isEmpty {
            let attachments = imageAttachments ?? []
            
            for (index, imageEnrichment) in enrichedDocument.imageEnrichments.enumerated() {
                let filename = attachments.indices.contains(index) ? 
                    (attachments[index]["filename"] as? String ?? "image") : "image"
                
                // Build image enrichment record for metadata
                var imgEnrichment: [String: Any] = ["filename": filename]
                
                // Collect caption and OCR for placeholder
                var caption = ""
                var ocrText = ""
                
                // Add caption to enrichment and collect for placeholder
                if let captionText = imageEnrichment.caption {
                    imgEnrichment["caption"] = captionText
                    caption = captionText
                    imageCaptions.append(captionText)
                }
                
                // Add OCR data to enrichment and collect for placeholder
                if let ocr = imageEnrichment.ocr {
                    imgEnrichment["ocr"] = [
                        "text": ocr.ocrText,
                        "recognition_level": ocr.recognitionLevel ?? "accurate",
                        "lang": ocr.lang
                    ]
                    ocrText = ocr.ocrText
                }
                
                // Add face detection data to enrichment
                if let faces = imageEnrichment.faces {
                    imgEnrichment["faces"] = [
                        "count": faces.faces.count,
                        "detections": faces.faces.map { face in
                            [
                                "confidence": face.confidence,
                                "bounds": [
                                    "x": face.boundingBox.x,
                                    "y": face.boundingBox.y,
                                    "width": face.boundingBox.width,
                                    "height": face.boundingBox.height
                                ]
                            ]
                        }
                    ]
                }
                
                imageEnrichments.append(imgEnrichment)
                
                // Build image placeholder: [Image: <filename> | <caption> | <ocr>]
                var parts: [String] = [filename]
                if !caption.isEmpty {
                    parts.append(caption)
                }
                if !ocrText.isEmpty {
                    parts.append(ocrText)
                }
                let placeholder = "[Image: \(parts.joined(separator: " | "))]"
                imagePlaceholders.append(placeholder)
            }
        }
        
        // Update document text to include image placeholders
        if !imagePlaceholders.isEmpty {
            if var text = document["text"] as? String, !text.isEmpty {
                text = text + "\n" + imagePlaceholders.joined(separator: "\n")
                document["text"] = text
            }
        }
        
        // Update metadata with enrichment data
        if !entitiesArray.isEmpty {
            enrichmentData["entities"] = entitiesArray
        }
        if !imageEnrichments.isEmpty {
            enrichmentData["images"] = imageEnrichments
        }
        if !imageCaptions.isEmpty {
            enrichmentData["captions"] = imageCaptions
        }
        
        if !enrichmentData.isEmpty {
            metadata["enrichment"] = enrichmentData
            document["metadata"] = metadata
        }
        
        return document
    }
}

