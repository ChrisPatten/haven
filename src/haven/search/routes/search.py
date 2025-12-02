from __future__ import annotations

from datetime import datetime
from functools import lru_cache
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status

from ..models import PageCursor, QueryFilter, RangeFilter, SearchRequest, SearchResult, SearchVectorQuery
from ..services.hybrid import HybridSearchService
from services.search_service.context_expander import get_context_expander
from services.search_service.conversation_store import get_conversation_store
from services.search_service.facet_aggregator import get_facet_aggregator
from services.search_service.models_v2 import (
    FacetFilter,
    SearchConverseRequest,
    SearchConverseResponse,
    SearchFacetsRequest,
    SearchFacetsResponse,
)
from services.search_service.search_planner import LLMError, get_search_planner
from shared.logging import get_logger
from .ingest import get_org_id

router = APIRouter(prefix="/v1/search", tags=["search"])
logger = get_logger("search.routes")


@lru_cache(maxsize=1)
def get_service() -> HybridSearchService:
    return HybridSearchService()


def _convert_facet_filters_to_query_filters(facet_filters: list[FacetFilter]) -> list[QueryFilter]:
    """Convert FacetFilter objects to QueryFilter objects for search service."""
    query_filters = []
    for ff in facet_filters:
        if ff.type == "term":
            # For term filters, create QueryFilter for each value
            for value in ff.values:
                query_filters.append(QueryFilter(term=ff.name, value=value))
        elif ff.type == "range" and ff.range:
            # For range filters
            gte = None
            lte = None
            try:
                if ff.range.start:
                    gte = datetime.fromisoformat(ff.range.start.replace("Z", "+00:00"))
                if ff.range.end:
                    lte = datetime.fromisoformat(ff.range.end.replace("Z", "+00:00"))
            except ValueError:
                logger.warning("invalid_date_range", range=ff.range.model_dump())
                continue
            
            query_filters.append(
                QueryFilter(
                    range=RangeFilter(
                        field=ff.name,
                        gte=gte,
                        lte=lte,
                    )
                )
            )
        elif ff.type == "boolean":
            # For boolean filters, use the first value
            if ff.values:
                bool_value = ff.values[0].lower() == "true"
                query_filters.append(QueryFilter(term=ff.name, value=str(bool_value)))
    return query_filters


@router.post("/query", response_model=SearchResult)
async def query(
    request: SearchRequest,
    org_id: str = Depends(get_org_id),
    service: HybridSearchService = Depends(get_service),
) -> SearchResult:
    if not request.query and not request.vector:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="query or vector must be provided")
    return await service.search(org_id=org_id, request=request)


@router.post("/similar", response_model=SearchResult)
async def similar(
    request: SearchRequest,
    org_id: str = Depends(get_org_id),
    service: HybridSearchService = Depends(get_service),
) -> SearchResult:
    if not request.vector:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="vector spec required for /similar")
    return await service.search(org_id=org_id, request=request)


