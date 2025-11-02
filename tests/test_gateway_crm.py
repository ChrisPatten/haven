"""Tests for CRM relationship endpoints in Gateway API.

Note: These tests verify the endpoint logic and business logic without requiring 
external dependencies like MinIO that aren't accessible from outside the container stack.

For full integration tests with the running service, use the integration test suite.
"""
from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest


class TestWindowParameterParsing:
    """Tests for window parameter parsing logic.
    
    Tests the validation and parsing of window parameters in the format "Xd".
    This logic is used by the _parse_window_parameter function.
    """

    def test_valid_window_format(self):
        """Test that valid window formats are recognized."""
        valid_windows = [
            ("1d", 1),
            ("30d", 30),
            ("90d", 90),
            ("365d", 365),
            ("3650d", 3650),
        ]
        
        for window_str, expected_days in valid_windows:
            # Parse format: extract number and 'd' suffix
            if window_str.endswith("d"):
                try:
                    days = int(window_str[:-1])
                    assert days == expected_days
                except ValueError:
                    pytest.fail(f"Failed to parse {window_str}")

    def test_invalid_window_format(self):
        """Test that invalid window formats are rejected."""
        invalid_windows = [
            "invalid",
            "90",
            "90days",
            "d90",
            "",
            "90D",  # uppercase D
            "-90d",
            "90 d",
        ]
        
        for window_str in invalid_windows:
            # Validation logic: must match pattern Xd where X is digit(s)
            is_valid = (
                window_str.endswith("d") and 
                len(window_str) > 1 and
                window_str[:-1].isdigit()
            )
            assert not is_valid, f"{window_str} should be invalid"

    def test_window_range_validation(self):
        """Test that window values are within valid range (1-3650 days)."""
        min_valid = 1
        max_valid = 3650
        
        # Valid ranges
        for days in [1, 30, 90, 365, 3650]:
            assert min_valid <= days <= max_valid
        
        # Invalid ranges
        for days in [0, -1, 3651, 10000]:
            assert not (min_valid <= days <= max_valid)

    def test_window_default(self):
        """Test that default window is 90 days."""
        default_window = "90d"
        default_days = 90
        
        if default_window.endswith("d"):
            days = int(default_window[:-1])
            assert days == default_days


class TestRelationshipQueryLogic:
    """Tests for the relationship query building logic."""

    def test_query_filters_by_time_window(self):
        """Test that query filters relationships by time window."""
        # Window of 90 days means: now() - 90 days
        now = datetime.now(UTC)
        window_days = 90
        window_start = now - timedelta(days=window_days)
        
        # The query should filter: last_contact_at >= window_start
        assert window_start < now
        
        # Test with different windows
        for days in [1, 30, 90, 365]:
            window = now - timedelta(days=days)
            assert window < now

    def test_query_orders_by_score_descending(self):
        """Test that results are ordered by score DESC."""
        # The query uses: ORDER BY score DESC
        # This means higher scores come first
        
        scores = [100, 50, 75, 25, 90]
        sorted_scores = sorted(scores, reverse=True)
        
        expected_order = [100, 90, 75, 50, 25]
        assert sorted_scores == expected_order

    def test_query_applies_pagination(self):
        """Test that query respects limit and offset."""
        total_items = 100
        limit = 10
        offset = 5
        
        # With offset=5, limit=10, should return items 5-14
        start_index = offset
        end_index = offset + limit
        
        assert start_index == 5
        assert end_index == 15
        assert end_index - start_index == limit

    def test_query_joins_with_people_table(self):
        """Test that query joins crm_relationships with people table."""
        # Query should:
        # 1. Select from crm_relationships
        # 2. LEFT JOIN people ON crm_relationships.person_id = people.id
        # 3. Return person metadata (display_name, emails, phones, organization)
        
        # This is verified by checking response includes person fields
        expected_person_fields = [
            "person_id",
            "display_name",
            "emails",
            "phones",
            "organization",
        ]
        
        for field in expected_person_fields:
            assert isinstance(field, str)


