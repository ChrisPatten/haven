# NER Preprocessing Design Proposal: HostAgent Framework

## Executive Summary

This design proposes a comprehensive Named Entity Recognition (NER) preprocessing module for Haven.app that extends the existing hostagent framework. The module leverages native macOS frameworks (NaturalLanguage, Vision, Contacts, CoreLocation) to extract, normalize, and canonicalize entities from text artifacts before they are sent to the Gateway for intent processing.

**Key Features:**
- **Language Detection**: Multi-language support using `NLLanguageRecognizer`
- **Entity Extraction**: Extended entity types using `NLTagger` and pattern matching
- **Text Normalization**: Signature removal, quoted content stripping, HTML-to-text conversion
- **Entity Canonicalization**: Contact matching, location geocoding, date/time normalization
- **OCR Integration**: Entity extraction from OCR'd images and PDFs
- **Privacy-First**: All processing occurs locally on the device

## 1. Overview

### 1.1 Purpose

The NER Preprocessing module extracts structured entities from heterogeneous text artifacts (messages, emails, notes, OCR text) using native macOS frameworks. It prepares entities for downstream intent processing by normalizing values, resolving ambiguities, and matching against system databases (Contacts, location services).

### 1.2 Integration with HostAgent Framework

The NER Preprocessing module extends the existing hostagent architecture:

```
Haven.app Collectors
    │
    ├─→ iMessage Collector
    ├─→ Email Collector
    ├─→ Notes Collector
    └─→ LocalFS Collector
            │
            └─→ NERPreprocessor (NEW)
                    │
                    ├─→ LanguageDetector
                    ├─→ TextNormalizer (extends EmailBodyExtractor)
                    ├─→ EntityExtractor (extends EntityService)
                    ├─→ ContactMatcher
                    ├─→ LocationNormalizer
                    └─→ EntityCanonicalizer
                    │
                    └─→ EntitySet (serialized JSON)
                            │
                            └─→ Gateway API (with artifact)
```

### 1.3 Design Principles

1. **Extend Existing Services**: Build upon `EntityService`, `OCRService`, and `EmailBodyExtractor`
2. **Actor-Based Concurrency**: Use Swift actors for thread-safe operations
3. **Native Frameworks First**: Leverage macOS system frameworks before custom solutions
4. **Privacy-Preserving**: All processing occurs locally; no external API calls
5. **Modular Architecture**: Separate concerns into focused components
6. **Structured Logging**: Use `HavenLogger` for consistent logging patterns
7. **Error Handling**: Comprehensive error types with recovery strategies

## 2. Component Architecture

### 2.1 Module Structure

```
hostagent/Sources/NER/
├── NERPreprocessor.swift          # Main coordinator actor
├── LanguageDetector.swift          # Language detection wrapper
├── TextNormalizer.swift            # Text cleaning and normalization
├── EntityExtractor.swift           # Extended entity extraction
├── ContactMatcher.swift            # Contacts framework integration
├── LocationNormalizer.swift        # CoreLocation integration
├── EntityCanonicalizer.swift       # Value normalization
├── DateTimeResolver.swift          # Date/time parsing and resolution
├── PatternExtractor.swift          # Regex-based entity patterns
└── Models/
    ├── EntitySet.swift             # Complete entity extraction result
    ├── NormalizedText.swift        # Text normalization result
    └── ProcessingHints.swift       # Configuration hints
```

### 2.2 Core Components

#### 2.2.1 NERPreprocessor (`NERPreprocessor.swift`)

Main coordinator actor that orchestrates the NER preprocessing pipeline.

**Responsibilities:**
- Coordinate all preprocessing steps
- Manage async operations and error handling
- Aggregate results into `EntitySet`
- Provide health check and metrics