@router.post("/converse", response_model=SearchConverseResponse)
async def converse(
    request: SearchConverseRequest,
    org_id: str = Depends(get_org_id),
    service: HybridSearchService = Depends(get_service),
) -> SearchConverseResponse:
    """Conversational search endpoint with LLM-driven query translation."""
    try:
        # Get conversation state
        store = get_conversation_store()
        conversation_state = None
        if request.conversation_id:
            conversation_state = store.get_conversation(request.conversation_id)
        
        if not conversation_state:
            conversation_state = store.create_conversation()
        
        # Merge request filters with conversation filters
        all_filters = list(request.facet_filters)
        if conversation_state.latest_filters:
            # Merge: request filters take precedence
            existing_filter_names = {f.name for f in all_filters}
            for cf in conversation_state.latest_filters:
                if cf.name not in existing_filter_names:
                    all_filters.append(cf)
        
        # Plan search using LLM
        planner = get_search_planner()
        try:
            search_plan = planner.plan_search(
                question=request.question,
                prior_filters=conversation_state.latest_filters,
                conversation_metadata=conversation_state.conversation_metadata,
            )
        except LLMError as e:
            logger.error("planner_failed", error=str(e), question=request.question[:100])
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=f"Search planning failed: {str(e)}",
            ) from e
        
        # Merge planner filters with request filters (request takes precedence)
        planner_filter_names = {f.name for f in search_plan.facet_filters}
        final_filters = list(search_plan.facet_filters)
        for rf in all_filters:
            if rf.name not in planner_filter_names:
                final_filters.append(rf)
        
        # Convert to QueryFilter format
        query_filters = _convert_facet_filters_to_query_filters(final_filters)
        
        # Build search request
        search_request = SearchRequest(
            query=search_plan.keyword_query,
            filter=query_filters,
            vector=SearchVectorQuery(text=search_plan.similarity_query, weight=1.0),
            page=PageCursor(size=request.top_k),
            facets=["person", "source_type", "has_attachments", "thread_id"],
        )
        
        # Execute search
        search_result = await service.search(org_id=org_id, request=search_request)
        
        # Expand context for iMessage hits
        context_expander = get_context_expander()
        context_hits = await context_expander.expand_imessage_context(search_result.hits)
        
        # Combine hits
        all_hits = list(search_result.hits)
        all_hits.extend(context_hits)
        
        # Aggregate facets
        facet_aggregator = get_facet_aggregator()
        facets = facet_aggregator.aggregate_facets(
            hits=all_hits,
            active_filters=final_filters,
            facet_limit=10,
        )
        
        # Update conversation state
        conversation_state.latest_filters = final_filters
        store.save_conversation(conversation_state)
        
        # Build response
        # Convert SearchHit to dict format for response
        documents = []
        for hit in all_hits[:request.top_k]:
            if hasattr(hit, "model_dump"):
                documents.append(hit.model_dump())
            else:
                documents.append(hit)
        
        return SearchConverseResponse(
            query=search_plan.keyword_query,
            conversation_id=conversation_state.conversation_id,
            answer="",  # Answer synthesis is done by Custom GPT
            confidence=0.8,  # Placeholder
            documents=documents,
            document_count=len(all_hits),
            facets=facets,
            inferred_filters=search_plan.facet_filters,
            metadata={
                "retrieval_strategy": search_plan.retrieval_strategy,
                "summarization_intent": search_plan.summarization_intent,
            },
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error("converse_error", error=str(e), exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Conversational search failed: {str(e)}",
        ) from e


@router.post("/facets", response_model=SearchFacetsResponse)
async def facets(
    request: SearchFacetsRequest,
    org_id: str = Depends(get_org_id),
    service: HybridSearchService = Depends(get_service),
) -> SearchFacetsResponse:
    """Facet discovery endpoint for conversational search."""
    try:
        # Get conversation state
        store = get_conversation_store()
        conversation_state = None
        if request.conversation_id:
            conversation_state = store.get_conversation(request.conversation_id)
        
        # Merge filters
        all_filters = list(request.facet_filters)
        if conversation_state and conversation_state.latest_filters:
            existing_filter_names = {f.name for f in all_filters}
            for cf in conversation_state.latest_filters:
                if cf.name not in existing_filter_names:
                    all_filters.append(cf)
        
        # Optionally plan search to get query
        planner = get_search_planner()
        try:
            search_plan = planner.plan_search(
                question=request.question,
                prior_filters=all_filters,
                conversation_metadata=conversation_state.conversation_metadata if conversation_state else None,
            )
        except LLMError as e:
            logger.warning("planner_failed_facets", error=str(e))
            # Use question as query if planning fails
            search_plan = None
        
        # Build search request
        query_filters = _convert_facet_filters_to_query_filters(all_filters)
        search_request = SearchRequest(
            query=search_plan.query_text if search_plan else request.question,
            filter=query_filters,
            vector=SearchVectorQuery(
                text=search_plan.query_text if search_plan else request.question,
                weight=1.0,
            ),
            page=PageCursor(size=50),  # Get more results for better facet counts
            facets=["person", "source_type", "has_attachments", "thread_id"],
        )
        
        # Execute search
        search_result = await service.search(org_id=org_id, request=search_request)
        
        # Aggregate facets
        facet_aggregator = get_facet_aggregator()
        facets_list = facet_aggregator.aggregate_facets(
            hits=search_result.hits,
            active_filters=all_filters,
            facet_limit=request.facet_limit,
        )
        
        # Get or create conversation
        if not conversation_state:
            conversation_state = store.create_conversation()
        
        return SearchFacetsResponse(
            query=search_plan.query_text if search_plan else request.question,
            conversation_id=conversation_state.conversation_id,
            document_count=len(search_result.hits),
            facets=facets_list,
            metadata={},
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error("facets_error", error=str(e), exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Facet discovery failed: {str(e)}",
        ) from e


__all__ = ["router"]
