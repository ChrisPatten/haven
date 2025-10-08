import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

SRC = ROOT / "src"
if SRC.exists() and str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

# Allow local dev environments with all extras installed to import modules without
# tripping dependency isolation assertions.
import os

os.environ.setdefault("HAVEN_SKIP_DEP_ASSERT", "1")
