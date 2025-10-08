from __future__ import annotations

from datetime import datetime

import pytest

from haven.search.models import Acl, DocumentUpsert


def test_document_upsert_requires_acl_org() -> None:
    doc = DocumentUpsert(
        document_id="doc-1",
        source_id="source-1",
        text="hello world",
        acl=Acl(org_id="org-1"),
    )
    assert doc.acl.org_id == "org-1"


def test_document_upsert_rejects_empty_chunks() -> None:
    with pytest.raises(ValueError):
        DocumentUpsert(
            document_id="doc-1",
            source_id="source-1",
            text=None,
            chunks=[],
            acl=Acl(org_id="org-1"),
        )