**Key Methods:**
```swift
public actor NERPreprocessor {
    private let logger: HavenLogger
    private let languageDetector: LanguageDetector
    private let textNormalizer: TextNormalizer
    private let entityExtractor: EntityExtractor
    private let contactMatcher: ContactMatcher
    private let locationNormalizer: LocationNormalizer
    private let entityCanonicalizer: EntityCanonicalizer
    private let dateTimeResolver: DateTimeResolver
    private let patternExtractor: PatternExtractor
    
    /// Main preprocessing entry point
    public func preprocess(
        text: String,
        ocrText: String? = nil,
        metadata: ChannelMetadata,
        hints: ProcessingHints? = nil
    ) async throws -> EntitySet
    
    /// Health check
    public func healthCheck() -> NERHealth
}
```

**Processing Flow:**
1. Language detection
2. Text normalization (signatures, quotes, HTML)
3. Entity extraction (NLTagger + patterns)
4. Contact matching (for person entities)
5. Location normalization (for location entities)
6. Date/time resolution (for date/time entities)
7. Entity canonicalization
8. Deduplication and merging

#### 2.2.2 LanguageDetector (`LanguageDetector.swift`)

Wrapper around `NLLanguageRecognizer` for language detection.

**Responsibilities:**
- Detect primary and secondary languages
- Provide confidence scores
- Handle multilingual text

**Key Methods:**
```swift
public actor LanguageDetector {
    private let recognizer: NLLanguageRecognizer
    
    public func detectLanguages(
        _ text: String,
        maxLanguages: Int = 3
    ) async -> [DetectedLanguage]
}

public struct DetectedLanguage: Codable {
    public let code: String  // BCP-47 language code
    public let confidence: Float  // 0.0-1.0
}
```

**Implementation:**
- Uses `NLLanguageRecognizer` with `processString(_:for:)`
- Returns top N languages with confidence scores
- Falls back to "en" if detection fails

#### 2.2.3 TextNormalizer (`TextNormalizer.swift`)

Extends `EmailBodyExtractor` functionality for general text normalization.

**Responsibilities:**
- Remove email signatures
- Strip quoted/forwarded content
- Convert HTML to plain text
- Remove boilerplate (legal footers, disclaimers)
- Preserve text offsets for evidence tracking

**Key Methods:**
```swift
public struct TextNormalizer {
    private let logger: HavenLogger
    private let emailBodyExtractor: EmailBodyExtractor
    
    public func normalize(
        _ text: String,
        source: TextSource,
        hints: ProcessingHints? = nil
    ) async -> NormalizedText
}

public enum TextSource {
    case email
    case imessage
    case note
    case ocr
    case file
}

public struct NormalizedText: Codable {
    public let cleanedText: String
    public let originalText: String
    public let removedSections: [RemovedSection]
    public let normalizationNotes: [String]
}

public struct RemovedSection: Codable {
    public let type: String  // "signature", "quoted", "boilerplate"
    public let startOffset: Int
    public let endOffset: Int
    public let preview: String
}
```

**Implementation:**
- Reuses `EmailBodyExtractor` for email-specific normalization
- Adds general-purpose signature detection (regex patterns)
- Strips quoted content using common patterns ("> ", "On ... wrote:")
- Removes legal boilerplate using keyword matching
- Tracks removed sections for evidence preservation

#### 2.2.4 EntityExtractor (`EntityExtractor.swift`)

Extends `EntityService` with additional entity types and pattern-based extraction.

**Responsibilities:**
- Extract entities using `NLTagger` (extends existing functionality)
- Extract entities using regex patterns (emails, phones, URLs, identifiers)
- Combine results from multiple sources
- Provide entity offsets and confidence scores

**Key Methods:**
```swift
public actor EntityExtractor {
    private let entityService: EntityService
    private let logger: HavenLogger
    
    public func extractEntities(
        from text: String,
        enabledTypes: [EntityType]? = nil,
        minConfidence: Float? = nil
    ) async throws -> [Entity]
    
    private func extractWithNLTagger(_ text: String) async -> [Entity]
    private func extractWithPatterns(_ text: String) async -> [Entity]
    private func mergeEntities(_ entities: [[Entity]]) -> [Entity]
}

// Extended EntityType enum
public enum EntityType: String, Codable, CaseIterable, Sendable {
    // Existing from EntityService
    case person
    case organization
    case place
    
    // New types
    case date
    case time
    case daterange
    case amount
    case currency
    case percentage
    case email
    case phone
    case url
    case address
    case identifier  // Invoice numbers, tracking codes, etc.
    case thing  // Products, services, topics
}
```

