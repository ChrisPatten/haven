"""Tests for email fixture generator"""

import json
import sqlite3
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from scripts import generate_email_fixtures as gen


def test_generate_message_id():
    """Test message ID generation"""
    msg_id = gen.generate_message_id("test", 123)
    assert msg_id == "<test123@example.com>"


def test_format_date():
    """Test email date formatting"""
    dt = datetime(2025, 10, 21, 14, 30, 0, tzinfo=timezone.utc)
    formatted = gen.format_date(dt)
    assert "21 Oct 2025" in formatted
    assert "14:30:00" in formatted


def test_create_receipt_template():
    """Test receipt email template generation"""
    base_date = datetime(2025, 10, 1, tzinfo=timezone.utc)
    template = gen.create_receipt_template(0, base_date)
    
    assert "Order" in template.subject
    assert "ORD-2025-10000" in template.body_plain
    assert template.intent == "receipt"
    assert not template.is_noise
    assert "$" in template.body_plain


def test_create_bill_template():
    """Test bill email template generation"""
    base_date = datetime(2025, 10, 1, tzinfo=timezone.utc)
    template = gen.create_bill_template(0, base_date)
    
    assert "Statement" in template.subject or "Bill" in template.subject
    assert template.intent == "bill"
    assert not template.is_noise
    assert "$" in template.body_plain


def test_create_appointment_template():
    """Test appointment email template generation"""
    base_date = datetime(2025, 10, 1, tzinfo=timezone.utc)
    template = gen.create_appointment_template(0, base_date)
    
    assert "Appointment" in template.subject
    assert template.intent == "appointment"
    assert template.in_reply_to is not None
    assert template.references is not None
    assert len(template.references) > 0


def test_create_promotional_template():
    """Test promotional email template generation"""
    base_date = datetime(2025, 10, 1, tzinfo=timezone.utc)
    template = gen.create_promotional_template(0, base_date)
    
    assert template.intent == "promotional"
    assert template.is_noise is True
    assert template.list_unsubscribe is not None
    assert "unsubscribe" in template.list_unsubscribe.lower()


def test_create_notification_template():
    """Test notification email template generation"""
    base_date = datetime(2025, 10, 1, tzinfo=timezone.utc)
    template = gen.create_notification_template(0, base_date)
    
    assert template.intent == "notification"
    assert not template.is_noise


def test_create_action_request_template():
    """Test action request email template generation"""
    base_date = datetime(2025, 10, 1, tzinfo=timezone.utc)
    template = gen.create_action_request_template(0, base_date)
    
    assert template.intent == "action_request"
    assert not template.is_noise


def test_create_emlx_content_plain_text():
    """Test .emlx content creation for plain text email"""
    content = gen.create_emlx_content(
        message_id="<test@example.com>",
        subject="Test Subject",
        from_addr="sender@example.com",
        to_addr="recipient@example.com",
        date=datetime(2025, 10, 21, 12, 0, 0, tzinfo=timezone.utc),
        body_plain="Test body content",
    )
    
    assert "From: sender@example.com" in content
    assert "To: recipient@example.com" in content
    assert "Subject: Test Subject" in content
    assert "Message-ID: <test@example.com>" in content
    assert "Test body content" in content
    assert "Content-Type: text/plain" in content


def test_create_emlx_content_with_html():
    """Test .emlx content creation with HTML body"""
    content = gen.create_emlx_content(
        message_id="<test@example.com>",
        subject="Test",
        from_addr="sender@example.com",
        to_addr="recipient@example.com",
        date=datetime(2025, 10, 21, 12, 0, 0, tzinfo=timezone.utc),
        body_plain="Plain text",
        body_html="<html><body>HTML content</body></html>",
    )
    
    assert "multipart/mixed" in content
    assert "multipart/alternative" in content
    assert "text/plain" in content
    assert "text/html" in content
    assert "Plain text" in content
    assert "HTML content" in content


def test_create_emlx_content_with_attachment():
    """Test .emlx content creation with attachment"""
    content = gen.create_emlx_content(
        message_id="<test@example.com>",
        subject="Test",
        from_addr="sender@example.com",
        to_addr="recipient@example.com",
        date=datetime(2025, 10, 21, 12, 0, 0, tzinfo=timezone.utc),
        body_plain="Body",
        has_attachment=True,
        attachment_name="document.pdf",
    )
    
    assert "multipart/mixed" in content
    assert "attachment" in content.lower()
    assert "document.pdf" in content


