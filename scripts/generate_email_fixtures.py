#!/usr/bin/env python3
"""
Generate test fixtures for the email collector that simulate a real Mail.app environment.

This script creates:
1. .emlx files in a realistic directory structure
2. A mock Envelope Index SQLite database
3. Sample attachments
4. A catalog of metadata

Usage:
    # Generate synthetic emails
    python scripts/generate_email_fixtures.py --output /path/to/fixtures --count 50
    python scripts/generate_email_fixtures.py --output /path/to/fixtures --preset realistic
    
    # Import real user emails
    python scripts/generate_email_fixtures.py --output /path/to/fixtures --import-from ~/Mail/V10/Messages
"""

import argparse
import email
import email.message
import email.policy
import hashlib
import json
import random
import re
import shutil
import sqlite3
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


# Email templates and generators
@dataclass
class EmailTemplate:
    """Template for generating test emails"""
    subject: str
    from_addr: str
    to_addr: str
    body_plain: str
    body_html: Optional[str] = None
    intent: str = "generic"
    has_attachment: bool = False
    attachment_name: Optional[str] = None
    attachment_content: Optional[bytes] = None
    list_unsubscribe: Optional[str] = None
    in_reply_to: Optional[str] = None
    references: Optional[List[str]] = None
    message_id_prefix: str = "test"
    is_noise: bool = False


def generate_message_id(prefix: str, index: int) -> str:
    """Generate a unique message ID"""
    return f"<{prefix}{index}@example.com>"


def format_date(dt: datetime) -> str:
    """Format datetime for email Date header"""
    return dt.strftime("%a, %d %b %Y %H:%M:%S %z")


def calculate_emlx_size(content: str) -> int:
    """Calculate the size prefix for .emlx format (number of bytes in message)"""
    return len(content.encode('utf-8'))


def create_emlx_content(
    message_id: str,
    subject: str,
    from_addr: str,
    to_addr: str,
    date: datetime,
    body_plain: str,
    body_html: Optional[str] = None,
    list_unsubscribe: Optional[str] = None,
    in_reply_to: Optional[str] = None,
    references: Optional[List[str]] = None,
    cc: Optional[str] = None,
    bcc: Optional[str] = None,
    has_attachment: bool = False,
    attachment_name: Optional[str] = None,
) -> str:
    """Generate .emlx file content in RFC 2822 format"""
    
    headers = [
        f"From: {from_addr}",
        f"To: {to_addr}",
    ]
    
    if cc:
        headers.append(f"CC: {cc}")
    if bcc:
        headers.append(f"BCC: {bcc}")
    
    headers.extend([
        f"Subject: {subject}",
        f"Date: {format_date(date)}",
        f"Message-ID: {message_id}",
    ])
    
    if in_reply_to:
        headers.append(f"In-Reply-To: {in_reply_to}")
    
    if references:
        headers.append(f"References: {' '.join(references)}")
    
    if list_unsubscribe:
        headers.append(f"List-Unsubscribe: {list_unsubscribe}")
    
    # Determine content type
    if has_attachment or body_html:
        boundary = "----=_Part_" + hashlib.md5(message_id.encode()).hexdigest()[:16]
        headers.append(f"Content-Type: multipart/mixed; boundary=\"{boundary}\"")
        headers.append("MIME-Version: 1.0")
        headers.append("")
        
        body_parts = [f"--{boundary}"]
        
        if body_html:
            # Multipart alternative for plain + HTML
            alt_boundary = "----=_Part_Alt_" + hashlib.md5((message_id + "alt").encode()).hexdigest()[:16]
            body_parts.append(f"Content-Type: multipart/alternative; boundary=\"{alt_boundary}\"")
            body_parts.append("")
            body_parts.append(f"--{alt_boundary}")
            body_parts.append("Content-Type: text/plain; charset=utf-8")
            body_parts.append("Content-Transfer-Encoding: 7bit")
            body_parts.append("")
            body_parts.append(body_plain)
            body_parts.append("")
            body_parts.append(f"--{alt_boundary}")
            body_parts.append("Content-Type: text/html; charset=utf-8")
            body_parts.append("Content-Transfer-Encoding: 7bit")
            body_parts.append("")
            body_parts.append(body_html)
            body_parts.append(f"--{alt_boundary}--")
        else:
            body_parts.append("Content-Type: text/plain; charset=utf-8")
            body_parts.append("Content-Transfer-Encoding: 7bit")
            body_parts.append("")
            body_parts.append(body_plain)
        
        if has_attachment and attachment_name:
            body_parts.append(f"--{boundary}")
            body_parts.append(f"Content-Type: application/octet-stream; name=\"{attachment_name}\"")
            body_parts.append("Content-Transfer-Encoding: base64")
            body_parts.append(f"Content-Disposition: attachment; filename=\"{attachment_name}\"")
            body_parts.append("")
            # Placeholder attachment content
            import base64
            attachment_data = f"[Binary content for {attachment_name}]".encode()
            body_parts.append(base64.b64encode(attachment_data).decode())
        
        body_parts.append(f"--{boundary}--")
        
        message_body = "\n".join(body_parts)
    else:
        headers.append("Content-Type: text/plain; charset=utf-8")
        headers.append("")
        message_body = body_plain
    
    return "\n".join(headers) + "\n" + message_body


