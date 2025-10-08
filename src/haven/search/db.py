from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Any, AsyncIterator, Awaitable, Callable, TypeVar

import psycopg

from .config import get_settings

T = TypeVar("T")


@asynccontextmanager
async def get_connection() -> AsyncIterator[psycopg.AsyncConnection[Any]]:
    settings = get_settings()
    conn = await psycopg.AsyncConnection.connect(settings.database_url)
    try:
        yield conn
    finally:
        await conn.close()


async def run_in_transaction(fn: Callable[[psycopg.AsyncConnection[Any]], Awaitable[T]]) -> T:
    async with get_connection() as conn:
        async with conn.transaction():
            return await fn(conn)


__all__ = ["get_connection", "run_in_transaction"]