**Pattern-Based Extraction:**
- **Email**: RFC 5322 compliant regex
- **Phone**: E.164 format detection, US/International patterns
- **URL**: HTTP/HTTPS URL detection
- **Date**: Relative ("next Friday") and absolute date patterns
- **Time**: Time expressions ("3pm", "15:30")
- **Amount**: Currency amounts ("$100", "€50.00")
- **Identifier**: Invoice numbers, tracking codes, confirmation numbers

#### 2.2.5 ContactMatcher (`ContactMatcher.swift`)

Matches person entities against macOS Contacts database.

**Responsibilities:**
- Query Contacts framework for matching names
- Normalize person names to canonical forms
- Link entities to contact records (when available)
- Handle privacy permissions

**Key Methods:**
```swift
public actor ContactMatcher {
    private let store: CNContactStore
    private let logger: HavenLogger
    
    public func matchPerson(
        _ entity: Entity,
        text: String
    ) async throws -> MatchedPerson?
    
    public func normalizeName(_ name: String) -> String
}

public struct MatchedPerson: Codable {
    public let originalText: String
    public let normalizedName: String
    public let contactId: String?  // CNContact.identifier
    public let emailAddresses: [String]
    public let phoneNumbers: [String]
    public let confidence: Float
}
```

**Implementation:**
- Uses `CNContactStore` with `CNContactFetchRequest`
- Fuzzy matching using name similarity (Levenshtein distance)
- Handles "Full Disk Access" permission requirements
- Falls back gracefully if Contacts unavailable

#### 2.2.6 LocationNormalizer (`LocationNormalizer.swift`)

Normalizes location entities using CoreLocation and geocoding.

**Responsibilities:**
- Geocode addresses to coordinates
- Normalize location names (cities, states, countries)
- Resolve ambiguous locations
- Provide structured address components

**Key Methods:**
```swift
public actor LocationNormalizer {
    private let geocoder: CLGeocoder
    private let logger: HavenLogger
    
    public func normalizeLocation(
        _ entity: Entity,
        text: String
    ) async -> NormalizedLocation?
}

public struct NormalizedLocation: Codable {
    public let originalText: String
    public let normalizedName: String
    public let addressComponents: AddressComponents?
    public let coordinates: Coordinates?
    public let confidence: Float
}

public struct AddressComponents: Codable {
    public let street: String?
    public let city: String?
    public let state: String?
    public let postalCode: String?
    public let country: String?
}

public struct Coordinates: Codable {
    public let latitude: Double
    public let longitude: Double
}
```

**Implementation:**
- Uses `CLGeocoder.geocodeAddressString(_:completionHandler:)`
- Handles both forward (address → coordinates) and reverse (coordinates → address) geocoding
- Caches results to avoid repeated API calls
- Respects rate limiting and errors gracefully

#### 2.2.7 DateTimeResolver (`DateTimeResolver.swift`)

Resolves date and time expressions to absolute ISO datetimes.

**Responsibilities:**
- Parse relative dates ("next Friday", "tomorrow")
- Parse absolute dates ("2024-01-15", "Jan 15")
- Parse time expressions ("3pm", "15:30")
- Resolve timezones
- Handle ambiguous dates