def create_receipt_template(index: int, base_date: datetime) -> EmailTemplate:
    """Generate a receipt email template"""
    order_num = f"ORD-2025-{10000 + index}"
    amount = f"${random.randint(10, 500)}.{random.randint(0, 99):02d}"
    
    return EmailTemplate(
        subject=f"Order Confirmation - {order_num}",
        from_addr="orders@shop.example.com",
        to_addr="customer@example.com",
        body_plain=f"""Dear Customer,

Thank you for your purchase!

Order Number: {order_num}
Amount: {amount}
Date: {base_date.strftime('%Y-%m-%d')}

Your order has been confirmed and will ship within 2-3 business days.

Items:
- Product A (Qty: 1) - ${random.randint(10, 100)}.99
- Product B (Qty: 2) - ${random.randint(5, 50)}.99

Shipping Address:
123 Main St
Anytown, ST 12345

Tracking information will be sent once your order ships.

Best regards,
Example Store
""",
        body_html=f"""<html><body>
<h2>Order Confirmation</h2>
<p>Dear Customer,</p>
<p>Thank you for your purchase!</p>
<table>
<tr><td><b>Order Number:</b></td><td>{order_num}</td></tr>
<tr><td><b>Amount:</b></td><td>{amount}</td></tr>
<tr><td><b>Date:</b></td><td>{base_date.strftime('%Y-%m-%d')}</td></tr>
</table>
<p>Your order has been confirmed and will ship within 2-3 business days.</p>
</body></html>""",
        intent="receipt",
        message_id_prefix=f"receipt{index}",
    )


def create_bill_template(index: int, base_date: datetime) -> EmailTemplate:
    """Generate a bill/statement email template"""
    account_num = f"****{random.randint(1000, 9999)}"
    amount = f"${random.randint(50, 500)}.{random.randint(0, 99):02d}"
    due_date = (base_date + timedelta(days=15)).strftime('%Y-%m-%d')
    
    return EmailTemplate(
        subject=f"Your Monthly Statement is Ready - Due {due_date}",
        from_addr="billing@utility.example.com",
        to_addr="customer@example.com",
        body_plain=f"""Account Statement

Account Number: {account_num}
Statement Date: {base_date.strftime('%Y-%m-%d')}
Amount Due: {amount}
Due Date: {due_date}

Please remit payment by the due date to avoid late fees.

Current Charges:
- Service Fee: ${random.randint(20, 100)}.00
- Usage: ${random.randint(30, 400)}.{random.randint(0, 99):02d}

Previous Balance: $0.00
Payments Received: $0.00

Total Amount Due: {amount}

You can pay online at https://billing.utility.example.com
or call 1-800-555-0100.

Thank you for your business.
""",
        intent="bill",
        message_id_prefix=f"bill{index}",
        has_attachment=random.random() > 0.5,
        attachment_name="statement.pdf" if random.random() > 0.5 else None,
    )


def create_appointment_template(index: int, base_date: datetime) -> EmailTemplate:
    """Generate an appointment confirmation email"""
    appt_date = base_date + timedelta(days=random.randint(1, 30))
    appt_time = f"{random.randint(9, 17):02d}:{random.choice(['00', '15', '30', '45'])}"
    conf_num = f"CONF-{random.randint(100000, 999999)}"
    
    thread_id = f"appt-request{index}@example.com"
    
    return EmailTemplate(
        subject="Appointment Confirmation",
        from_addr="appointments@clinic.example.com",
        to_addr="patient@example.com",
        body_plain=f"""Appointment Confirmation

Confirmation Number: {conf_num}

Date: {appt_date.strftime('%A, %B %d, %Y')}
Time: {appt_time}

Provider: Dr. Smith
Location: Medical Center, Suite 200
Address: 456 Health Ave, Wellness City, ST 12345

Please arrive 15 minutes early for check-in.

If you need to reschedule, please call us at 1-800-555-CARE at least 24 hours in advance.

Important: Please bring your insurance card and photo ID.

See you soon!
""",
        intent="appointment",
        message_id_prefix=f"appt{index}",
        in_reply_to=f"<{thread_id}>",
        references=[f"<{thread_id}>"],
    )


