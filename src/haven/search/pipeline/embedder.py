from __future__ import annotations

from typing import Iterable, List

import numpy as np
import httpx

from ..config import get_settings
from ..models import ChunkInput


class Embedder:
    """Embedder that calls an Ollama embedding endpoint to generate vectors.

    This mirrors the embedding_service worker behavior and keeps a thin client
    so search can synchronously request a single-text embedding when needed.
    """

    def __init__(self) -> None:
        self._settings = get_settings()

    def encode(self, chunks: Iterable[ChunkInput]) -> List[np.ndarray]:
        texts = [chunk.text for chunk in chunks]
        return self.encode_texts(texts)

    def encode_texts(self, texts: Iterable[str]) -> List[np.ndarray]:
        texts = [text for text in texts if text]
        if not texts:
            return []
        vectors: List[np.ndarray] = []
        # Use a short-lived HTTP client for each batch to call Ollama's embeddings API.
        import os

        base_url = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
        timeout = float(os.getenv("EMBEDDING_REQUEST_TIMEOUT", "15.0"))
        with httpx.Client(base_url=base_url, timeout=timeout) as client:
            for text in texts:
                resp = client.post(
                    "/api/embeddings",
                    json={"model": self._settings.embedding_model, "prompt": text},
                )
                resp.raise_for_status()
                data = resp.json()
                vec = data.get("embedding")
                if not isinstance(vec, list):
                    # defensive: skip malformed responses
                    continue
                vectors.append(np.asarray(vec))

        return vectors


__all__ = ["Embedder"]
