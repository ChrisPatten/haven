from __future__ import annotations

import typer
import uvicorn

from .app import create_app
from .config import get_settings

cli = typer.Typer(help="Search Service entrypoint")


@cli.command()
def serve(host: str = "0.0.0.0", port: int = 8080) -> None:
    """Start the Search Service using uvicorn."""

    settings = get_settings()
    app = create_app()
    uvicorn.run(app, host=host, port=port, log_level="info", lifespan="on")


if __name__ == "__main__":
    cli()