def create_promotional_template(index: int, base_date: datetime) -> EmailTemplate:
    """Generate a promotional/newsletter email (noise)"""
    discount = random.choice([20, 30, 40, 50])
    
    return EmailTemplate(
        subject=f"🎉 Weekly Newsletter - {discount}% Off Sale!",
        from_addr="marketing@newsletter.example.com",
        to_addr="subscriber@example.com",
        body_plain=f"""Weekly Newsletter - Special Offer Inside!

Hi there!

Don't miss our {discount}% off sale happening now!

Featured products:
- Item 1 - NOW ${random.randint(10, 50)}.99
- Item 2 - NOW ${random.randint(15, 75)}.99
- Item 3 - NOW ${random.randint(20, 100)}.99

Use code SAVE{discount} at checkout.

Sale ends {(base_date + timedelta(days=7)).strftime('%B %d')}.

Shop now: https://shop.example.com/sale

---
You're receiving this because you subscribed to our newsletter.
Unsubscribe: https://newsletter.example.com/unsubscribe?id=12345
""",
        body_html=f"""<html><body>
<h1>🎉 Weekly Newsletter</h1>
<h2>{discount}% Off Sale!</h2>
<p>Don't miss our special offer!</p>
<div style="background:#f0f0f0;padding:20px;">
<h3>Featured Products</h3>
<ul>
<li>Item 1 - <b>NOW ${random.randint(10, 50)}.99</b></li>
<li>Item 2 - <b>NOW ${random.randint(15, 75)}.99</b></li>
<li>Item 3 - <b>NOW ${random.randint(20, 100)}.99</b></li>
</ul>
<p><a href="https://shop.example.com/sale" style="background:#007bff;color:white;padding:10px 20px;text-decoration:none;">Shop Now</a></p>
</div>
<hr>
<small>Unsubscribe: <a href="https://newsletter.example.com/unsubscribe?id=12345">Click here</a></small>
</body></html>""",
        intent="promotional",
        is_noise=True,
        list_unsubscribe="<mailto:unsubscribe@newsletter.example.com>",
        message_id_prefix=f"promo{index}",
    )


def create_notification_template(index: int, base_date: datetime) -> EmailTemplate:
    """Generate a notification email (account activity, shipping, etc.)"""
    tracking = f"TRACK{random.randint(100000000, 999999999)}"
    
    return EmailTemplate(
        subject="Your package has shipped!",
        from_addr="shipping@delivery.example.com",
        to_addr="customer@example.com",
        body_plain=f"""Shipping Notification

Good news! Your package has shipped.

Tracking Number: {tracking}
Carrier: Example Shipping Co.
Estimated Delivery: {(base_date + timedelta(days=random.randint(3, 7))).strftime('%A, %B %d')}

Track your package: https://delivery.example.com/track/{tracking}

Items in this shipment:
- Product A (Qty: 1)

Your package will be delivered to:
123 Main St
Anytown, ST 12345

Thank you for your order!
""",
        intent="notification",
        message_id_prefix=f"notify{index}",
    )


def create_action_request_template(index: int, base_date: datetime) -> EmailTemplate:
    """Generate an action request email (password reset, verification, etc.)"""
    code = f"{random.randint(100000, 999999)}"
    
    return EmailTemplate(
        subject="Verify Your Email Address",
        from_addr="noreply@account.example.com",
        to_addr="user@example.com",
        body_plain=f"""Email Verification Required

Hello,

Please verify your email address to complete your account setup.

Verification Code: {code}

Or click this link to verify:
https://account.example.com/verify?code={code}

This code expires in 24 hours.

If you didn't request this, you can safely ignore this email.

Thanks,
The Example Team
""",
        intent="action_request",
        message_id_prefix=f"action{index}",
    )


# Template generators registry
TEMPLATE_GENERATORS = [
    create_receipt_template,
    create_bill_template,
    create_appointment_template,
    create_notification_template,
    create_action_request_template,
]

NOISE_GENERATORS = [
    create_promotional_template,
]


def generate_templates(count: int, noise_ratio: float = 0.2, start_date: Optional[datetime] = None) -> List[EmailTemplate]:
    """Generate a mix of email templates"""
    if start_date is None:
        start_date = datetime.now(timezone.utc) - timedelta(days=90)
    
    templates = []
    noise_count = int(count * noise_ratio)
    signal_count = count - noise_count
    
    # Generate signal emails
    for i in range(signal_count):
        generator = random.choice(TEMPLATE_GENERATORS)
        # Spread emails over 90 days
        days_offset = int((i / signal_count) * 90)
        email_date = start_date + timedelta(days=days_offset, hours=random.randint(0, 23), minutes=random.randint(0, 59))
        templates.append(generator(i, email_date))
    
    # Generate noise emails
    for i in range(noise_count):
        generator = random.choice(NOISE_GENERATORS)
        days_offset = int((i / noise_count) * 90)
        email_date = start_date + timedelta(days=days_offset, hours=random.randint(0, 23), minutes=random.randint(0, 59))
        templates.append(generator(signal_count + i, email_date))
    
    # Sort by date
    templates.sort(key=lambda t: start_date)
    
    return templates


