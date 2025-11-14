"""Main entry point for worker service.

Supports multiple worker types:
- embedding: Vectorizes document chunks
- intents: Processes document intent classification

Worker type is determined by WORKER_TYPE environment variable:
- "embedding" - runs only embedding worker
- "intents" - runs only intents worker
- "both" or unset/default - runs both workers in parallel
"""
from __future__ import annotations

import os
import sys
import threading

from services.worker_service.workers.embedding import EmbeddingWorker, EmbeddingWorkerSettings
from services.worker_service.workers.intents import IntentsWorker, IntentsWorkerSettings


def run_embedding_worker() -> None:
    """Run the embedding worker in a separate thread."""
    worker = EmbeddingWorker(EmbeddingWorkerSettings())
    worker.run()


def run_intents_worker() -> None:
    """Run the intents worker in a separate thread."""
    worker = IntentsWorker(IntentsWorkerSettings())
    worker.run()


def main() -> None:
    """Run the appropriate worker(s) based on WORKER_TYPE environment variable."""
    worker_type = os.getenv("WORKER_TYPE", "both").lower()
    
    if worker_type == "embedding":
        run_embedding_worker()
    elif worker_type == "intents":
        run_intents_worker()
    elif worker_type == "both":
        # Run both workers in parallel threads
        embedding_thread = threading.Thread(target=run_embedding_worker, daemon=True, name="embedding-worker")
        intents_thread = threading.Thread(target=run_intents_worker, daemon=True, name="intents-worker")
        
        embedding_thread.start()
        intents_thread.start()
        
        # Wait for both threads (they run indefinitely)
        try:
            embedding_thread.join()
            intents_thread.join()
        except KeyboardInterrupt:
            print("Shutting down workers...", file=sys.stderr)
            sys.exit(0)
    else:
        print(f"Unknown worker type: {worker_type}", file=sys.stderr)
        print("Supported types: embedding, intents, both", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

