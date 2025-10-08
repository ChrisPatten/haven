from __future__ import annotations

from typing import Iterable, List

import numpy as np
from sentence_transformers import SentenceTransformer

from ..config import get_settings
from ..models import ChunkInput


class Embedder:
    """Wrapper around SentenceTransformer with lazy initialization."""

    def __init__(self) -> None:
        self._settings = get_settings()
        self._model: SentenceTransformer | None = None

    @property
    def model(self) -> SentenceTransformer:
        if self._model is None:
            self._model = SentenceTransformer(self._settings.embedding_model)
        return self._model

    def encode(self, chunks: Iterable[ChunkInput]) -> List[np.ndarray]:
        texts = [chunk.text for chunk in chunks]
        return self.encode_texts(texts)

    def encode_texts(self, texts: Iterable[str]) -> List[np.ndarray]:
        texts = [text for text in texts if text]
        if not texts:
            return []
        embeddings = self.model.encode(texts, normalize_embeddings=True)
        if isinstance(embeddings, list):
            return [np.asarray(vec) for vec in embeddings]
        return [np.asarray(vec) for vec in embeddings]  # type: ignore[call-overload]


__all__ = ["Embedder"]