def write_emlx_file(output_dir: Path, index: int, template: EmailTemplate, date: datetime) -> dict:
    """Write an .emlx file and return metadata"""
    message_id = generate_message_id(template.message_id_prefix, index)
    
    content = create_emlx_content(
        message_id=message_id,
        subject=template.subject,
        from_addr=template.from_addr,
        to_addr=template.to_addr,
        date=date,
        body_plain=template.body_plain,
        body_html=template.body_html,
        list_unsubscribe=template.list_unsubscribe,
        in_reply_to=template.in_reply_to,
        references=template.references,
        has_attachment=template.has_attachment,
        attachment_name=template.attachment_name,
    )
    
    # .emlx format: size on first line, then content
    size = calculate_emlx_size(content)
    emlx_content = f"{size}\n{content}"
    
    # Write file with index as filename (simulating Mail.app numbering)
    emlx_path = output_dir / f"{index + 1}.emlx"
    emlx_path.write_text(emlx_content, encoding='utf-8')
    
    return {
        'index': index + 1,
        'path': str(emlx_path),
        'message_id': message_id,
        'subject': template.subject,
        'from': template.from_addr,
        'to': template.to_addr,
        'date': date.isoformat(),
        'intent': template.intent,
        'is_noise': template.is_noise,
        'has_attachment': template.has_attachment,
        'size': size,
    }


