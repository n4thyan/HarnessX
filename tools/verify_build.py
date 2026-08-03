from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any

EXPECTED_PROJECT = "HarnessX"
EXPECTED_REPOSITORY = "n4thyan/HarnessX"
EXPECTED_ARTIFACT = "HarnessXPlugin.lua"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class VerificationError(ValueError):
    """Raised when a HarnessX build artifact fails local verification."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_checksums(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            digest, filename = line.split("  ", 1)
        except ValueError as exc:
            raise VerificationError(f"Invalid checksum line: {line!r}") from exc
        if SHA256_PATTERN.fullmatch(digest) is None:
            raise VerificationError(f"Invalid SHA-256 digest: {digest!r}")
        if filename in values:
            raise VerificationError(f"Duplicate checksum entry: {filename!r}")
        values[filename] = digest
    return values


def require_string(mapping: dict[str, Any], key: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value:
        raise VerificationError(f"Manifest field {key!r} must be a string")
    return value


def require_sha256(mapping: dict[str, Any], key: str) -> str:
    value = require_string(mapping, key)
    if SHA256_PATTERN.fullmatch(value) is None:
        raise VerificationError(f"Manifest field {key!r} is not SHA-256")
    return value


def verify_manifest(
    manifest_path: Path,
    *,
    expected_repository: str = EXPECTED_REPOSITORY,
) -> dict[str, Any]:
    if not manifest_path.is_file():
        raise VerificationError(f"Manifest not found: {manifest_path}")
    if manifest_path.name != "HarnessXPlugin.manifest.json":
        raise VerificationError("Unexpected manifest filename")

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise VerificationError("Manifest is not valid JSON") from exc

    if not isinstance(manifest, dict):
        raise VerificationError("Manifest root must be an object")
    if manifest.get("schemaVersion") != 1:
        raise VerificationError("Unsupported manifest schema")
    if manifest.get("project") != EXPECTED_PROJECT:
        raise VerificationError("Manifest does not describe HarnessX")
    if manifest.get("repository") != expected_repository:
        raise VerificationError("Manifest repository does not match the expected origin")

    verification = manifest.get("verification")
    artifact = manifest.get("artifact")
    source = manifest.get("source")
    if not isinstance(verification, dict):
        raise VerificationError("Manifest verification section is required")
    if verification.get("bannerIsProof") is not False:
        raise VerificationError("Manifest must not claim that its banner is proof")
    if not isinstance(artifact, dict) or not isinstance(source, dict):
        raise VerificationError("Manifest source and artifact sections are required")

    artifact_name = require_string(artifact, "path")
    if artifact_name != EXPECTED_ARTIFACT:
        raise VerificationError("Unexpected artifact filename")

    artifact_digest = require_sha256(artifact, "sha256")
    source_digest = require_sha256(source, "sha256")
    version = require_string(manifest, "version")
    commit = require_string(manifest, "commit")

    artifact_path = manifest_path.parent / artifact_name
    if not artifact_path.is_file():
        raise VerificationError(f"Artifact not found: {artifact_path}")

    expected_size = artifact.get("sizeBytes")
    if not isinstance(expected_size, int) or expected_size < 1:
        raise VerificationError("Manifest artifact size is invalid")
    if artifact_path.stat().st_size != expected_size:
        raise VerificationError("Artifact size does not match the manifest")

    actual_artifact_digest = sha256_file(artifact_path)
    if actual_artifact_digest != artifact_digest:
        raise VerificationError(
            "Artifact SHA-256 does not match the manifest; the build was modified"
        )

    artifact_text = artifact_path.read_text(encoding="utf-8")
    required_banner_values = (
        f"Repository: {expected_repository}",
        f"Version: {version}",
        f"Commit: {commit}",
        f"Source SHA-256: {source_digest}",
        "Artifact SHA-256: see HarnessXPlugin.manifest.json or SHA256SUMS",
        "This banner is metadata, not cryptographic proof.",
    )
    for expected in required_banner_values:
        if expected not in artifact_text:
            raise VerificationError(f"Artifact banner is missing {expected!r}")

    checksums_path = manifest_path.parent / "SHA256SUMS"
    if not checksums_path.is_file():
        raise VerificationError("SHA256SUMS is required")

    checksums = parse_checksums(checksums_path)
    manifest_digest = sha256_file(manifest_path)
    if checksums.get(artifact_name) != artifact_digest:
        raise VerificationError("SHA256SUMS does not match the artifact")
    if checksums.get(manifest_path.name) != manifest_digest:
        raise VerificationError("SHA256SUMS does not match the manifest")
    if set(checksums) != {artifact_name, manifest_path.name}:
        raise VerificationError("SHA256SUMS contains unexpected entries")

    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify HarnessX artifact checksums and banner metadata. "
            "Use gh attestation verify separately for origin verification."
        )
    )
    parser.add_argument("manifest", type=Path)
    parser.add_argument(
        "--expect-repository",
        default=EXPECTED_REPOSITORY,
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    manifest = verify_manifest(
        args.manifest,
        expected_repository=args.expect_repository,
    )
    print(
        "Verified local HarnessX checksums: "
        f"{manifest['buildId']} ({manifest['artifact']['sha256']})"
    )
    print(
        "Origin is not proven by local checksums alone. Run: "
        f"{manifest['verification']['attestationCommand']}"
    )


if __name__ == "__main__":
    main()
