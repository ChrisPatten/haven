from __future__ import annotations

import shutil
from pathlib import Path
from typing import Dict, List

_generated_paths: List[Path] = []


def _project_root(config: Dict) -> Path:
    """Resolve the repository root from the MkDocs config."""
    config_file = Path(config["config_file_path"]).resolve()
    return config_file.parent


def _normalize_spec(raw_spec: Dict) -> Dict:
    """Ensure a spec configuration dict contains the keys we expect."""
    if isinstance(raw_spec, dict):
        spec = dict(raw_spec)
    else:
        # Allow shorthand string configuration: "openapi/gateway.yaml"
        spec = {"source": str(raw_spec)}
    source = Path(spec["source"])
    spec.setdefault("id", source.stem)
    spec.setdefault("output", f"openapi/{spec['id']}{source.suffix}")
    return spec


def prepare_openapi_assets(config: Dict) -> None:
    """Copy OpenAPI specs into the docs directory before building."""
    global _generated_paths
    _generated_paths = []

    specs = config.get("extra", {}).get("openapi_specs", [])
    if not specs:
        return

    project_root = _project_root(config)
    docs_dir = Path(config["docs_dir"]).resolve()

    for raw_spec in specs:
        spec = _normalize_spec(raw_spec)
        source = (project_root / spec["source"]).resolve()
        if not source.exists():
            raise FileNotFoundError(f"OpenAPI spec '{source}' was not found")

        destination = docs_dir / spec["output"]
        destination.parent.mkdir(parents=True, exist_ok=True)

        preexisting = destination.exists()
        shutil.copy2(source, destination)

        if not preexisting:
            _generated_paths.append(destination)


def cleanup_openapi_assets(config: Dict) -> None:
    """Remove generated OpenAPI artifacts after the build completes."""
    global _generated_paths

    for path in _generated_paths:
        try:
            path.unlink()
        except FileNotFoundError:
            continue

        # Clean up empty parent directories we created
        parent = path.parent
        while parent.name and parent.exists():
            try:
                parent.rmdir()
            except OSError:
                break
            parent = parent.parent

    _generated_paths = []
