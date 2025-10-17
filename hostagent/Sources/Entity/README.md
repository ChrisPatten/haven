# Entity Extraction Module

The Entity Extraction module uses Apple's NaturalLanguage framework to identify and extract named entities from text.

## Features

- **Entity Types**: Person, Organization, Place
- **Confidence Filtering**: Configurable minimum confidence threshold
- **Standalone Endpoint**: `/v1/entities` for direct entity extraction
- **OCR Integration**: Automatic entity extraction from OCR results

## Configuration

Add to `hostagent/Resources/default-config.yaml`:

```yaml
modules:
  entity:
    enabled: true
    types:
      - person
      - organization
      - place
    min_confidence: 0.0  # Range: 0.0-1.0
```

## API Usage

### Standalone Entity Extraction

Extract entities from any text:

```bash
curl -X POST http://localhost:7090/v1/entities \
  -H "Content-Type: application/json" \
  -H "x-auth: changeme" \
  -d '{
    "text": "Meet John Smith at Apple Park on Monday"
  }'
```

Response:
```json
{
  "entities": [
    {
      "text": "John Smith",
      "type": "person",
      "range": [5, 15],
      "confidence": 1.0
    },
    {
      "text": "Apple Park",
      "type": "place",
      "range": [19, 29],
      "confidence": 1.0
    }
  ],
  "total_entities": 2,
  "timings_ms": {
    "total": 12
  }
}
```

### OCR with Entity Extraction

Extract entities from OCR'd image text:

```bash
curl -X POST http://localhost:7090/v1/ocr \
  -H "Content-Type: application/json" \
  -H "x-auth: changeme" \
  -d '{
    "image_path": "/path/to/image.jpg",
    "extract_entities": true
  }'
```

Response includes both OCR results and extracted entities:
```json
{
  "ocr_text": "Schedule meeting with Sarah Johnson at Microsoft...",
  "ocr_boxes": [...],
  "entities": [
    {
      "text": "Sarah Johnson",
      "type": "person",
      "range": [22, 35],
      "confidence": 1.0
    },
    {
      "text": "Microsoft",
      "type": "organization",
      "range": [39, 48],
      "confidence": 1.0
    }
  ]
}
```

### Optional Parameters

Override default configuration per request:

```bash
curl -X POST http://localhost:7090/v1/entities \
  -H "Content-Type: application/json" \
  -H "x-auth: changeme" \
  -d '{
    "text": "Steve Jobs founded Apple in Cupertino.",
    "enabled_types": ["person"],
    "min_confidence": 0.8
  }'
```

## Testing

Run the test script to validate functionality:

```bash
# Start hostagent
cd hostagent && swift run

# In another terminal
python scripts/test_entity_extraction.py
```

## Implementation Details

- **Framework**: Apple NaturalLanguage (`NLTagger`)
- **Tag Scheme**: `.nameType`
- **Entity Mapping**:
  - `.personalName` → `person`
  - `.organizationName` → `organization`
  - `.placeName` → `place`
- **Confidence**: NLTagger doesn't provide confidence scores, so all matches return 1.0

## Limitations

- Currently supports Person, Organization, and Place entity types
- Date, Time, and Address extraction planned for future enhancement
- Confidence scores are fixed at 1.0 (NaturalLanguage limitation)
- Best performance with English text

## Future Enhancements

- Date/time entity extraction using NSDataDetector
- Custom entity type training
- Multi-language support
- Relationship extraction between entities
