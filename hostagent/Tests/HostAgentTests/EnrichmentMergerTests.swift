import XCTest
import HostAgent
import HavenCore

final class EnrichmentMergerTests: XCTestCase {
    func testTokenReplacementWithCaption() {
        // Given: Document with token and attachment with caption
        let baseDocument: [String: Any] = [
            "content": [
                "data": "Here is an image: {IMG:abc123}"
            ],
            "metadata": [
                "attachments": [
                    [
                        "id": "abc123",
                        "caption": ["text": "A beautiful sunset", "model": "test"],
                        "filename": "sunset.jpg"
                    ]
                ]
            ]
        ]
        
        let enrichedDocument = EnrichedDocument(
            documentEnrichment: nil,
            imageEnrichments: []
        )
        
        // When: Merge enrichment
        let result = EnrichmentMerger.mergeEnrichmentIntoDocument(baseDocument, enrichedDocument)
        
        // Then: Token is replaced with slug containing caption
        let content = result["content"] as? [String: Any]
        let text = content?["data"] as? String
        XCTAssertEqual(text, "Here is an image: [Image: A beautiful sunset | sunset.jpg]")
    }
    
    func testTokenReplacementWithoutCaption() {
        // Given: Document with token and attachment without caption
        let baseDocument: [String: Any] = [
            "content": [
                "data": "Image here: {IMG:def456}"
            ],
            "metadata": [
                "attachments": [
                    [
                        "id": "def456",
                        "filename": "photo.png"
                    ]
                ]
            ]
        ]
        
        let enrichedDocument = EnrichedDocument(
            documentEnrichment: nil,
            imageEnrichments: []
        )
        
        // When: Merge enrichment
        let result = EnrichmentMerger.mergeEnrichmentIntoDocument(baseDocument, enrichedDocument)
        
        // Then: Token is replaced with slug using "No caption"
        let content = result["content"] as? [String: Any]
        let text = content?["data"] as? String
        XCTAssertEqual(text, "Image here: [Image: No caption | photo.png]")
    }
    
    func testTokenReplacementWithHash() {
        // Given: Document with token and attachment with hash (no filename)
        let baseDocument: [String: Any] = [
            "content": [
                "data": "Embedded image: {IMG:md5hash}"
            ],
            "metadata": [
                "attachments": [
                    [
                        "id": "md5hash",
                        "hash": "a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3",
                        "caption": ["text": "A cat", "model": "test"]
                    ]
                ]
            ]
        ]
        
        let enrichedDocument = EnrichedDocument(
            documentEnrichment: nil,
            imageEnrichments: []
        )
        
        // When: Merge enrichment
        let result = EnrichmentMerger.mergeEnrichmentIntoDocument(baseDocument, enrichedDocument)
        
        // Then: Token is replaced with slug using hash
        let content = result["content"] as? [String: Any]
        let text = content?["data"] as? String
        XCTAssertEqual(text, "Embedded image: [Image: A cat | a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3]")
    }
    
    func testMultipleTokensReplaced() {
        // Given: Document with multiple tokens
        let baseDocument: [String: Any] = [
            "content": [
                "data": "First: {IMG:id1} and second: {IMG:id2}"
            ],
            "metadata": [
                "attachments": [
                    [
                        "id": "id1",
                        "filename": "first.jpg",
                        "caption": ["text": "First image", "model": "test"]
                    ],
                    [
                        "id": "id2",
                        "filename": "second.png",
                        "caption": ["text": "Second image", "model": "test"]
                    ]
                ]
            ]
        ]
        
        let enrichedDocument = EnrichedDocument(
            documentEnrichment: nil,
            imageEnrichments: []
        )
        
        // When: Merge enrichment
        let result = EnrichmentMerger.mergeEnrichmentIntoDocument(baseDocument, enrichedDocument)
        
        // Then: All tokens are replaced with slugs
        let content = result["content"] as? [String: Any]
        let text = content?["data"] as? String
        XCTAssertEqual(text, "First: [Image: First image | first.jpg] and second: [Image: Second image | second.png]")
    }
    
    func testNoTokensNoChange() {
        // Given: Document without tokens
        let baseDocument: [String: Any] = [
            "content": [
                "data": "Just text, no images"
            ],
            "metadata": [:]
        ]
        
        let enrichedDocument = EnrichedDocument(
            documentEnrichment: nil,
            imageEnrichments: []
        )
        
        // When: Merge enrichment
        let result = EnrichmentMerger.mergeEnrichmentIntoDocument(baseDocument, enrichedDocument)
        
        // Then: Content remains unchanged
        let content = result["content"] as? [String: Any]
        let text = content?["data"] as? String
        XCTAssertEqual(text, "Just text, no images")
    }
}
