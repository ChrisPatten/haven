# Email Utilities

The Email module provides utilities for parsing .emlx files (macOS Mail.app format) and extracting metadata, classifying intent, and redacting PII.

## Overview

The Email module is implemented in Swift within the HostAgent and provides a set of HTTP endpoints for email processing:

- **Parsing**: Parse .emlx files to extract headers, body, and attachments
- **Metadata Extraction**: Extract structured metadata from parsed emails
- **Intent Classification**: Classify email intent (bill, receipt, appointment, etc.)
- **Noise Detection**: Identify promotional/spam emails
- **PII Redaction**: Remove sensitive information from text

## API Endpoints

All endpoints require the mail module to be enabled in the configuration.

### POST /v1/email/parse

Parse an .emlx file and return structured email data.

**Request:**
```json
{
  "path": "/path/to/email.emlx"
}
```

**Response:**
```json
{
  "messageId": "<abc@example.com>",
  "subject": "Your Receipt",
  "from": ["sender@example.com"],
  "to": ["recipient@example.com"],
  "cc": [],
  "bcc": [],
  "date": "2025-10-21T10:30:00Z",
  "inReplyTo": null,
  "references": [],
  "listUnsubscribe": null,
  "bodyPlainText": "Email body content...",
  "bodyHTML": null,
  "attachments": [],
  "headers": {
    "subject": "Your Receipt",
    "from": "sender@example.com",
    ...
  }
}
```

### POST /v1/email/metadata

Extract metadata from a parsed email message.

**Request:**
```json
{
  "messageId": "<abc@example.com>",
  "subject": "Your Receipt",
  "from": ["sender@example.com"],
  "to": ["recipient@example.com"],
  "date": "2025-10-21T10:30:00Z",
  "bodyPlainText": "Thank you for your purchase...",
  "attachments": []
}
```

**Response:**
```json
{
  "subject": "Your Receipt",
  "from": ["sender@example.com"],
  "to": ["recipient@example.com"],
  "cc": [],
  "date": "2025-10-21T10:30:00Z",
  "messageId": "<abc@example.com>",
  "inReplyTo": null,
  "references": [],
  "listUnsubscribe": null,
  "hasAttachments": false,
  "attachmentCount": 0,
  "bodyPreview": "Thank you for your purchase...",
  "isNoiseEmail": false,
  "intentClassification": {
    "primaryIntent": "receipt",
    "confidence": 0.85,
    "secondaryIntents": [],
    "extractedEntities": {
      "order_number": "ORD-12345"
    }
  }
}
```

### POST /v1/email/classify-intent

Classify the intent of email text.

**Request:**
```json
{
  "subject": "Your Monthly Bill",
  "body": "Please pay your invoice...",
  "sender": "billing@utility.com"
}
```

**Response:**
```json
{
  "primaryIntent": "bill",
  "confidence": 0.8,
  "secondaryIntents": [],
  "extractedEntities": {
    "amount": "$125.50"
  }
}
```

**Intent Types:**
- `bill`: Billing statements and invoices
- `receipt`: Payment confirmations and receipts
- `orderConfirmation`: Order confirmations and shipping notifications
- `appointment`: Appointment reminders and calendar events
- `actionRequired`: Emails requiring user action
- `notification`: General notifications
- `promotional`: Marketing and promotional content
- `newsletter`: Newsletter subscriptions
- `personal`: Personal correspondence
- `unknown`: Unclassified

### POST /v1/email/is-noise

Check if email metadata indicates noise/promotional content.

**Request:**
```json
{
  "subject": "Weekly Newsletter",
  "from": ["newsletter@example.com"],
  "to": ["subscriber@example.com"],
  "listUnsubscribe": "<mailto:unsubscribe@example.com>",
  "hasAttachments": false,
  "attachmentCount": 0
}
```

**Response:**
```json
{
  "is_noise": true
}
```

**Noise Detection Criteria:**
- Presence of List-Unsubscribe header (score +3)
- Promotional keywords in subject (score +2): "sale", "offer", "discount", etc.
- Bulk mail patterns in sender (score +2): "noreply", "no-reply", etc.
- Threshold: score >= 2 indicates noise

### POST /v1/email/redact-pii

Redact personally identifiable information from text.

**Request:**
```json
{
  "text": "Contact me at john@example.com or call 555-123-4567"
}
```

**Response:**
```json
{
  "redacted_text": "Contact me at [EMAIL_REDACTED] or call [PHONE_REDACTED]"
}
```

**PII Types Redacted:**
- Email addresses → `[EMAIL_REDACTED]`
- Phone numbers (various formats) → `[PHONE_REDACTED]`
- Account numbers (8+ digits) → `[ACCOUNT_REDACTED]`
- Social Security Numbers → `[SSN_REDACTED]`

## Configuration

Enable the mail module in your HostAgent configuration:

```yaml
modules:
  mail:
    enabled: true
    filters:
      combination_mode: any
      default_action: include
      # See MailFilters documentation for advanced filtering
```

## Implementation Details

### .emlx File Format

The .emlx format used by macOS Mail.app consists of:
1. A byte count on the first line
2. RFC 2822 formatted email message
3. Optional XML plist metadata (separated by `<?xml`)

### RFC 2822 Parsing

The parser handles:
- Multi-line headers (continuation lines starting with whitespace)
- Email address extraction using regex patterns
- Date parsing in RFC 2822 format
- MIME content type detection
- Header preservation for custom processing

### Intent Classification

Classification uses keyword matching and pattern detection:
- Subject line analysis
- Body content scanning
- Sender domain heuristics
- Confidence scoring based on match strength

Entity extraction attempts to identify:
- Dollar amounts for bills/receipts
- Order numbers and confirmation codes
- Dates and times for appointments

### Limitations

- **Attachment Resolution**: `resolveAttachmentPath` requires additional context from Mail.app's Envelope Index database
- **MIME Parsing**: Currently simplified - complex multipart MIME messages may not be fully parsed
- **HTML Rendering**: HTML emails are stored as-is; use LinkResolver for full rendering if needed

## Testing

The Email module includes comprehensive tests covering:
- Parsing various email formats (.emlx fixtures)
- Metadata extraction
- Noise detection with different criteria
- Intent classification for all supported types
- PII redaction accuracy

Run tests:
```bash
cd hostagent
swift test --filter EmailServiceTests
```

## Usage in Email Collector

The email utilities are designed to support the upcoming email collector (haven-25):

1. **Parsing**: Read .emlx files from Mail.app cache
2. **Filtering**: Use noise detection to skip promotional content
3. **Classification**: Identify high-value emails (bills, receipts, appointments)
4. **Privacy**: Redact PII before sending to Gateway/Catalog
5. **Enrichment**: Extract entities for enhanced searchability

See [Local Email Collector Guide](../guides/email-collector.md) for integration details.