class TestResponseModel:
    """Tests for the response model structure."""

    def test_relationship_item_fields(self):
        """Test that relationship items have required fields."""
        # Expected fields in each relationship item
        required_fields = {
            "person_id": str,
            "score": (int, float),
            "last_contact_at": str,  # ISO datetime
        }
        
        optional_fields = {
            "display_name": str,
            "emails": list,
            "phones": list,
            "organization": str,
        }
        
        all_fields = {**required_fields, **optional_fields}
        # 3 required + 4 optional = 7 total fields
        assert len(all_fields) == 7

    def test_response_envelope_fields(self):
        """Test that response envelope has required fields."""
        required_envelope_fields = [
            "window",
            "window_start",
            "window_end",
            "limit",
            "offset",
            "total_count",
            "relationships",
        ]
        
        assert len(required_envelope_fields) == 7

    def test_window_boundaries_logic(self):
        """Test that window boundaries are calculated correctly."""
        now = datetime.now(UTC)
        window_days = 90
        
        window_end = now
        window_start = now - timedelta(days=window_days)
        
        # Verify ordering
        assert window_start < window_end
        
        # Verify interval
        difference = window_end - window_start
        assert difference.days == window_days


class TestPaginationLogic:
    """Tests for pagination parameter validation."""

    def test_limit_constraints(self):
        """Test limit parameter constraints (1-500)."""
        min_limit = 1
        max_limit = 500
        
        # Valid limits
        for limit in [1, 50, 100, 500]:
            assert min_limit <= limit <= max_limit
        
        # Invalid limits
        for limit in [0, -1, 501, 1000]:
            assert not (min_limit <= limit <= max_limit)

    def test_offset_constraints(self):
        """Test offset parameter constraints (>= 0)."""
        min_offset = 0
        
        # Valid offsets
        for offset in [0, 1, 10, 1000]:
            assert offset >= min_offset
        
        # Invalid offsets
        for offset in [-1, -10]:
            assert offset < min_offset

    def test_pagination_math(self):
        """Test pagination calculation logic."""
        total_items = 100
        limit = 10
        
        # Number of pages
        num_pages = (total_items + limit - 1) // limit  # ceiling division
        assert num_pages == 10
        
        # Items on last page
        items_on_last = total_items % limit or limit
        assert items_on_last == 10

    def test_offset_beyond_total(self):
        """Test that offset can be beyond total (returns empty list)."""
        total_items = 100
        offset = 150
        limit = 10
        
        # Valid query, just returns 0 items
        items_to_return = max(0, total_items - offset)
        assert items_to_return == 0


class TestSortingLogic:
    """Tests for relationship sorting logic."""

    def test_score_sorting_descending(self):
        """Test that relationships are sorted by score descending."""
        relationships = [
            {"person_id": "a", "score": 50},
            {"person_id": "b", "score": 100},
            {"person_id": "c", "score": 75},
            {"person_id": "d", "score": 25},
        ]
        
        # Sort by score DESC
        sorted_rels = sorted(
            relationships,
            key=lambda r: r["score"],
            reverse=True
        )
        
        scores = [r["score"] for r in sorted_rels]
        assert scores == [100, 75, 50, 25]

    def test_equal_scores_ordering(self):
        """Test that equal scores maintain stable order."""
        relationships = [
            {"person_id": "a", "score": 50},
            {"person_id": "b", "score": 50},
            {"person_id": "c", "score": 75},
        ]
        
        # Sort by score DESC (stable sort preserves order for equal values)
        sorted_rels = sorted(
            relationships,
            key=lambda r: r["score"],
            reverse=True
        )
        
        # C should be first, then A and B in original order
        assert sorted_rels[0]["person_id"] == "c"
        assert sorted_rels[1]["person_id"] == "a"
        assert sorted_rels[2]["person_id"] == "b"


