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
                        "language": ocr.lang
                    ]
                    
                    // Add regions if available (bounding boxes)
                    if let regions = ocr.regions, !regions.isEmpty {
                        let regionDicts: [[String: Any]] = regions.map { region in
                            return [
                                "text": region.text,
                                "bounding_box": [
                                    "x": region.boundingBox.x,
                                    "y": region.boundingBox.y,
                                    "width": region.boundingBox.width,
                                    "height": region.boundingBox.height
                                ] as [String: Any],
                                "confidence": region.confidence,
                                "detected_language": region.detectedLanguage ?? ocr.lang
                            ] as [String: Any]
                        }
                        ocrData["regions"] = regionDicts
                    } else if !ocr.ocrBoxes.isEmpty {
                        let regionDicts: [[String: Any]] = ocr.ocrBoxes.map { box in
                            let bbox = box.bbox
                            let x = bbox.count > 0 ? bbox[0] : 0
                            let y = bbox.count > 1 ? bbox[1] : 0
                            let w = bbox.count > 2 ? bbox[2] : 0
                            let h = bbox.count > 3 ? bbox[3] : 0
                            return [
                                "text": box.text,
                                "bounding_box": [
                                    "x": x,
                                    "y": y,
                                    "width": w,
                                    "height": h
                                ] as [String: Any],
                                "confidence": box.confidence ?? 0.9,
                                "detected_language": ocr.lang
                            ] as [String: Any]
                        }
                        ocrData["regions"] = regionDicts
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
            }
            
            // Update metadata with enriched attachments
            if !attachments.isEmpty {
                metadata["attachments"] = attachments
            }
        }
        
        // Replace image tokens with slugs in content, ensuring positional context and single occurrence per image
        if var content = document["content"] as? [String: Any],
           var text = content["data"] as? String, !text.isEmpty {
            // Build id → slug map from attachments
            var idToSlug: [String: String] = [:]
            if let attachments = (metadata["attachments"] as? [[String: Any]]) {
                for attachment in attachments {
                    guard let attachmentId = attachment["id"] as? String else { continue }
                    
                    // Determine filename or hash
                    let filenameOrHash: String = {
                        if let filename = attachment["filename"] as? String, !filename.isEmpty {
                            return filename
                        }
                        if let path = attachment["path"] as? String, !path.isEmpty {
                            // Use basename of path
                            if let last = path.split(separator: "/").last {
                                return String(last)
                            }
                            return path
                        }
                        if let hash = attachment["hash"] as? String, !hash.isEmpty {
                            return hash
                        }
                        return "image"
                    }()
                    
                    // Determine caption with fallback
                    var captionText = "No caption"
                    if let caption = attachment["caption"] as? [String: Any],
                       let ctext = caption["text"] as? String, !ctext.isEmpty {
                        captionText = ctext
                    }
                    
                    let slug = "[Image: \(captionText) | \(filenameOrHash)]"
                    idToSlug[attachmentId] = slug
                }
            }
            
            // Perform replacements for all known tokens
            if !idToSlug.isEmpty {
                for (attachmentId, slug) in idToSlug {
                    let token = "{IMG:\(attachmentId)}"
                    if text.contains(token) {
                        text = text.replacingOccurrences(of: token, with: slug)
                    }
                }
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

