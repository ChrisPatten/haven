# VCF Contacts Collector

The contacts collector in hostagent now supports importing contacts from VCF (vCard) files in addition to the macOS Contacts system application.

## Using VCF Directory Import

To import contacts from a directory containing VCF files, specify the directory path when making a request to the contacts collector endpoint.

### Request Format

```json
POST /v1/collectors/contacts:run

{
  "mode": "real",
  "collector_options": {
    "vcf_directory": "/path/to/vcf/directory"
  }
}
```

### Parameters

- `mode`: `"real"` or `"simulate"` (real mode required for actual VCF import)
- `collector_options`: Object containing collector-specific options
  - `vcf_directory`: Absolute path to a directory containing `.vcf` files

### Example Request

```bash
curl -X POST http://localhost:8071/v1/collectors/contacts:run \
  -H "Content-Type: application/json" \
  -d '{
    "mode": "real",
    "collector_options": {
      "vcf_directory": "/Users/username/Contacts"
    }
  }'
```

## Supported VCard Properties

The VCF parser supports the following vCard properties:

- **FN** (Formatted Name): Display name
- **N** (Name): Structured name (family;given;middle;prefix;suffix)
- **ORG** (Organization): Organization name
- **EMAIL** (Email Address): Email addresses
- **TEL** (Telephone): Phone numbers
- **URL** (URL): Website URLs
- **NICKNAME** (Nickname): Nicknames
- **PHOTO** (Photo): Contact photos (base64 encoded, generates photo hash)

## Behavior

1. If `vcf_directory` is specified in `collector_options`, contacts are loaded from VCF files in that directory
2. All `.vcf` files in the specified directory are processed
3. If `vcf_directory` is not specified, the system attempts to load contacts from macOS Contacts (default behavior)
4. The `limit` parameter can be used to cap the number of contacts imported
5. All contacts are submitted to the gateway for indexing

## Response

The response format is the same as standard collector responses:

```json
{
  "scanned": 42,
  "matched": 40,
  "submitted": 40,
  "skipped": 2,
  "batches": 1,
  "warnings": [],
  "errors": []
}
```

## Implementation Notes

- VCF files are expected to be UTF-8 encoded
- The parser handles both simple and complex vCard formats
- Base64-encoded photos are converted to SHA256 hashes for storage
- Invalid VCF entries are logged as warnings and skipped
- Contacts are submitted to the gateway in batches (default batch size: 500)
