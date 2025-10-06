from __future__ import annotations

import contextlib
import os
from typing import Iterator

import psycopg


DEFAULT_CONN_STR = "postgresql://postgres:postgres@localhost:5432/haven"


def get_conn_str() -> str:
    return os.getenv("DATABASE_URL", DEFAULT_CONN_STR)


@contextlib.contextmanager
def get_connection(autocommit: bool = True) -> Iterator[psycopg.Connection]:
    conn = psycopg.connect(get_conn_str())
    conn.autocommit = autocommit
    try:
        yield conn
    finally:
        conn.close()


@contextlib.contextmanager
def get_cursor(autocommit: bool = True) -> Iterator[psycopg.Cursor]:
    with get_connection(autocommit=autocommit) as conn:
        with conn.cursor() as cur:
            yield cur