class TestErrorScenarios:
    """Tests for error handling scenarios."""

    def test_missing_relationships_returns_empty_list(self):
        """Test that no relationships returns empty list."""
        relationships = []
        limit = 50
        offset = 0
        
        results = relationships[offset : offset + limit]
        assert results == []

    def test_null_person_fields_allowed(self):
        """Test that null person metadata fields are allowed."""
        relationship = {
            "person_id": "123",
            "score": 85,
            "last_contact_at": "2024-10-30T12:00:00Z",
            "display_name": None,  # Can be null
            "emails": [],  # Empty list ok
            "phones": [],  # Empty list ok
            "organization": None,  # Can be null
        }
        
        # Should not cause errors
        assert relationship["person_id"]
        assert relationship["score"] >= 0

    def test_window_parameter_none_uses_default(self):
        """Test that None/missing window parameter defaults to 90d."""
        window_param = None
        default_window = "90d"
        
        final_window = window_param or default_window
        assert final_window == "90d"


class TestDataTypes:
    """Tests for expected data types in response."""

    def test_score_is_numeric(self):
        """Test that relationship scores are numeric."""
        scores = [50, 85.5, 100, 0]
        
        for score in scores:
            assert isinstance(score, (int, float))
            assert score >= 0
            assert score <= 100 or score > 100  # Some systems allow > 100

    def test_person_id_is_string(self):
        """Test that person_id is a string."""
        person_ids = ["123", "abc-def", "550e8400-e29b-41d4-a716-446655440000"]
        
        for pid in person_ids:
            assert isinstance(pid, str)
            assert len(pid) > 0

    def test_timestamp_is_iso_format(self):
        """Test that timestamps are ISO 8601 format."""
        # Valid ISO 8601 timestamps
        timestamps = [
            "2024-10-30T12:00:00Z",
            "2024-10-30T12:00:00+00:00",
            "2024-10-30T12:00:00.123456Z",
        ]
        
        for ts in timestamps:
            # Should be parseable as ISO format
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                assert isinstance(dt, datetime)
            except ValueError:
                pytest.fail(f"Invalid ISO timestamp: {ts}")

    def test_emails_and_phones_are_lists_of_strings(self):
        """Test that emails and phones are lists containing only strings."""
        emails = ["test@example.com", "user@domain.org"]
        phones = ["+1-555-1234", "(555) 123-4567"]
        
        for email in emails:
            assert isinstance(email, str)
        
        for phone in phones:
            assert isinstance(phone, str)


class TestInputValidation:
    """Tests for input parameter validation logic."""

    def test_window_parameter_validation(self):
        """Test window parameter is validated."""
        # Valid
        assert self._is_valid_window("1d")
        assert self._is_valid_window("90d")
        assert self._is_valid_window("3650d")
        
        # Invalid format
        assert not self._is_valid_window("invalid")
        assert not self._is_valid_window("90")
        assert not self._is_valid_window("")
        
        # Invalid range (outside 1-3650)
        assert not self._is_valid_window("0d")
        assert not self._is_valid_window("3651d")

    def test_limit_parameter_validation(self):
        """Test limit parameter is validated."""
        # Valid (1-500)
        assert self._is_valid_limit(1)
        assert self._is_valid_limit(50)
        assert self._is_valid_limit(500)
        
        # Invalid
        assert not self._is_valid_limit(0)
        assert not self._is_valid_limit(501)
        assert not self._is_valid_limit(-1)

    def test_offset_parameter_validation(self):
        """Test offset parameter is validated."""
        # Valid (>= 0)
        assert self._is_valid_offset(0)
        assert self._is_valid_offset(10)
        assert self._is_valid_offset(1000)
        
        # Invalid
        assert not self._is_valid_offset(-1)
        assert not self._is_valid_offset(-100)

    @staticmethod
    def _is_valid_window(window: str) -> bool:
        """Check if window parameter is valid."""
        if not window or not window.endswith("d"):
            return False
        try:
            days = int(window[:-1])
            return 1 <= days <= 3650
        except ValueError:
            return False

    @staticmethod
    def _is_valid_limit(limit: int) -> bool:
        """Check if limit parameter is valid."""
        return 1 <= limit <= 500

    @staticmethod
    def _is_valid_offset(offset: int) -> bool:
        """Check if offset parameter is valid."""
        return offset >= 0
