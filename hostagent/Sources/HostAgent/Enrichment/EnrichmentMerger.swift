import Foundation
import Entity
import HavenCore

/// Shared utility for merging enrichment data into documents across all collectors
/// Haven.app enrichment strategy:
/// 1. Include image data as inline text placeholders: [Image: <filename> | <caption> | <ocr_text>]
/// 2. Store enrichment data in metadata.attachments[].ocr/caption/vision (new schema)
/// 3. Store document-level entities in metadata.enrichment.entities[]
/// 4. Don't send image files to gateway (business rule)
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
        
        // Build document-level entity enrichment
        var entitiesArray: [[String: Any]] = []
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
        
        // Process image enrichments and merge into metadata.attachments[]
        var imagePlaceholders: [String] = []
        if !enrichedDocument.imageEnrichments.isEmpty {
            // Get existing attachments array from metadata (new schema format)
            var attachments = (metadata["attachments"] as? [[String: Any]]) ?? []
            
            // If attachments array is empty but we have imageAttachments, convert them
            if attachments.isEmpty, let imageAtts = imageAttachments {
                attachments = imageAtts
            }
            
            // Match enriched images to attachments by index
            for (index, imageEnrichment) in enrichedDocument.imageEnrichments.enumerated() {
                guard index < attachments.count else {
                    // Skip if index is out of bounds
                    continue
                }
                
                var attachment = attachments[index]
                let filename = attachment["filename"] as? String ?? 
                    (imageAttachments?[index]["filename"] as? String ?? "image")
                
                // Build OCR data
                if let ocr = imageEnrichment.ocr {
                    var ocrData: [String: Any] = [
                        "text": ocr.ocrText,
                        "confidence": ocr.recognitionLevel == "accurate" ? 0.95 : 0.85,
                        "language": ocr.lang ?? "en"
                    ]
                    
                    // Add regions if available (bounding boxes)
                    if let boxes = ocr.boxes, !boxes.isEmpty {
                        var regions: [[String: Any]] = []
                        for box in boxes {
                            regions.append([
                                "text": box.text,
                                "bounding_box": [
                                    "x": box.boundingBox.x,
                                    "y": box.boundingBox.y,
                                    "width": box.boundingBox.width,
                                    "height": box.boundingBox.height
                                ],
                                "confidence": box.confidence ?? 0.9,
                                "detected_language": ocr.lang ?? "en"
                            ])
                        }
                        ocrData["regions"] = regions
                    }
                    
                    attachment["ocr"] = ocrData
                }
                
                // Build caption data
                if let captionText = imageEnrichment.caption {
                    attachment["caption"] = [
                        "text": captionText,
                        "model": "hostagent-caption-v1",
                        "confidence": 0.85,
                        "generated_at": ISO8601DateFormatter().string(from: Date())
                    ]
                    imagePlaceholders.append("[Image: \(filename) | \(captionText)]")
                }
                
                // Build vision data (faces)
                if let faces = imageEnrichment.faces {
                    var visionData: [String: Any] = [:]
                    
                    if !faces.faces.isEmpty {
                        visionData["faces"] = faces.faces.map { face in
                            [
                                "bounding_box": [
                                    "x": face.boundingBox.x,
                                    "y": face.boundingBox.y,
                                    "width": face.boundingBox.width,
                                    "height": face.boundingBox.height
                                ],
                                "confidence": face.confidence,
                                "quality_score": face.confidence  // Use confidence as quality proxy
                            ]
                        }
                    }
                    
                    if !visionData.isEmpty {
                        attachment["vision"] = visionData
                    }
                }
                
                // Update attachment in array
                attachments[index] = attachment
                
                // Build image placeholder for text
                var parts: [String] = [filename]
                if let caption = attachment["caption"] as? [String: Any],
                   let captionText = caption["text"] as? String {
                    parts.append(captionText)
                }
                if let ocr = attachment["ocr"] as? [String: Any],
                   let ocrText = ocr["text"] as? String {
                    parts.append(ocrText)
                }
                if parts.count > 1 {
                let placeholder = "[Image: \(parts.joined(separator: " | "))]"
                imagePlaceholders.append(placeholder)
                }
            }
            
            // Update metadata with enriched attachments
            if !attachments.isEmpty {
                metadata["attachments"] = attachments
            }
        }
        
        // Update document text to include image placeholders
        if !imagePlaceholders.isEmpty {
            if var content = document["content"] as? [String: Any],
               var text = content["data"] as? String, !text.isEmpty {
                text = text + "\n" + imagePlaceholders.joined(separator: "\n")
                content["data"] = text
                document["content"] = content
            }
        }
        
        // Update metadata with document-level enrichment (entities only)
        if !entitiesArray.isEmpty {
            enrichmentData["entities"] = entitiesArray
        }
        
        if !enrichmentData.isEmpty {
            metadata["enrichment"] = enrichmentData
        }
        
        document["metadata"] = metadata
        
        return document
    }
}

