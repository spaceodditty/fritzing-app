#!/usr/bin/env python3
"""Package pinned vendor-provided Fritzing bin bundles for a release."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Library:
    name: str
    url: str
    revision: str
    license_file: str
    expected_bins: tuple[tuple[str, str], ...]


LIBRARIES = (
    Library(
        name="adafruit",
        url="https://github.com/adafruit/Fritzing-Library.git",
        revision="7d905c3e982de3712c3033da4596cc71ea32de1c",
        license_file="LICENSE",
        expected_bins=(
            ("AdaFruit.fzbz", "df14e14554f2931ea32ebbfc8d66be8d5648967c19bd11f9c7c28c8886c356f3"),
            ("AdaGators.fzbz", "488479e21ddfb62b517599892dd2d194d39990b7d1252325540bbe619cc125c0"),
            ("Adafruit Arduino.fzbz", "d7c1b70d2157f5350eae4a8ce28100848315cbf81288188bf7d7229a16f3b734"),
            ("Adafruit Batteries.fzbz", "ade88c634ab3e677b9f5122dbc76482a8567e140a99617dc411cc36926a2b857"),
            ("Adafruit Feather.fzbz", "c4eae38d7762745ff79f0156f7ece2f3e1c0f41423a5c31f0444f94ac8067b4d"),
            ("Adafruit LED Backpacks.fzbz", "bb567dd034b1276b0cf59cd84ce6b084362284d47456cc6ed92186d9fda2c235"),
            ("Adafruit Raspberry Pi.fzbz", "f0b4e99389c91b06e4278c17b9899c44f7109df332a6143f0e2537c3eb8e3579"),
            ("CircuitPlayground.fzbz", "8e49088d731846a7468a14e85b96b3f718e0efd6e15a7f847a0bb13fdf95e75f"),
        ),
    ),
    Library(
        name="sparkfun",
        url="https://github.com/sparkfun/Fritzing_Parts.git",
        revision="71b17bbea66f92123f0a39dcf6f8c9ae566e31d1",
        license_file="License.md",
        expected_bins=(("SparkFun Plus.fzbz", "4d62a23fcd04e61b78be7d51538a700924e0cec051a07ce357bcf9e2aef3cfb1"),),
    ),
)


def run(*args: str, cwd: Path | None = None) -> str:
    result = subprocess.run(
        args,
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_library(library: Library, output: Path, workdir: Path) -> None:
    checkout = workdir / library.name
    checkout.mkdir()
    run("git", "init", "--quiet", cwd=checkout)
    run("git", "remote", "add", "origin", library.url, cwd=checkout)
    run("git", "sparse-checkout", "init", "--no-cone", cwd=checkout)
    run(
        "git",
        "sparse-checkout",
        "set",
        "--no-cone",
        "/*.fzbz",
        "/README.md",
        f"/{library.license_file}",
        cwd=checkout,
    )
    run(
        "git",
        "-c",
        "protocol.version=2",
        "fetch",
        "--quiet",
        "--depth=1",
        "--filter=blob:none",
        "origin",
        library.revision,
        cwd=checkout,
    )
    run("git", "checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=checkout)

    actual_revision = run("git", "rev-parse", "HEAD", cwd=checkout)
    if actual_revision != library.revision:
        raise RuntimeError(
            f"{library.name}: expected {library.revision}, got {actual_revision}"
        )

    actual_bins = tuple(sorted(path.name for path in checkout.glob("*.fzbz")))
    expected_bins = tuple(sorted(filename for filename, _ in library.expected_bins))
    if actual_bins != expected_bins:
        raise RuntimeError(
            f"{library.name}: expected bins {expected_bins}, got {actual_bins}"
        )

    destination = output / library.name
    destination.mkdir()
    for filename, expected_hash in library.expected_bins:
        actual_hash = sha256(checkout / filename)
        if actual_hash != expected_hash:
            raise RuntimeError(
                f"{library.name}/{filename}: expected SHA-256 {expected_hash}, "
                f"got {actual_hash}"
            )
        shutil.copy2(checkout / filename, destination / filename)
    for filename in ("README.md", library.license_file):
        shutil.copy2(checkout / filename, destination / filename)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fetch pinned third-party Fritzing bins into a release folder."
    )
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        raise SystemExit(f"refusing to overwrite non-empty directory: {output}")
    output.mkdir(parents=True, exist_ok=True)

    repository_root = Path(__file__).resolve().parents[1]
    shutil.copy2(repository_root / "THIRD_PARTY_PARTS.md", output / "README.md")

    with tempfile.TemporaryDirectory(prefix="fritzing-vendor-parts-") as temporary:
        workdir = Path(temporary)
        for library in LIBRARIES:
            fetch_library(library, output, workdir)

    packaged_bins = len(list(output.glob("*/*.fzbz")))
    print(f"Packaged {packaged_bins} third-party Fritzing bins in {output}")


if __name__ == "__main__":
    main()