def test_create_emlx_content_with_headers():
    """Test .emlx content with additional headers"""
    content = gen.create_emlx_content(
        message_id="<test@example.com>",
        subject="Re: Original",
        from_addr="sender@example.com",
        to_addr="recipient@example.com",
        date=datetime(2025, 10, 21, 12, 0, 0, tzinfo=timezone.utc),
        body_plain="Reply body",
        in_reply_to="<original@example.com>",
        references=["<original@example.com>"],
        list_unsubscribe="<mailto:unsub@example.com>",
    )
    
    assert "In-Reply-To: <original@example.com>" in content
    assert "References: <original@example.com>" in content
    assert "List-Unsubscribe: <mailto:unsub@example.com>" in content


def test_generate_templates():
    """Test template generation with various counts and ratios"""
    templates = gen.generate_templates(count=10, noise_ratio=0.3)
    
    assert len(templates) == 10
    
    noise_count = sum(1 for t in templates if t.is_noise)
    signal_count = sum(1 for t in templates if not t.is_noise)
    
    assert noise_count == 3
    assert signal_count == 7


def test_generate_templates_all_signal():
    """Test template generation with no noise"""
    templates = gen.generate_templates(count=5, noise_ratio=0.0)
    
    assert len(templates) == 5
    assert all(not t.is_noise for t in templates)


def test_generate_templates_all_noise():
    """Test template generation with all noise"""
    templates = gen.generate_templates(count=5, noise_ratio=1.0)
    
    assert len(templates) == 5
    assert all(t.is_noise for t in templates)


def test_write_emlx_file():
    """Test writing .emlx file"""
    with tempfile.TemporaryDirectory() as tmpdir:
        output_dir = Path(tmpdir)
        template = gen.create_receipt_template(0, datetime.now(timezone.utc))
        
        metadata = gen.write_emlx_file(
            output_dir,
            0,
            template,
            datetime(2025, 10, 21, 12, 0, 0, tzinfo=timezone.utc)
        )
        
        assert metadata['index'] == 1
        assert Path(metadata['path']).exists()
        assert metadata['subject'] == template.subject
        assert metadata['intent'] == template.intent
        
        # Read the file and verify format
        emlx_path = Path(metadata['path'])
        content = emlx_path.read_text()
        lines = content.split('\n')
        
        # First line should be the byte count
        assert lines[0].isdigit()
        size = int(lines[0])
        
        # Rest should be the email message
        message = '\n'.join(lines[1:])
        assert len(message.encode('utf-8')) == size


def test_create_envelope_index_db():
    """Test Envelope Index database creation"""
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = Path(tmpdir) / "test.db"
        
        metadata_list = [
            {
                'message_id': '<test1@example.com>',
                'subject': 'Test 1',
                'from': 'sender@example.com',
                'to': 'recipient@example.com',
                'date': datetime.now(timezone.utc).isoformat(),
                'intent': 'receipt',
                'is_noise': False,
            },
            {
                'message_id': '<test2@example.com>',
                'subject': 'Test 2',
                'from': 'sender@example.com',
                'to': 'recipient@example.com',
                'date': datetime.now(timezone.utc).isoformat(),
                'intent': 'promotional',
                'is_noise': True,
            },
        ]
        
        gen.create_envelope_index_db(db_path, metadata_list)
        
        assert db_path.exists()
        
        # Verify database contents
        conn = sqlite3.connect(str(db_path))
        cursor = conn.cursor()
        
        # Check messages table
        cursor.execute("SELECT COUNT(*) FROM messages")
        count = cursor.fetchone()[0]
        assert count == 2
        
        # Check mailboxes table
        cursor.execute("SELECT COUNT(*) FROM mailboxes")
        mailbox_count = cursor.fetchone()[0]
        assert mailbox_count > 0
        
        # Check message details
        cursor.execute("SELECT message_id, subject, junk FROM messages ORDER BY ROWID")
        rows = cursor.fetchall()
        
        assert rows[0][0] == '<test1@example.com>'
        assert rows[0][1] == 'Test 1'
        assert rows[0][2] == 0  # Not junk
        
        assert rows[1][0] == '<test2@example.com>'
        assert rows[1][1] == 'Test 2'
        assert rows[1][2] == 1  # Is junk
        
        conn.close()


