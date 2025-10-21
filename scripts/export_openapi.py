# Export the FastAPI OpenAPI spec for the gateway to openapi/gateway.yaml and .json

import json
import sys
from pathlib import Path

# Ensure repo root is on sys.path
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

try:
    # Import the FastAPI app instance
    # Make the import tolerant: skip optional dependency assertions and provide
    # a minimal stub for 'minio' if it's not installed so the module import
    # won't fail when generating the OpenAPI spec in developer environments.
    import os

    os.environ.setdefault("HAVEN_SKIP_DEP_ASSERT", "1")

    try:
        import minio  # type: ignore
    except Exception:  # pragma: no cover - runtime fallback
        # Create a minimal stub package so 'from minio import Minio' and
        # 'from minio.error import S3Error' succeed in dev environments.
        import types

        minio_mod = types.ModuleType("minio")

        class _MinioStub:
            def __init__(self, *args, **kwargs):
                pass

        minio_mod.Minio = _MinioStub

        error_mod = types.ModuleType("minio.error")

        class _S3Error(Exception):
            pass

        error_mod.S3Error = _S3Error

        sys.modules["minio"] = minio_mod
        sys.modules["minio.error"] = error_mod

    # pdfminer is optional; provide a minimal stub with high_level.extract_text
    try:
        import pdfminer.high_level  # type: ignore
    except Exception:
        import types

        ph = types.ModuleType("pdfminer")
        ph_high = types.ModuleType("pdfminer.high_level")

        def _extract_text(*args, **kwargs):
            return ""

        ph_high.extract_text = _extract_text
        sys.modules["pdfminer"] = ph
        sys.modules["pdfminer.high_level"] = ph_high

    # psycopg may not be installed in the dev environment; provide a light stub
    try:
        import psycopg  # type: ignore
    except Exception:
        import types

        psy = types.ModuleType("psycopg")
        # Minimal placeholder to satisfy import, not functional
        sys.modules["psycopg"] = psy

    from services.gateway_api.app import app
except Exception as exc:  # pragma: no cover - make failure visible
    print("Failed to import gateway FastAPI app:", exc, file=sys.stderr)
    raise

out_dir = ROOT / "openapi"
out_dir.mkdir(parents=True, exist_ok=True)

openapi = app.openapi()

# Write JSON
json_path = out_dir / "gateway.json"
with json_path.open("w", encoding="utf-8") as fh:
    json.dump(openapi, fh, indent=2, ensure_ascii=False)
print(f"Wrote {json_path}")

# Try to write YAML if PyYAML available
try:
    import yaml

    yaml_path = out_dir / "gateway.yaml"
    with yaml_path.open("w", encoding="utf-8") as fh:
        yaml.safe_dump(openapi, fh, sort_keys=False)
    print(f"Wrote {yaml_path}")
except Exception:
    print("PyYAML not available; skipping YAML output (JSON written).", file=sys.stderr)

