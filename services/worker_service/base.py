"""Base worker framework for Haven worker services."""
from __future__ import annotations

import os
import socket
import time
from abc import ABC, abstractmethod
from typing import Any, Generic, List, TypeVar

import psycopg
from pydantic import BaseModel, Field

from shared.db import get_conn_str
from shared.logging import get_logger, setup_logging

logger = get_logger("worker.service")

# Type variable for job types
JobType = TypeVar("JobType")


class WorkerSettings(BaseModel):
    """Base settings for all workers."""
    database_url: str = Field(default_factory=get_conn_str)
    catalog_base_url: str = Field(default_factory=lambda: os.getenv("CATALOG_BASE_URL", "http://catalog:8081"))
    catalog_token: str | None = Field(default_factory=lambda: os.getenv("CATALOG_TOKEN"))
    poll_interval: float = Field(default_factory=lambda: float(os.getenv("WORKER_POLL_INTERVAL", "2.0")))
    batch_size: int = Field(default_factory=lambda: int(os.getenv("WORKER_BATCH_SIZE", "8")))


class BaseWorker(ABC, Generic[JobType]):
    """Abstract base class for worker implementations."""
    
    def __init__(self, settings: WorkerSettings):
        self.settings = settings
        self.worker_id = self._worker_id()
        self.logger = get_logger(f"worker.{self.worker_type()}")
    
    @staticmethod
    def _worker_id() -> str:
        """Generate a unique worker ID."""
        hostname = socket.gethostname()
        pid = os.getpid()
        return f"{hostname}:{pid}"
    
    @abstractmethod
    def worker_type(self) -> str:
        """Return the worker type identifier (e.g., 'embedding', 'intents')."""
        pass
    
    @abstractmethod
    def dequeue_jobs(self, conn: psycopg.Connection, limit: int) -> List[JobType]:
        """Dequeue jobs from the database using FOR UPDATE SKIP LOCKED."""
        pass
    
    @abstractmethod
    def process_job(self, job: JobType) -> None:
        """Process a single job."""
        pass
    
    @abstractmethod
    def mark_job_failed(self, conn: psycopg.Connection, job: JobType, error_message: str) -> None:
        """Mark a job as failed in the database."""
        pass
    
    def run(self) -> None:
        """Main worker loop."""
        setup_logging()
        self.logger.info(
            f"{self.worker_type()}_service_start",
            worker_id=self.worker_id,
            catalog_base=self.settings.catalog_base_url,
            poll_interval=self.settings.poll_interval,
            batch_size=self.settings.batch_size,
        )
        
        while True:
            jobs: List[JobType] = []
            try:
                with psycopg.connect(self.settings.database_url) as conn:
                    conn.autocommit = False
                    jobs = self.dequeue_jobs(conn, self.settings.batch_size)
            except Exception as exc:  # pragma: no cover - defensive logging
                self.logger.error(f"{self.worker_type()}_job_dequeue_failed", error=str(exc))
                time.sleep(self.settings.poll_interval)
                continue
            
            if not jobs:
                time.sleep(self.settings.poll_interval)
                continue
            
            for job in jobs:
                try:
                    self.process_job(job)
                    self.logger.info(f"{self.worker_type()}_job_completed", job_id=str(job))
                except Exception as exc:  # pragma: no cover - error path
                    self.logger.error(
                        f"{self.worker_type()}_job_failed",
                        job_id=str(job),
                        error=str(exc),
                    )
                    try:
                        with psycopg.connect(self.settings.database_url) as conn:
                            conn.autocommit = False
                            self.mark_job_failed(conn, job, str(exc))
                    except Exception as db_exc:  # pragma: no cover
                        self.logger.error(
                            f"{self.worker_type()}_job_failure_mark_failed",
                            job_id=str(job),
                            error=str(db_exc),
                        )
                        # last resort: sleep briefly to avoid hot loop
                        time.sleep(1.0)
            
            # small pause to avoid immediate tight loop between batches
            time.sleep(0.01)

