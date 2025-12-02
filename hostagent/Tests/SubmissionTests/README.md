# DocumentSubmitter Tests

This test suite verifies that document conversion preserves critical metadata through the enrichment and submission pipeline.

## Test Coverage

### `DocumentSubmitterTests.swift`

Tests for the Swift-side conversion logic:

1. **`testConvertToEmailDocumentPayloadPreservesThreadData`**
   - Verifies that thread payload is stored in `additionalMetadata["thread_payload"]`
   - Ensures thread data survives the conversion from `CollectorDocument` to `EmailDocumentPayload`

2. **`testConvertToEmailDocumentPayloadPreservesPeopleData`**
   - Verifies that people array is stored in `additionalMetadata["people_payload"]`
   - Ensures people data can be parsed back correctly

3. **`testConvertToEmailDocumentPayloadPreservesOriginalMetadata`**
   - Verifies that original iMessage metadata structure is stored in `additionalMetadata["original_metadata"]`
   - Ensures iMessage-specific fields like `source.imessage.chat_guid` are preserved

4. **`testThreadIdGenerationIsDeterministic`**
   - Verifies that deterministic UUID generation from thread external_id is consistent
   - Ensures same external_id always produces same UUID

## Running Tests

### Swift Tests
```bash
# Run all SubmissionTests
swift test --filter DocumentSubmitterTests

# Run specific test
swift test --filter DocumentSubmitterTests.testConvertToEmailDocumentPayloadPreservesThreadData
```

### Python Tests
```bash
# Run gateway metadata preservation tests
pytest tests/test_gateway_metadata_preservation.py -v

# Run specific test
pytest tests/test_gateway_metadata_preservation.py::test_gateway_preserves_original_imessage_metadata -v
```

## What These Tests Prevent

These tests ensure that:

1. **Thread ID Regression**: Thread data is never lost during conversion, preventing the issue where `thread_id` was `NULL` in the database
2. **People Data Regression**: Sender and participant information is preserved through the pipeline
3. **Metadata Structure Regression**: iMessage-specific metadata (like `chat_guid`) is preserved instead of being converted to generic email-style metadata
4. **Gateway Extraction Regression**: The gateway correctly extracts and uses original metadata when present

## Integration with CI

These tests should be run as part of the CI pipeline to catch regressions before they reach production.

