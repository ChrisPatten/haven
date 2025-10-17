# Enhanced OCR Testing Guide

This guide explains how to test the Unit 3.1 enhanced OCR implementation.

## Prerequisites

1. **hostagent running**: The hostagent service must be running on localhost:7090
2. **Python 3**: Python 3.6+ with the `requests` library installed
3. **Test image**: Any image file with text (PNG, JPG, HEIC, etc.)

## Setup

### 1. Install Python dependencies

```bash
pip install requests
```

### 2. Start hostagent

In one terminal:

```bash
cd /Users/chrispatten/workspace/haven/hostagent
swift run
```

Wait until you see the banner and "Starting server..." message.

## Running Tests

### Set Authentication Token

The hostagent requires authentication. Set the token to match your config:

```bash
export HOSTAGENT_AUTH_TOKEN="change-me"  # Use default, or your custom secret
```

### Basic Test (Fast mode, with layout)

```bash
python scripts/test_enhanced_ocr.py /path/to/your/image.png
```

### Accurate Recognition Mode

```bash
python scripts/test_enhanced_ocr.py /path/to/your/image.png accurate
```

### Without Layout Information

```bash
python scripts/test_enhanced_ocr.py /path/to/your/image.png fast false
```

## Expected Output

The test script will display:

1. **Extracted Text**: The OCR'd text content (first 500 characters)
2. **Detected Languages**: Languages identified in the text
3. **Recognition Level**: The mode used (fast or accurate)
4. **Bounding Boxes**: Count of text regions detected
5. **Layout Regions**: Detailed bounding box information with coordinates
6. **Timings**: Performance metrics (read time, OCR time, total time)

Example output:

```
============================================================
Testing OCR with:
  Image: screenshot.png
  Recognition Level: fast
  Include Layout: True
============================================================

✅ OCR Successful!

📝 Extracted Text (245 chars):
------------------------------------------------------------
Schedule plumber for Monday at 9am
Call dentist to reschedule appointment
...

🌐 Detected Languages: en
🎯 Recognition Level: fast

📦 Bounding Boxes: 12 boxes
📍 Layout Regions: 12 regions

Sample Regions (first 3):

  Region 1:
    Text: Schedule plumber for Monday at 9am...
    Confidence: 0.982
    BBox: x=0.123, y=0.456, w=0.567, h=0.034
    Language: en

⏱️  Timings:
    read: 15ms
    ocr: 162ms
    total: 177ms

============================================================
✅ Test completed successfully!
============================================================
```

## Testing Different Scenarios

### 1. Multi-language Text

Test with images containing multiple languages to verify language detection:

```bash
python scripts/test_enhanced_ocr.py multilingual_document.png accurate
```

### 2. Complex Layout

Test with images having complex layouts (tables, columns):

```bash
python scripts/test_enhanced_ocr.py complex_layout.png accurate true
```

### 3. Performance Testing

Compare fast vs. accurate mode performance:

```bash
# Fast mode
python scripts/test_enhanced_ocr.py large_image.png fast

# Accurate mode
python scripts/test_enhanced_ocr.py large_image.png accurate
```

## Troubleshooting

### Authentication Failed (401)

**Error**: `Authentication failed (401 Unauthorized)`

**Solution**: Set the auth token environment variable:
```bash
export HOSTAGENT_AUTH_TOKEN="change-me"  # Default from config
# Or if you changed it in your config:
export HOSTAGENT_AUTH_TOKEN="your-custom-secret"
```

### Connection Refused

**Error**: `Could not connect to hostagent at localhost:7090`

**Solution**: Make sure hostagent is running:
```bash
cd hostagent && swift run
```

### Image Not Found

**Error**: `Image file not found: /path/to/image.png`

**Solution**: Use absolute paths or verify the file exists:
```bash
ls -l /path/to/image.png
```

### OCR Failed

**Error**: `OCR processing failed`

**Possible causes**:
- Image format not supported (try converting to PNG/JPG)
- Image too large (try resizing)
- OCR timeout (increase timeout_ms in config)

## Configuration

The OCR module can be configured in `hostagent/Resources/default-config.yaml`:

```yaml
modules:
  ocr:
    enabled: true
    languages:
      - en
      - es  # Add more languages
    timeout_ms: 2000
    recognition_level: fast  # or 'accurate'
    include_layout: true
```

## API Reference

### Endpoint: POST /v1/ocr

**Request Body:**

```json
{
  "image_path": "/absolute/path/to/image.png",
  "recognition_level": "fast",  // optional: "fast" or "accurate"
  "include_layout": true         // optional: true or false
}
```

Or with base64 image data:

```json
{
  "image_data": "base64_encoded_image_data...",
  "recognition_level": "accurate",
  "include_layout": true
}
```

**Response:**

```json
{
  "ocr_text": "Full extracted text...",
  "ocr_boxes": [...],
  "regions": [
    {
      "text": "Text in this region",
      "bounding_box": {
        "x": 0.123,
        "y": 0.456,
        "width": 0.567,
        "height": 0.034
      },
      "confidence": 0.982,
      "detected_language": "en"
    }
  ],
  "detected_languages": ["en"],
  "recognition_level": "fast",
  "lang": "en",
  "tooling": {
    "vision": "macOS-14.x.x"
  },
  "timings_ms": {
    "read": 15,
    "ocr": 162,
    "total": 177
  }
}
```

## Next Steps

After validating Unit 3.1:

1. Test integration with existing collectors (iMessage, etc.)
2. Benchmark performance with various image sizes
3. Proceed to Unit 3.2 (Natural Language Entity Extraction)