def create_envelope_index_db(db_path: Path, metadata_list: List[dict]) -> None:
    """Create a mock Envelope Index SQLite database"""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    
    conn = sqlite3.connect(str(db_path))
    cursor = conn.cursor()
    
    # Simplified Envelope Index schema (based on Mail.app structure)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS messages (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id TEXT,
            subject TEXT,
            sender TEXT,
            date_received INTEGER,
            date_sent INTEGER,
            mailbox TEXT,
            read INTEGER DEFAULT 0,
            flagged INTEGER DEFAULT 0,
            deleted INTEGER DEFAULT 0,
            junk INTEGER DEFAULT 0,
            remote_id TEXT,
            original_mailbox TEXT
        )
    """)
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS mailboxes (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT,
            name TEXT
        )
    """)
    
    # Create some mailboxes
    mailboxes = [
        ('imap://mail.example.com/INBOX', 'Inbox'),
        ('imap://mail.example.com/Sent', 'Sent'),
        ('imap://mail.example.com/Receipts', 'Inbox/Receipts'),
        ('imap://mail.example.com/Bills', 'Inbox/Bills'),
        ('imap://mail.example.com/Junk', 'Junk'),
        ('imap://mail.example.com/Trash', 'Trash'),
        ('imap://mail.example.com/Promotions', 'Promotions'),
    ]
    
    for url, name in mailboxes:
        cursor.execute("INSERT INTO mailboxes (url, name) VALUES (?, ?)", (url, name))
    
    # Insert messages
    for i, metadata in enumerate(metadata_list):
        # Handle both string and datetime objects
        date_value = metadata['date']
        if isinstance(date_value, str):
            date_obj = datetime.fromisoformat(date_value)
        elif isinstance(date_value, datetime):
            date_obj = date_value
        else:
            date_obj = datetime.now(timezone.utc)
        
        date_epoch = int(date_obj.timestamp())
        
        # Assign mailbox based on intent
        intent = metadata.get('intent', 'generic')
        is_noise = metadata.get('is_noise', False)
        
        if is_noise:
            mailbox = random.choice(['Junk', 'Promotions'])
        elif intent == 'receipt':
            mailbox = 'Inbox/Receipts'
        elif intent == 'bill':
            mailbox = 'Inbox/Bills'
        else:
            mailbox = 'Inbox'
        
        cursor.execute("""
            INSERT INTO messages (
                message_id, subject, sender, date_received, date_sent,
                mailbox, read, flagged, junk
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            metadata['message_id'],
            metadata['subject'],
            metadata['from'],
            date_epoch,
            date_epoch,
            mailbox,
            random.choice([0, 1]),
            0,
            1 if is_noise else 0,
        ))
    
    conn.commit()
    conn.close()


def create_catalog_json(output_dir: Path, metadata_list: List[dict]) -> None:
    """Create a JSON catalog of all generated emails"""
    
    # Convert datetime objects to ISO strings for JSON serialization
    serializable_metadata = []
    for m in metadata_list:
        m_copy = m.copy()
        if 'date' in m_copy and isinstance(m_copy['date'], datetime):
            m_copy['date'] = m_copy['date'].isoformat()
        serializable_metadata.append(m_copy)
    
    catalog = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'total_emails': len(metadata_list),
        'emails': serializable_metadata,
        'stats': {
            'intents': {},
            'noise_emails': sum(1 for m in metadata_list if m.get('is_noise', False)),
            'signal_emails': sum(1 for m in metadata_list if not m.get('is_noise', False)),
        }
    }
    
    # Count by intent
    for metadata in metadata_list:
        intent = metadata.get('intent', 'unknown')
        catalog['stats']['intents'][intent] = catalog['stats']['intents'].get(intent, 0) + 1
    
    catalog_path = output_dir / 'catalog.json'
    catalog_path.write_text(json.dumps(catalog, indent=2))


def create_readme(output_dir: Path, metadata_list: List[dict]) -> None:
    """Create a README describing the fixture structure"""
    readme_content = f"""# Email Collector Test Fixtures

Generated: {datetime.now(timezone.utc).isoformat()}
Total emails: {len(metadata_list)}

## Structure

```
{output_dir.name}/
├── Messages/           # .emlx files (Mail.app format)
│   ├── 1.emlx
│   ├── 2.emlx
│   └── ...
├── Envelope Index     # Mock SQLite database
├── catalog.json       # Metadata catalog
└── README.md         # This file
```

## .emlx Files

Each .emlx file follows the Mail.app format:
- First line: byte count of the message
- Remaining lines: RFC 2822 email message

Files are numbered sequentially starting from 1.

## Envelope Index

SQLite database simulating Mail.app's Envelope Index with tables:
- `messages`: Message metadata (ROWID, subject, sender, date, mailbox, flags)
- `mailboxes`: Mailbox definitions (INBOX, Sent, Receipts, Bills, Junk, etc.)

## Catalog

The `catalog.json` file contains metadata for all generated emails:
- Message IDs
- Subjects, senders, recipients
- Dates
- Intent classifications
- Noise flags
- File paths

## Usage

### With HostAgent (simulate mode)

```bash
curl -X POST http://localhost:7090/v1/collectors/email_local:run \\
  -H "Content-Type: application/json" \\
  -H "x-auth: change-me" \\
  -d '{{
        "mode": "simulate",
        "simulate_path": "{output_dir / 'Messages'}",
        "limit": {len(metadata_list)}
      }}'
```

### With Python collector (when implemented)

```python
from scripts.collectors import collector_email_local

# Indexed mode (using Envelope Index)
collector_email_local.run_indexed_mode(
    envelope_index_path="{output_dir / 'Envelope Index'}",
    emlx_root="{output_dir / 'Messages'}"
)

# Crawler mode (scanning .emlx files)
collector_email_local.run_crawler_mode(
    emlx_root="{output_dir / 'Messages'}"
)
```

## Email Types

This fixture set includes:
{chr(10).join(f"- {intent}: {count} emails" for intent, count in sorted(__count_intents(metadata_list).items()))}

Noise ratio: {sum(1 for m in metadata_list if m['is_noise']) / len(metadata_list) * 100:.1f}%

## Testing Notes

- All emails use example.com domains (no real addresses)
- Dates span 90 days from generation
- Attachments are referenced but contain placeholder content
- PII patterns (phone numbers, account numbers) included for redaction testing
"""
    
    readme_path = output_dir / 'README.md'
    readme_path.write_text(readme_content)


def __count_intents(metadata_list: List[dict]) -> dict:
    """Helper to count intents for README"""
    counts = {}
    for m in metadata_list:
        intent = m['intent']
        counts[intent] = counts.get(intent, 0) + 1
    return counts


def parse_emlx_file(emlx_path: Path) -> Tuple[email.message.Message, Dict[str, Any]]:
    """
    Parse a .emlx file and extract the email message and metadata.
    
    Returns:
        Tuple of (email.message.Message, metadata dict)
    """
    content = emlx_path.read_text(encoding='utf-8', errors='replace')
    lines = content.split('\n')
    
    # First line is byte count
    if not lines[0].isdigit():
        raise ValueError(f"Invalid .emlx format in {emlx_path}: first line should be byte count")
    
    byte_count = int(lines[0])
    message_text = '\n'.join(lines[1:])
    
    # Parse email message
    msg = email.message_from_string(message_text, policy=email.policy.default)
    
    # Extract metadata
    metadata = {
        'path': str(emlx_path),
        'size': byte_count,
        'message_id': msg.get('Message-ID', f'<unknown@{emlx_path.name}>'),
        'subject': msg.get('Subject', '(no subject)'),
        'from': msg.get('From', 'unknown@example.com'),
        'to': msg.get('To', 'unknown@example.com'),
        'cc': msg.get('CC', ''),
        'date': None,
        'in_reply_to': msg.get('In-Reply-To'),
        'references': msg.get('References', '').split() if msg.get('References') else [],
        'list_unsubscribe': msg.get('List-Unsubscribe'),
    }
    
    # Parse date
    date_str = msg.get('Date')
    if date_str:
        try:
            metadata['date'] = parsedate_to_datetime(date_str)
        except Exception:
            metadata['date'] = datetime.now(timezone.utc)
    else:
        metadata['date'] = datetime.now(timezone.utc)
    
    # Get body content
    body_plain = None
    body_html = None
    
    if msg.is_multipart():
        for part in msg.walk():
            content_type = part.get_content_type()
            if content_type == 'text/plain' and body_plain is None:
                try:
                    body_plain = part.get_content()
                except Exception:
                    pass
            elif content_type == 'text/html' and body_html is None:
                try:
                    body_html = part.get_content()
                except Exception:
                    pass
    else:
        content_type = msg.get_content_type()
        if content_type == 'text/plain':
            try:
                body_plain = msg.get_content()
            except Exception:
                body_plain = str(msg.get_payload())
        elif content_type == 'text/html':
            try:
                body_html = msg.get_content()
            except Exception:
                body_html = str(msg.get_payload())
    
    metadata['body_plain'] = body_plain or ''
    metadata['body_html'] = body_html
    
    return msg, metadata


def classify_intent_from_metadata(metadata: Dict[str, Any]) -> str:
    """Classify email intent based on metadata"""
    subject = (metadata.get('subject') or '').lower()
    body = (metadata.get('body_plain') or '').lower()
    
    # Receipt patterns
    if any(word in subject or word in body for word in ['order', 'receipt', 'purchase', 'confirmation']):
        if any(word in subject or word in body for word in ['order #', 'order number', 'ord-', 'receipt']):
            return 'receipt'
    
    # Bill patterns
    if any(word in subject or word in body for word in ['bill', 'statement', 'invoice', 'payment due']):
        return 'bill'
    
    # Appointment patterns
    if any(word in subject or word in body for word in ['appointment', 'reservation', 'booking']):
        return 'appointment'
    
    # Notification patterns
    if any(word in subject or word in body for word in ['shipped', 'tracking', 'delivery', 'notification']):
        return 'notification'
    
    # Action request patterns
    if any(word in subject or word in body for word in ['verify', 'confirm', 'reset password', 'activate']):
        return 'action_request'
    
    # Promotional patterns (noise)
    if any(word in subject or word in body for word in ['sale', 'discount', 'offer', 'newsletter', 'unsubscribe']):
        return 'promotional'
    
    return 'generic'


def is_noise_from_metadata(metadata: Dict[str, Any]) -> bool:
    """Determine if email is noise based on metadata"""
    # Check for List-Unsubscribe header (strong signal of promotional content)
    if metadata.get('list_unsubscribe'):
        return True
    
    # Check subject and body for promotional keywords
    subject = (metadata.get('subject') or '').lower()
    body = (metadata.get('body_plain') or '').lower()
    
    noise_keywords = ['unsubscribe', 'opt out', 'marketing', 'newsletter', 'promotional']
    
    if any(keyword in subject or keyword in body for keyword in noise_keywords):
        return True
    
    return False


def detect_attachments(msg: email.message.Message) -> List[Dict[str, Any]]:
    """Detect attachments in an email message"""
    attachments = []
    
    if msg.is_multipart():
        for i, part in enumerate(msg.walk()):
            content_disposition = part.get('Content-Disposition', '')
            
            if 'attachment' in content_disposition:
                filename = part.get_filename()
                content_type = part.get_content_type()
                
                try:
                    payload = part.get_payload(decode=True)
                    size = len(payload) if payload else 0
                except Exception:
                    size = 0
                
                attachments.append({
                    'filename': filename or f'attachment_{i}',
                    'content_type': content_type,
                    'size': size,
                    'part_index': i,
                })
    
    return attachments


def copy_attachments_from_mail_cache(
    source_dir: Path,
    attachments_info: List[Dict[str, Any]],
    output_attachments_dir: Path
) -> List[Path]:
    """
    Copy attachments from Mail.app cache structure.
    
    Mail.app stores attachments in a parallel directory structure:
    Messages/12345.emlx
    Attachments/12345/<filename>
    
    Args:
        source_dir: Source directory containing Messages/ and Attachments/
        attachments_info: List of attachment metadata from email parsing
        output_attachments_dir: Destination for copied attachments
        
    Returns:
        List of copied attachment paths
    """
    copied = []
    
    # Look for Attachments directory parallel to Messages
    source_attachments = source_dir.parent / 'Attachments' if source_dir.name == 'Messages' else source_dir / 'Attachments'
    
    if not source_attachments.exists():
        return copied
    
    output_attachments_dir.mkdir(parents=True, exist_ok=True)
    
    for att in attachments_info:
        filename = att['filename']
        
        # Try to find attachment in source
        # Mail.app uses various naming schemes
        found_files = list(source_attachments.rglob(filename))
        
        if found_files:
            source_file = found_files[0]
            dest_file = output_attachments_dir / filename
            
            # Avoid duplicates
            if dest_file.exists():
                base = dest_file.stem
                ext = dest_file.suffix
                counter = 1
                while dest_file.exists():
                    dest_file = output_attachments_dir / f"{base}_{counter}{ext}"
                    counter += 1
            
            shutil.copy2(source_file, dest_file)
            copied.append(dest_file)
    
    return copied


def convert_eml_to_emlx(eml_path: Path, output_path: Path) -> None:
    """
    Convert a .eml file to .emlx format.
    
    .eml format: Standard RFC 2822 email message
    .emlx format: Mail.app format with byte count on first line
    
    Args:
        eml_path: Path to source .eml file
        output_path: Path to destination .emlx file
    """
    # Read .eml file
    content = eml_path.read_text(encoding='utf-8', errors='replace')
    
    # Calculate byte count
    byte_count = len(content.encode('utf-8'))
    
    # Write .emlx format: byte count on first line, then content
    emlx_content = f"{byte_count}\n{content}"
    output_path.write_text(emlx_content, encoding='utf-8')


def import_user_emails(
    source_dir: Path,
    output_dir: Path,
    limit: Optional[int] = None,
    include_attachments: bool = True
) -> List[dict]:
    """
    Import real user emails from a directory of .emlx or .eml files.
    
    Supports both .emlx (Mail.app) and .eml (standard RFC 2822) formats.
    .eml files are automatically converted to .emlx format.
    
    Args:
        source_dir: Directory containing .emlx/.eml files (e.g., ~/Library/Mail/V10/Messages)
        output_dir: Output directory for fixture structure
        limit: Maximum number of emails to import (None for all)
        include_attachments: Whether to copy attachments
        
    Returns:
        List of metadata dicts for imported emails
    """
    if not source_dir.exists():
        raise FileNotFoundError(f"Source directory not found: {source_dir}")
    
    # Find all .emlx and .eml files
    emlx_files = sorted(source_dir.rglob('*.emlx'))
    eml_files = sorted(source_dir.rglob('*.eml'))
    
    all_files = emlx_files + eml_files
    
    if not all_files:
        raise ValueError(f"No .emlx or .eml files found in {source_dir}")
    all_files = emlx_files + eml_files
    
    if not all_files:
        raise ValueError(f"No .emlx or .eml files found in {source_dir}")
    
    if limit:
        all_files = all_files[:limit]
    
    print(f"Found {len(all_files)} email files to import ({len(emlx_files)} .emlx, {len(eml_files)} .eml)")
    
    # Create output structure
    messages_dir = output_dir / 'Messages'
    messages_dir.mkdir(parents=True, exist_ok=True)
    
    attachments_dir = output_dir / 'Attachments'
    if include_attachments:
        attachments_dir.mkdir(parents=True, exist_ok=True)
    
    metadata_list = []
    eml_converted = 0
    
    for i, source_file in enumerate(all_files):
        try:
            # Handle .eml files: convert to .emlx format first
            if source_file.suffix.lower() == '.eml':
                # Create temporary .emlx file
                temp_emlx = messages_dir / f"{i + 1}.emlx"
                convert_eml_to_emlx(source_file, temp_emlx)
                source_emlx = temp_emlx
                eml_converted += 1
            else:
                # Copy .emlx to output with sequential numbering
                dest_emlx = messages_dir / f"{i + 1}.emlx"
                shutil.copy2(source_file, dest_emlx)
                source_emlx = dest_emlx
            
            # Parse email
            msg, metadata = parse_emlx_file(source_emlx)
            
            # Classify intent
            metadata['intent'] = classify_intent_from_metadata(metadata)
            metadata['is_noise'] = is_noise_from_metadata(metadata)
            
            # Detect attachments
            attachments = detect_attachments(msg)
            metadata['has_attachment'] = len(attachments) > 0
            metadata['attachments'] = attachments
            
            # Update path to point to final .emlx location
            metadata['index'] = i + 1
            metadata['path'] = str(source_emlx)
            metadata['original_path'] = str(source_file)
            metadata['was_converted'] = source_file.suffix.lower() == '.eml'
            
            # Copy attachments if present and requested
            if include_attachments and attachments:
                att_output_dir = attachments_dir / f"{i + 1}"
                copied = copy_attachments_from_mail_cache(
                    source_dir,
                    attachments,
                    att_output_dir
                )
                metadata['attachment_paths'] = [str(p) for p in copied]
            
            metadata_list.append(metadata)
            
            if (i + 1) % 10 == 0 or i == len(all_files) - 1:
                print(f"  Imported {i + 1}/{len(all_files)} emails...", end='\r')
        
        except Exception as e:
            print(f"\n  Warning: Failed to import {source_file.name}: {e}")
            continue
    
    print(f"\n✓ Imported {len(metadata_list)} emails")
    if eml_converted > 0:
        print(f"  ({eml_converted} .eml files converted to .emlx format)")
    
    return metadata_list


def main():
    parser = argparse.ArgumentParser(
        description="Generate test fixtures for email collector",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate synthetic emails
  python scripts/generate_email_fixtures.py --output ~/.haven/fixtures/email --count 50
  python scripts/generate_email_fixtures.py --output ./fixtures --count 100 --noise 0.3
  python scripts/generate_email_fixtures.py --output ./fixtures --preset realistic
  
  # Import real user emails
  python scripts/generate_email_fixtures.py --output ./fixtures --import-from ~/Library/Mail/V10/Messages
  python scripts/generate_email_fixtures.py --output ./fixtures --import-from ~/Mail --limit 50
        """
    )
    
    parser.add_argument(
        '--output', '-o',
        type=Path,
        required=True,
        help='Output directory for fixtures'
    )
    
    parser.add_argument(
        '--import-from',
        type=Path,
        help='Import real .emlx files from this directory instead of generating synthetic ones'
    )
    
    parser.add_argument(
        '--limit',
        type=int,
        help='Maximum number of emails to import (when using --import-from)'
    )
    
    parser.add_argument(
        '--no-attachments',
        action='store_true',
        help='Skip copying attachments when importing (when using --import-from)'
    )
    
    parser.add_argument(
        '--count', '-c',
        type=int,
        default=50,
        help='Number of emails to generate (default: 50, ignored with --import-from)'
    )
    
    parser.add_argument(
        '--noise', '-n',
        type=float,
        default=0.2,
        help='Ratio of noise/promotional emails (default: 0.2, ignored with --import-from)'
    )
    
    parser.add_argument(
        '--preset', '-p',
        choices=['minimal', 'realistic', 'stress'],
        help='Use a preset configuration'
    )
    
    parser.add_argument(
        '--start-date',
        type=lambda s: datetime.fromisoformat(s),
        help='Start date for email timestamps (ISO format, default: 90 days ago)'
    )
    
    args = parser.parse_args()
    
    # Setup
    output_dir = args.output.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Import mode vs generate mode
    if args.import_from:
        # Import real emails
        source_dir = args.import_from.resolve()
        
        if not source_dir.exists():
            print(f"Error: Source directory not found: {source_dir}", file=sys.stderr)
            sys.exit(1)
        
        print(f"Importing emails from: {source_dir}")
        print(f"Output directory: {output_dir}")
        
        try:
            metadata_list = import_user_emails(
                source_dir=source_dir,
                output_dir=output_dir,
                limit=args.limit,
                include_attachments=not args.no_attachments
            )
        except Exception as e:
            print(f"Error importing emails: {e}", file=sys.stderr)
            sys.exit(1)
        
        if not metadata_list:
            print("Error: No emails were successfully imported", file=sys.stderr)
            sys.exit(1)
        
        messages_dir = output_dir / 'Messages'
        
    else:
        # Generate synthetic emails
        # Apply presets
        if args.preset == 'minimal':
            count = 10
            noise = 0.1
        elif args.preset == 'realistic':
            count = 100
            noise = 0.25
        elif args.preset == 'stress':
            count = 1000
            noise = 0.3
        else:
            count = args.count
            noise = args.noise
        
        # Validate
        if count < 1:
            print("Error: count must be at least 1", file=sys.stderr)
            sys.exit(1)
        
        if not 0 <= noise <= 1:
            print("Error: noise ratio must be between 0 and 1", file=sys.stderr)
            sys.exit(1)
        
        messages_dir = output_dir / 'Messages'
        messages_dir.mkdir(exist_ok=True)
        
        print(f"Generating {count} email fixtures (noise ratio: {noise:.0%})...")
        print(f"Output directory: {output_dir}")
        
        # Generate templates
        start_date = args.start_date or (datetime.now(timezone.utc) - timedelta(days=90))
        templates = generate_templates(count, noise_ratio=noise, start_date=start_date)
        
        # Write .emlx files
        metadata_list = []
        for i, template in enumerate(templates):
            # Calculate date for this email
            days_offset = int((i / len(templates)) * 90)
            email_date = start_date + timedelta(
                days=days_offset,
                hours=random.randint(0, 23),
                minutes=random.randint(0, 59)
            )
            
            metadata = write_emlx_file(messages_dir, i, template, email_date)
            metadata_list.append(metadata)
            
            if (i + 1) % 10 == 0 or i == len(templates) - 1:
                print(f"  Generated {i + 1}/{len(templates)} emails...", end='\r')
        
        print(f"\n✓ Generated {len(templates)} .emlx files")
    
    # Create Envelope Index database
    db_path = output_dir / 'Envelope Index'
    create_envelope_index_db(db_path, metadata_list)
    print(f"✓ Created Envelope Index database: {db_path}")
    
    # Create catalog
    create_catalog_json(output_dir, metadata_list)
    print(f"✓ Created catalog: {output_dir / 'catalog.json'}")
    
    # Create README
    create_readme(output_dir, metadata_list)
    print(f"✓ Created README: {output_dir / 'README.md'}")
    
    mode_label = "imported" if args.import_from else "generated"
    print(f"\n✅ Fixture {mode_label.replace('ed', 'ion')} complete!")
    print(f"\nTo use with HostAgent:")
    print(f'  curl -X POST http://localhost:7090/v1/collectors/email_local:run \\')
    print(f'    -H "Content-Type: application/json" \\')
    print(f'    -H "x-auth: change-me" \\')
    print(f'    -d \'{{"mode":"simulate","simulate_path":"{messages_dir}","limit":{len(metadata_list)}}}\'')
    print(f"\nFixture stats:")
    print(f"  Total: {len(metadata_list)} emails ({mode_label})")
    print(f"  Signal: {sum(1 for m in metadata_list if not m.get('is_noise', False))} emails")
    print(f"  Noise: {sum(1 for m in metadata_list if m.get('is_noise', False))} emails")
    
    # Count attachments if any
    total_attachments = sum(len(m.get('attachments', [])) for m in metadata_list)
    if total_attachments > 0:
        print(f"  Attachments: {total_attachments}")
    
    intent_counts = {}
    for m in metadata_list:
        intent = m.get('intent', 'unknown')
        intent_counts[intent] = intent_counts.get(intent, 0) + 1
    
    print(f"\n  By intent:")
    for intent, count in sorted(intent_counts.items()):
        print(f"    {intent}: {count}")


if __name__ == '__main__':
    main()
