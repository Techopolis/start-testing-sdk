"""Build each artifact on its target OS. Build metadata is embedded, never fetched at startup."""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--environment", choices=["beta", "production"], required=True)
    parser.add_argument("--version", default="0.1.0a1")
    parser.add_argument("--commit", default="unknown")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    staging = root / "build" / ("sample-" + args.environment)
    staging.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / "samples" / "python-wx" / "demo.py", staging / "demo.py")
    metadata = staging / "starttesting_build.json"
    metadata.write_text(
        json.dumps(
            {
                "environment": args.environment,
                "distribution": "github_prerelease"
                if args.environment == "beta"
                else "github_release",
                "version": args.version,
                "commit": args.commit,
            }
        )
    )
    name = "starttesting-sample-" + args.environment
    subprocess.run(
        [
            sys.executable,
            "-m",
            "PyInstaller",
            "--noconfirm",
            "--clean",
            "--onedir",
            "--name",
            name,
            "--distpath",
            str(root / "dist"),
            "--workpath",
            str(staging / "work"),
            "--specpath",
            str(staging),
            "--add-data",
            str(metadata) + ":.",
            "--collect-submodules",
            "starttesting",
            "--hidden-import",
            "wx",
            str(staging / "demo.py"),
        ],
        check=True,
    )
    executable = root / "dist" / name / (name + (".exe" if sys.platform == "win32" else ""))
    output = subprocess.check_output([str(executable), "--check-build"], text=True)
    loaded = json.loads(output)
    if loaded["environment"] != args.environment:
        raise RuntimeError("Packaged environment did not match requested build")
    print("Verified packaged metadata:", output.strip())


if __name__ == "__main__":
    main()
