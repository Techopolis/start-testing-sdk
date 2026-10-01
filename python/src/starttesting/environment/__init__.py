"""Explicit metadata wins; packaging never grants tester privileges."""

from __future__ import annotations

import json
import os
import platform
import sys
from collections.abc import Mapping
from pathlib import Path

from ..models import BuildInfo, Distribution, Environment

_SIGNALS = {
    Distribution.XCODE: Environment.DEVELOPMENT,
    Distribution.DEBUG: Environment.DEVELOPMENT,
    Distribution.TESTFLIGHT: Environment.BETA,
    Distribution.GITHUB_PRERELEASE: Environment.BETA,
    Distribution.MSIX_FLIGHT: Environment.BETA,
    Distribution.GITHUB_RELEASE: Environment.PRODUCTION,
    Distribution.APP_STORE: Environment.PRODUCTION,
    Distribution.MICROSOFT_STORE: Environment.PRODUCTION,
}


def resolve_build(
    *,
    environment: Environment | str = Environment.AUTO,
    distribution: Distribution | str | None = None,
    metadata_path: Path | None = None,
    environ: Mapping[str, str] | None = None,
) -> BuildInfo:
    env = os.environ if environ is None else environ
    metadata = {}
    if metadata_path is None and Environment(environment) == Environment.AUTO:
        if getattr(sys, "frozen", False):
            bundle_root = Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
            candidate = bundle_root / "starttesting_build.json"
            if candidate.is_file():
                metadata_path = candidate
    if metadata_path is not None:
        with metadata_path.open("rb") as stream:
            raw = stream.read(16_385)
        if len(raw) > 16_384:
            raise ValueError("Build metadata exceeds 16 KiB")
        metadata = json.loads(raw)
        if not isinstance(metadata, dict):
            raise ValueError("Build metadata must be an object")

    def value(key: str, default: str = "unknown") -> str:
        result = env.get("START_TESTING_" + key.upper(), metadata.get(key, default))
        if not isinstance(result, str) or len(result) > 256:
            raise ValueError(f"Invalid build metadata: {key}")
        return result

    dist = Distribution(distribution or value("distribution"))
    if dist == Distribution.UNKNOWN and getattr(sys, "frozen", False):
        dist = Distribution.PYINSTALLER
    selected = Environment(environment)
    if selected == Environment.AUTO:
        selected = Environment(value("environment"))
        if selected in {Environment.UNKNOWN, Environment.AUTO}:
            selected = _SIGNALS.get(dist, Environment.UNKNOWN)
    return BuildInfo(
        selected,
        dist,
        value("version"),
        value("build"),
        value("commit", ""),
        platform.system(),
        platform.release(),
        platform.machine(),
    )