**Key Methods:**
```swift
public actor DateTimeResolver {
    private let logger: HavenLogger
    private let calendar: Calendar
    private let timeZone: TimeZone
    
    public func resolveDateTime(
        _ entity: Entity,
        text: String,
        referenceDate: Date,
        timeZoneHint: TimeZone?
    ) async -> ResolvedDateTime?
}

public struct ResolvedDateTime: Codable {
    public let originalText: String
    public let normalizedValue: String  // ISO 8601 datetime
    public let startDate: Date
    public let endDate: Date?  // For date ranges
    public let timeZone: String  // IANA timezone
    public let ambiguous: Bool
    public let resolutionBasis: String  // "text", "metadata", "timezone_hint"
}
```

**Implementation:**
- Uses `NSDataDetector` with `.date` type
- Parses relative dates using `Calendar.date(byAdding:to:)`
- Resolves timezones from text, metadata, or system default
- Handles ambiguous cases (e.g., "Monday" could be next or last Monday)

#### 2.2.8 EntityCanonicalizer (`EntityCanonicalizer.swift`)

Normalizes entity values to canonical forms.

**Responsibilities:**
- Normalize phone numbers to E.164 format
- Normalize URLs to canonical forms
- Normalize currency amounts to ISO 4217 codes
- Merge duplicate entities
- Generate normalized values for all entity types

**Key Methods:**
```swift
public actor EntityCanonicalizer {
    private let logger: HavenLogger
    
    public func canonicalize(
        _ entities: [Entity],
        text: String,
        metadata: ChannelMetadata
    ) async -> [CanonicalEntity]
}

public struct CanonicalEntity: Codable {
    public let entity: Entity
    public let normalizedValue: String
    public let canonicalType: String?  // E.164, ISO 4217, etc.
    public let mergedWith: [Entity]?  // If merged with other entities
}
```

**Implementation:**
- Phone normalization using libPhoneNumber (if available) or regex
- URL normalization (remove fragments, normalize paths)
- Currency conversion to ISO 4217 codes
- Entity deduplication based on normalized values and proximity

#### 2.2.9 PatternExtractor (`PatternExtractor.swift`)

Extracts entities using regex patterns for types not covered by NLTagger.

**Responsibilities:**
- Define regex patterns for each entity type
- Extract matches with offsets
- Provide confidence scores based on pattern quality
- Handle overlapping matches

**Key Methods:**
```swift
public actor PatternExtractor {
    private let patterns: [EntityType: [NSRegularExpression]]
    private let logger: HavenLogger
    
    public func extract(
        _ text: String,
        types: [EntityType]
    ) async -> [Entity]
    
    private func compilePatterns() -> [EntityType: [NSRegularExpression]]
}
```

**Pattern Definitions:**
- **Email**: `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}`
- **Phone**: `\+?1?[-.\s]?\(?[0-9]{3}\)?[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}`
- **URL**: `https?://[^\s]+`
- **Invoice**: `INV[-/]?[0-9]+`, `Invoice\s+#?[0-9]+`
- **Tracking**: `[0-9]{12,}`, `[A-Z]{2}[0-9]{9}[A-Z]{2}`

## 3. Data Models

### 3.1 EntitySet

Complete entity extraction result with all entity types and metadata.

```swift
public struct EntitySet: Codable {
    // Language detection
    public let detectedLanguages: [DetectedLanguage]
    
    // Entity arrays (empty if none found)
    public let people: [CanonicalEntity]
    public let organizations: [CanonicalEntity]
    public let places: [CanonicalEntity]
    public let dates: [CanonicalEntity]
    public let dateranges: [CanonicalEntity]
    public let amounts: [CanonicalEntity]
    public let contacts: [CanonicalEntity]  // emails, phones, URLs
    public let identifiers: [CanonicalEntity]
    public let things: [CanonicalEntity]
    
    // Document layout (if OCR)
    public let documentLayout: DocumentLayout?
    
    // Normalization metadata
    public let normalizationNotes: [String]
    public let processingTimestamps: ProcessingTimestamps
    
    // Provenance
    public let nerVersion: String
    public let nerFramework: String
}

public struct DocumentLayout: Codable {
    public let pages: [PageLayout]
}

public struct PageLayout: Codable {
    public let pageNumber: Int
    public let blocks: [BlockLayout]
}

public struct BlockLayout: Codable {
    public let blockId: String
    public let lines: [LineLayout]
    public let boundingBox: BoundingBox
}

public struct LineLayout: Codable {
    public let lineId: String
    public let words: [WordLayout]
    public let boundingBox: BoundingBox
}

public struct WordLayout: Codable {
    public let text: String
    public let boundingBox: BoundingBox
    public let confidence: Float?
}
```