def test_create_catalog_json():
    """Test catalog JSON creation"""
    with tempfile.TemporaryDirectory() as tmpdir:
        output_dir = Path(tmpdir)
        
        metadata_list = [
            {'intent': 'receipt', 'is_noise': False},
            {'intent': 'receipt', 'is_noise': False},
            {'intent': 'bill', 'is_noise': False},
            {'intent': 'promotional', 'is_noise': True},
        ]
        
        gen.create_catalog_json(output_dir, metadata_list)
        
        catalog_path = output_dir / 'catalog.json'
        assert catalog_path.exists()
        
        catalog = json.loads(catalog_path.read_text())
        
        assert catalog['total_emails'] == 4
        assert catalog['stats']['signal_emails'] == 3
        assert catalog['stats']['noise_emails'] == 1
        assert catalog['stats']['intents']['receipt'] == 2
        assert catalog['stats']['intents']['bill'] == 1
        assert catalog['stats']['intents']['promotional'] == 1


def test_end_to_end_fixture_generation():
    """Test complete fixture generation workflow"""
    with tempfile.TemporaryDirectory() as tmpdir:
        output_dir = Path(tmpdir)
        messages_dir = output_dir / 'Messages'
        messages_dir.mkdir()
        
        # Generate templates
        templates = gen.generate_templates(count=10, noise_ratio=0.2)
        
        # Write .emlx files
        metadata_list = []
        start_date = datetime.now(timezone.utc) - timedelta(days=30)
        
        for i, template in enumerate(templates):
            email_date = start_date + timedelta(days=i * 3)
            metadata = gen.write_emlx_file(messages_dir, i, template, email_date)
            metadata_list.append(metadata)
        
        # Create Envelope Index
        db_path = output_dir / 'Envelope Index'
        gen.create_envelope_index_db(db_path, metadata_list)
        
        # Create catalog
        gen.create_catalog_json(output_dir, metadata_list)
        
        # Create README
        gen.create_readme(output_dir, metadata_list)
        
        # Verify all artifacts exist
        assert (output_dir / 'Messages').exists()
        assert (output_dir / 'Envelope Index').exists()
        assert (output_dir / 'catalog.json').exists()
        assert (output_dir / 'README.md').exists()
        
        # Verify .emlx files
        emlx_files = list(messages_dir.glob('*.emlx'))
        assert len(emlx_files) == 10
        
        # Verify catalog
        catalog = json.loads((output_dir / 'catalog.json').read_text())
        assert catalog['total_emails'] == 10
        assert len(catalog['emails']) == 10
        
        # Verify README
        readme_content = (output_dir / 'README.md').read_text()
        assert 'Email Collector Test Fixtures' in readme_content
        assert 'Total emails: 10' in readme_content


def test_calculate_emlx_size():
    """Test .emlx size calculation"""
    content = "Hello, World!"
    size = gen.calculate_emlx_size(content)
    assert size == len(content.encode('utf-8'))
    
    # Test with unicode
    content_unicode = "Hello, 世界! 🌍"
    size_unicode = gen.calculate_emlx_size(content_unicode)
    assert size_unicode == len(content_unicode.encode('utf-8'))
    assert size_unicode > len(content_unicode)  # Multi-byte chars


def test_templates_have_realistic_content():
    """Test that templates contain realistic email patterns"""
    base_date = datetime.now(timezone.utc)
    
    # Receipt should have order numbers and amounts
    receipt = gen.create_receipt_template(0, base_date)
    assert "ORD-" in receipt.body_plain
    assert "$" in receipt.body_plain
    
    # Bill should have account numbers and amounts
    bill = gen.create_bill_template(0, base_date)
    assert "****" in bill.body_plain  # Masked account number
    assert "$" in bill.body_plain
    assert "Due" in bill.subject or "Due" in bill.body_plain
    
    # Appointment should have dates and times
    appt = gen.create_appointment_template(0, base_date)
    assert "Confirmation" in appt.body_plain
    
    # Promotional should have unsubscribe
    promo = gen.create_promotional_template(0, base_date)
    assert promo.list_unsubscribe is not None
    assert "unsubscribe" in promo.body_plain.lower()
    
    # Notification should have tracking info
    notif = gen.create_notification_template(0, base_date)
    assert "TRACK" in notif.body_plain or "track" in notif.body_plain.lower()
    
    # Action request should have codes/links
    action = gen.create_action_request_template(0, base_date)
    assert "verify" in action.body_plain.lower() or "confirm" in action.body_plain.lower()
