# Quick Start: Entity Extraction

## Start the Server

```bash
cd /Users/chrispatten/workspace/haven/hostagent
swift run
```

## Test Entity Extraction

### Option 1: Use the Test Script
```bash
python /Users/chrispatten/workspace/haven/scripts/test_entity_extraction.py
```

### Option 2: Manual cURL Test
```bash
# Simple entity extraction
curl -X POST http://localhost:7090/v1/entities \
  -H "Content-Type: application/json" \
  -H "x-auth: changeme" \
  -d '{
    "text": "Meet John Smith at Apple Park on Monday"
  }'

# With entity type filtering
curl -X POST http://localhost:7090/v1/entities \
  -H "Content-Type: application/json" \
  -H "x-auth: changeme" \
  -d '{
    "text": "Steve Jobs founded Apple in Cupertino",
    "enabled_types": ["person"]
  }'
```

### Option 3: OCR with Entity Extraction
```bash
curl -X POST http://localhost:7090/v1/ocr \
  -H "Content-Type: application/json" \
  -H "x-auth: changeme" \
  -d '{
    "image_path": "/path/to/your/image.jpg",
    "extract_entities": true
  }'
```

## Configuration

Edit `hostagent/Resources/default-config.yaml`:

```yaml
modules:
  entity:
    enabled: true
    types:
      - person
      - organization
      - place
    min_confidence: 0.0
```

## Expected Response

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

## Troubleshooting

### Server won't start
- Check if port 7090 is available: `lsof -i :7090`
- Check config file exists: `ls hostagent/Resources/default-config.yaml`

### "Entity module is disabled" error
- Ensure `modules.entity.enabled: true` in config
- Restart the server after config changes

### No entities found
- Check the text contains recognizable entity types
- Try lowering `min_confidence` threshold
- Entity extraction works best with proper nouns

## Implementation Files

- **Service:** `hostagent/Sources/Entity/EntityService.swift`
- **Handler:** `hostagent/Sources/HostHTTP/Handlers/EntityHandler.swift`
- **Config:** `hostagent/Sources/HavenCore/Config.swift`
- **Tests:** `scripts/test_entity_extraction.py`
- **Docs:** `hostagent/Sources/Entity/README.md`