### 3.2 Extended Entity Model

```swift
public struct Entity: Codable {
    // Existing fields
    public let text: String
    public let type: EntityType
    public let range: [Int]  // [startOffset, endOffset]
    public let confidence: Float
    
    // New fields
    public let normalizedValue: String?
    public let sourceLayer: String  // "text", "ocr", "metadata"
    public let page: Int?  // For OCR entities
    public let blockId: String?  // For OCR entities
    public let lineId: String?  // For OCR entities
    public let quoted: Bool?  // True if from quoted/forwarded content
    public let ambiguous: Bool?  // True if multiple resolutions possible
    public let resolutionBasis: String?  // "text", "metadata", "timezone_hint"
}
```

### 3.3 ProcessingHints

Configuration hints for preprocessing.

```swift
public struct ProcessingHints: Codable {
    public let languageHint: String?  // BCP-47 code
    public let timezoneHint: String?  // IANA timezone
    public let source: TextSource
    public let skipNormalization: Bool?  // Skip text cleaning
    public let enabledEntityTypes: [EntityType]?
    public let minConfidence: Float?
}
```

### 3.4 ChannelMetadata

Metadata about the source channel.

```swift
public struct ChannelMetadata: Codable {
    public let source: String  // "imessage", "email", "notes", etc.
    public let sender: String?
    public let recipients: [String]?
    public let threadId: String?
    public let subject: String?
    public let observedAt: Date
    public let timezone: TimeZone?
}
```

## 4. Integration Points

### 4.1 Collector Integration

Collectors call NER preprocessing before sending artifacts to Gateway:

```swift
// Example: iMessage Collector
let preprocessor = NERPreprocessor()
let hints = ProcessingHints(
    languageHint: nil,
    timezoneHint: TimeZone.current.identifier,
    source: .imessage,
    skipNormalization: false,
    enabledEntityTypes: nil,
    minConfidence: nil
)

let metadata = ChannelMetadata(
    source: "imessage",
    sender: message.sender,
    recipients: message.recipients,
    threadId: message.threadId,
    subject: nil,
    observedAt: message.date,
    timezone: TimeZone.current
)

let entitySet = try await preprocessor.preprocess(
    text: message.text,
    ocrText: nil,
    metadata: metadata,
    hints: hints
)

// Include entitySet in Gateway payload
let payload = ArtifactPayload(
    artifactId: message.id,
    text: message.text,
    entities: entitySet,  // Pre-processed entities
    // ... other fields
)
```

### 4.2 OCR Integration

OCR results are passed to NER preprocessing:

```swift
// After OCR processing
let ocrResult = try await ocrService.processImage(path: imagePath)

let entitySet = try await preprocessor.preprocess(
    text: "",  // No plain text
    ocrText: ocrResult.ocrText,
    metadata: metadata,
    hints: hints
)

// EntitySet includes documentLayout from OCR regions
```

### 4.3 Email Integration

Reuses `EmailBodyExtractor` for text normalization:

```swift
// TextNormalizer uses EmailBodyExtractor internally
let normalizer = TextNormalizer()
let normalized = await normalizer.normalize(
    email.bodyHTML ?? email.bodyPlainText ?? "",
    source: .email,
    hints: hints
)

// Then extract entities from normalized text
let entities = try await entityExtractor.extractEntities(
    from: normalized.cleanedText
)
```

## 5. Configuration

### 5.1 HostAgent Configuration

Add NER configuration to `hostagent/Resources/default-config.yaml`:

```yaml
modules:
  ner:
    enabled: true
    
    # Language detection
    language_detection:
      enabled: true
      max_languages: 3
    
    # Text normalization
    text_normalization:
      enabled: true
      remove_signatures: true
      remove_quoted_content: true
      remove_boilerplate: true
      html_to_text: true
    
    # Entity extraction
    entity_extraction:
      enabled_types:
        - person
        - organization
        - place
        - date
        - time
        - email
        - phone
        - url
        - amount
        - identifier
      min_confidence: 0.0
      use_patterns: true
      use_nltagger: true
    
    # Contact matching
    contact_matching:
      enabled: true
      fuzzy_threshold: 0.8  # Levenshtein similarity
      require_permission: true  # Fail gracefully if no Contacts permission
    
    # Location normalization
    location_normalization:
      enabled: true
      geocode_addresses: true
      cache_results: true
      cache_ttl_hours: 168  # 7 days
    
    # Date/time resolution
    date_time_resolution:
      enabled: true
      default_timezone: "America/Los_Angeles"  # or system default
      resolve_relative_dates: true
      handle_ambiguity: true
    
    # Entity canonicalization
    canonicalization:
      enabled: true
      normalize_phones: true
      normalize_urls: true
      normalize_currency: true
      merge_duplicates: true
      merge_threshold: 0.9  # Similarity for merging
```

### 5.2 Runtime Configuration

Configuration can be overridden per-request via `ProcessingHints`:

```swift
let hints = ProcessingHints(
    languageHint: "en",
    timezoneHint: "America/New_York",
    source: .email,
    skipNormalization: false,
    enabledEntityTypes: [.person, .date, .amount],
    minConfidence: 0.7
)
```

## 6. Error Handling

### 6.1 Error Types

```swift
public enum NERError: Error, LocalizedError {
    case noInput
    case languageDetectionFailed
    case textNormalizationFailed(String)
    case entityExtractionFailed(String)
    case contactMatchingFailed(String)
    case locationNormalizationFailed(String)
    case dateTimeResolutionFailed(String)
    case canonicalizationFailed(String)
    case permissionDenied(String)  // Contacts, Location permissions
    
    public var errorDescription: String? {
        switch self {
        case .noInput:
            return "No text provided for NER preprocessing"
        case .languageDetectionFailed:
            return "Failed to detect language"
        case .textNormalizationFailed(let details):
            return "Text normalization failed: \(details)"
        // ... other cases
        }
    }
}
```

### 6.2 Error Recovery

- **Partial Failures**: Continue processing other steps if one fails
- **Permission Denials**: Fall back gracefully (skip contact matching, location normalization)
- **Timeout**: Use shorter timeouts for real-time processing
- **Invalid Input**: Return empty EntitySet with error in normalizationNotes

## 7. Performance & Optimization

### 7.1 Performance Targets

- **Language Detection**: < 50ms per artifact
- **Text Normalization**: < 100ms per artifact
- **Entity Extraction**: < 200ms per artifact (NLTagger + patterns)
- **Contact Matching**: < 100ms per artifact (with caching)
- **Location Normalization**: < 500ms per artifact (with caching)
- **Total Pipeline**: < 1 second per artifact (P95)

### 7.2 Optimization Strategies

- **Caching**: Cache contact matches, location geocoding results
- **Lazy Loading**: Only load Contacts/Location services when needed
- **Batch Processing**: Process multiple entities in parallel
- **Early Exit**: Skip expensive operations if no entities of that type found
- **Async Operations**: Use async/await for I/O-bound operations

### 7.3 Resource Management

- **Memory**: Release large objects (OCR results, contact stores) after use
- **CPU**: Use appropriate QoS levels (`.userInitiated` for real-time, `.utility` for batch)
- **Network**: No network calls (all local processing)

## 8. Testing Strategy

### 8.1 Unit Tests

- Test each component independently
- Mock dependencies (Contacts, Location services)
- Test error handling and edge cases

### 8.2 Integration Tests

