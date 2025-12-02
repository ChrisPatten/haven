"""LLM-driven search query translation and planning."""

from __future__ import annotations

import json
from typing import Any, Dict, List, Optional

from shared.haven_llm import LLMError, OpenAISettings, get_llm_provider
from shared.logging import get_logger

from .models_v2 import FacetFilter, FacetRange, SearchPlan

logger = get_logger("search.planner")


class SearchPlanner:
    """Translates natural language questions into structured search plans using LLM."""

    def __init__(self, model: str = "gpt-5-nano-2025-08-07"):
        """Initialize search planner.
        
        Args:
            model: OpenAI model to use (default: gpt-5-nano-2025-08-07)
        """
        settings = OpenAISettings(model=model)
        self._provider = get_llm_provider(provider_type="openai", settings=settings)
        self._model = model

    def plan_search(
        self,
        question: str,
        prior_filters: Optional[List[FacetFilter]] = None,
        conversation_metadata: Optional[Dict[str, Any]] = None,
    ) -> SearchPlan:
        """Translate natural language question into a search plan.
        
        Args:
            question: User's natural language question
            prior_filters: Previously inferred filters from conversation
            conversation_metadata: Optional conversation context
            
        Returns:
            SearchPlan with query text, filters, and strategy hints
            
        Raises:
            LLMError: If LLM translation fails
        """
        prompt = self._build_prompt(question, prior_filters, conversation_metadata)
        
        try:
            response = self._provider.generate(
                prompt=prompt,
                format="json",
                system_prompt=self._get_system_prompt(),
            )
            
            # Extract JSON from response (may be wrapped in markdown code blocks)
            text = response.text.strip()
            
            # Remove markdown code blocks if present
            if text.startswith("```"):
                # Find the first ``` and last ```
                start_idx = text.find("```")
                if start_idx >= 0:
                    # Skip language identifier if present
                    end_marker = text.find("\n", start_idx + 3)
                    if end_marker > 0:
                        text = text[end_marker + 1:]
                # Find closing ```
                end_idx = text.rfind("```")
                if end_idx >= 0:
                    text = text[:end_idx].strip()
            
            plan_dict = json.loads(text)
            return self._parse_search_plan(plan_dict, question)
            
        except json.JSONDecodeError as e:
            logger.error(
                "planner_json_parse_error",
                error=str(e),
                response_text=response.text[:500] if hasattr(response, 'text') else None,
            )
            raise LLMError(f"Failed to parse LLM response as JSON: {e}") from e
        except Exception as e:
            logger.error("planner_error", error=str(e), question=question[:100])
            raise LLMError(f"Search planning failed: {e}") from e

    def _build_prompt(
        self,
        question: str,
        prior_filters: Optional[List[FacetFilter]],
        conversation_metadata: Optional[Dict[str, Any]],
    ) -> str:
        """Build the prompt for LLM translation."""
        parts = [f"Question: {question}"]
        
        if prior_filters:
            parts.append("Prior filters:")
            for f in prior_filters:
                if f.name in ("source_type", "content_timestamp"):
                    if f.values:
                        parts.append(f"  {f.name}: {f.values}")
                    elif f.range:
                        parts.append(f"  {f.name}: {f.range.start} to {f.range.end}")
        
        parts.extend([
            "",
            "Return JSON only:",
            "{",
            '  "keyword_query": "keywords for text search",',
            '  "similarity_query": "query for semantic search",',
            '  "source_type": "imessage|email|files|null",',
            '  "timeframe": {"start": "ISO8601", "end": "ISO8601"} | null',
            "}",
        ])
        
        return "\n".join(parts)

    def _get_system_prompt(self) -> str:
        """Get the system prompt for the LLM."""
        return """Translate questions into search queries for a personal knowledge base (iMessages, emails, files).

Generate:
- keyword_query: Keywords for lexical search (extract/propose key terms)
- similarity_query: Natural query for semantic/vector search (rephrase question/keywords as appropriate)
- source_type: Filter by source if mentioned (imessage, email, files) or null
- timeframe: Date range if mentioned (ISO8601 format) or null

Corpus: User's iMessages, emails, and local files. Return JSON only."""

    def _parse_search_plan(self, plan_dict: Dict[str, Any], original_question: str) -> SearchPlan:
        """Parse LLM response into SearchPlan."""
        # Build facet filters from simplified structure
        facet_filters = []
        
        # Source type filter
        source_type = plan_dict.get("source_type")
        if source_type and source_type != "null":
            facet_filters.append(
                FacetFilter(
                    name="source_type",
                    type="term",
                    values=[source_type],
                )
            )
        
        # Timeframe filter
        timeframe = plan_dict.get("timeframe")
        if timeframe and timeframe != "null":
            if isinstance(timeframe, dict):
                range_obj = FacetRange(
                    start=timeframe.get("start", ""),
                    end=timeframe.get("end", ""),
                    start_inclusive=True,
                    end_inclusive=True,
                )
                facet_filters.append(
                    FacetFilter(
                        name="content_timestamp",
                        type="range",
                        range=range_obj,
                    )
                )
        
        # Extract queries
        keyword_query = plan_dict.get("keyword_query") or plan_dict.get("query_text") or original_question
        similarity_query = plan_dict.get("similarity_query") or keyword_query
        
        return SearchPlan(
            keyword_query=keyword_query,
            similarity_query=similarity_query,
            facet_filters=facet_filters,
            retrieval_strategy="hybrid",
            summarization_intent="summary",
        )

def get_search_planner() -> SearchPlanner:
    """Get a SearchPlanner instance."""
    return SearchPlanner()

