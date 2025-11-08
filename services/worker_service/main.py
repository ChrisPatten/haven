"""Main entry point for worker service.

Supports multiple worker types:
- embedding: Vectorizes document chunks
- intents: Processes document intent classification

Worker type is determined by WORKER_TYPE environment variable (default: embedding).
"""
from __future__ import annotations

import os
import sys

from services.worker_service.workers.embedding import EmbeddingWorker, EmbeddingWorkerSettings
from services.worker_service.workers.intents import IntentsWorker, IntentsWorkerSettings


def main() -> None:
    """Run the appropriate worker based on WORKER_TYPE environment variable."""
    worker_type = os.getenv("WORKER_TYPE", "embedding").lower()
    
    if worker_type == "embedding":
        worker = EmbeddingWorker(EmbeddingWorkerSettings())
        worker.run()
    elif worker_type == "intents":
        worker = IntentsWorker(IntentsWorkerSettings())
        worker.run()
    else:
        print(f"Unknown worker type: {worker_type}", file=sys.stderr)
        print("Supported types: embedding, intents", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

