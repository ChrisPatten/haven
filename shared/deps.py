from __future__ import annotations

import os
import logging
from importlib import metadata
from typing import Iterable


logger = logging.getLogger("shared.deps")


def assert_missing_dependencies(distributions: Iterable[str], scope: str) -> None:
    """Warn if the provided distributions are installed in this environment.

    Historically this function raised to prevent shipping extra packages into
    service images. The project now prefers a warning so services can start
    even when optional extras are present.
    """

    if os.getenv("HAVEN_SKIP_DEP_ASSERT"):
        return

    for dist_name in distributions:
        try:
            metadata.distribution(dist_name)
        except metadata.PackageNotFoundError:
            continue
        logger.warning(
            "Distribution '%s' is available inside %s. Check pyproject extras and Docker build configuration.",
            dist_name,
            scope,
            extra={"distribution": dist_name, "scope": scope},
        )


__all__ = ["assert_missing_dependencies"]