- Test full pipeline with sample artifacts
- Test with real Contacts database (with permission)
- Test OCR integration

### 8.3 Performance Tests

- Benchmark each component
- Measure end-to-end latency
- Test with large documents

## 9. Implementation Phases

### Phase 1: Core Infrastructure (MVP)

**Scope:**
- Extend `EntityService` with new entity types
- Implement `LanguageDetector`
- Implement `TextNormalizer` (extend `EmailBodyExtractor`)
- Basic `EntityExtractor` with pattern matching
- Simple `EntityCanonicalizer`

**Deliverables:**
- `NERPreprocessor` coordinator
- Language detection
- Text normalization
- Extended entity extraction (person, organization, place, email, phone, URL, date)
- Basic canonicalization

### Phase 2: Advanced Features

**Scope:**
- `ContactMatcher` with Contacts framework
- `LocationNormalizer` with CoreLocation
- `DateTimeResolver` with relative date parsing
- Advanced canonicalization (phone E.164, currency ISO 4217)
- Entity deduplication and merging

**Deliverables:**
- Contact matching
- Location geocoding
- Date/time resolution
- Full canonicalization
- Deduplication

### Phase 3: OCR Integration & Optimization

**Scope:**
- OCR text entity extraction
- Document layout tracking
- Performance optimization
- Caching layer
- Error recovery improvements

**Deliverables:**
- OCR entity extraction
- Layout tracking
- Performance optimizations
- Comprehensive caching

## 10. Migration from Existing Code

### 10.1 EntityService Extension

The existing `EntityService` will be extended rather than replaced:

```swift
// Existing EntityService remains for backward compatibility
public actor EntityService {
    // Existing methods unchanged
}

// New EntityExtractor wraps and extends EntityService
public actor EntityExtractor {
    private let entityService: EntityService
    
    // New methods for extended functionality
    public func extractEntities(...) async throws -> [Entity] {
        // Use EntityService for basic extraction
        let basicEntities = try await entityService.extractEntities(...)
        
        // Add pattern-based extraction
        let patternEntities = await patternExtractor.extract(...)
        
        // Merge and return
        return mergeEntities([basicEntities, patternEntities])
    }
}
```

### 10.2 Backward Compatibility

- Existing `EntityService` API remains unchanged
- New functionality available via `NERPreprocessor`
- Gradual migration path for collectors

## 11. Open Questions & Decisions Needed

### 11.1 Library Dependencies

- **libPhoneNumber**: Use for phone normalization, or implement regex-based solution?
- **Date Parsing**: Use `NSDataDetector` or custom parser for relative dates?

**Recommendation**: Start with `NSDataDetector` and regex, add libPhoneNumber if needed.

### 11.2 Caching Strategy

- **In-Memory Cache**: Use NSCache for contact/location results?
- **Persistent Cache**: Store cache in SQLite or file system?

**Recommendation**: Start with in-memory cache, add persistent cache if needed.

### 11.3 Permission Handling

- **Contacts Permission**: Require at startup or request on-demand?
- **Location Permission**: Always require or optional?

**Recommendation**: Request permissions on-demand, fail gracefully if denied.

### 11.4 Entity Confidence Scores

- **NLTagger**: Doesn't provide confidence (currently returns 1.0)
- **Pattern Matching**: How to assign confidence scores?

**Recommendation**: Use pattern quality heuristics (specificity, match length) for confidence.

## 12. References

- Intents Design Proposal (`documentation/intents-design-proposal.md`)
- HostAgent EntityService (`hostagent/Sources/Entity/EntityService.swift`)
- HostAgent OCRService (`hostagent/Sources/OCR/OCRService.swift`)
- HostAgent EmailBodyExtractor (`hostagent/Sources/Email/EmailBodyExtractor.swift`)
- Apple NaturalLanguage Framework Documentation
- Apple Vision Framework Documentation
- Apple Contacts Framework Documentation
- Apple CoreLocation Framework Documentation


