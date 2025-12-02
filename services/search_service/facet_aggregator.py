"""Facet aggregation and counting from search results."""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime
from typing import Any, Dict, List, Optional
from uuid import UUID

from shared.logging import get_logger

from .models_v2 import Facet, FacetFilter, FacetRange, FacetValue

logger = get_logger("search.facets")


class FacetAggregator:
    """Aggregates facet counts from search result hits."""

    # Standard facet definitions
    FACET_DEFINITIONS = {
        "person": {
            "name": "person",
            "display_name": "People",
            "type": "term",
        },
        "source_type": {
            "name": "source_type",
            "display_name": "Source Type",
            "type": "term",
        },
        "has_attachments": {
            "name": "has_attachments",
            "display_name": "Has Attachments",
            "type": "boolean",
        },
        "thread_id": {
            "name": "thread_id",
            "display_name": "Thread",
            "type": "term",
        },
    }

    def aggregate_facets(
        self,
        hits: List[Any],  # SearchHit from haven.search
        active_filters: List[FacetFilter],
        facet_limit: int = 5,
    ) -> List[Facet]:
        """Aggregate facets from search hits.
        
        Args:
            hits: List of SearchHit objects from search results
            active_filters: Currently active facet filters
            facet_limit: Maximum number of values per facet
            
        Returns:
            List of Facet objects with counts and selected flags
        """
        # Extract facet values from hits
        facet_values: Dict[str, Dict[str, int]] = defaultdict(lambda: defaultdict(int))
        
        for hit in hits:
            metadata = hit.metadata if hasattr(hit, "metadata") else {}
            
            # Extract people
            people = metadata.get("people", [])
            if isinstance(people, list):
                for person in people:
                    if isinstance(person, dict):
                        identifier = person.get("identifier") or person.get("display_name")
                        if identifier:
                            facet_values["person"][identifier] += 1
                    elif isinstance(person, str):
                        facet_values["person"][person] += 1
            
            # Extract source_type
            source_type = metadata.get("source_type")
            if source_type:
                facet_values["source_type"][str(source_type)] += 1
            
            # Extract has_attachments
            has_attachments = metadata.get("has_attachments", False)
            facet_values["has_attachments"][str(has_attachments).lower()] += 1
            
            # Extract thread_id
            thread_id = metadata.get("thread_id")
            if thread_id:
                facet_values["thread_id"][str(thread_id)] += 1
            
            # Extract tags from metadata
            tags = metadata.get("tags", [])
            if isinstance(tags, list):
                for tag in tags:
                    if tag:
                        facet_values["tags"][str(tag)] += 1
        
        # Build facet objects
        facets = []
        
        # Process standard facets
        for facet_name, facet_def in self.FACET_DEFINITIONS.items():
            values_dict = facet_values.get(facet_name, {})
            if not values_dict:
                continue
            
            # Get active filter for this facet
            active_filter = next(
                (f for f in active_filters if f.name == facet_name),
                None,
            )
            
            # Build facet values
            facet_value_list = []
            for value, count in sorted(
                values_dict.items(),
                key=lambda x: (-x[1], x[0]),  # Sort by count desc, then value asc
            )[:facet_limit]:
                is_selected = (
                    active_filter is not None
                    and value in active_filter.values
                    if active_filter
                    else False
                )
                
                facet_value_list.append(
                    FacetValue(
                        value=value,
                        display_name=self._format_display_name(facet_name, value),
                        count=count,
                        selected=is_selected,
                    )
                )
            
            if facet_value_list:
                selected_values = [
                    fv.value for fv in facet_value_list if fv.selected
                ]
                
                facets.append(
                    Facet(
                        name=facet_name,
                        display_name=facet_def["display_name"],
                        type=facet_def["type"],
                        values=facet_value_list,
                        selected_values=selected_values,
                    )
                )
        
        # Process tags facet if present
        if "tags" in facet_values:
            tags_dict = facet_values["tags"]
            active_filter = next(
                (f for f in active_filters if f.name == "tags"),
                None,
            )
            
            facet_value_list = []
            for value, count in sorted(
                tags_dict.items(),
                key=lambda x: (-x[1], x[0]),
            )[:facet_limit]:
                is_selected = (
                    active_filter is not None
                    and value in active_filter.values
                    if active_filter
                    else False
                )
                
                facet_value_list.append(
                    FacetValue(
                        value=value,
                        display_name=value,
                        count=count,
                        selected=is_selected,
                    )
                )
            
            if facet_value_list:
                selected_values = [
                    fv.value for fv in facet_value_list if fv.selected
                ]
                
                facets.append(
                    Facet(
                        name="tags",
                        display_name="Tags",
                        type="term",
                        values=facet_value_list,
                        selected_values=selected_values,
                    )
                )
        
        return facets

    def _format_display_name(self, facet_name: str, value: str) -> str:
        """Format display name for facet value."""
        if facet_name == "has_attachments":
            return "Yes" if value.lower() == "true" else "No"
        if facet_name == "source_type":
            # Capitalize source type
            return value.replace("_", " ").title()
        return value


def get_facet_aggregator() -> FacetAggregator:
    """Get a FacetAggregator instance."""
    return FacetAggregator()

