from __future__ import annotations

import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_NAME = "HarnessX"
DEFAULT_REPOSITORY = "n4thyan/HarnessX"
ARTIFACT_NAME = "HarnessXPlugin.lua"
MANIFEST_NAME = "HarnessXPlugin.manifest.json"
CHECKSUMS_NAME = "SHA256SUMS"
SCHEMA_VERSION = 1


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def normalized_timestamp(value: str | None) -> str:
    if value:
        return value

    source_date_epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if source_date_epoch:
        return datetime.fromtimestamp(
            int(source_date_epoch),
            tz=timezone.utc,
        ).isoformat().replace("+00:00", "Z")

    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def build_banner(
    *,
    repository: str,
    version: str,
    commit: str,
    channel: str,
    source_sha256: str,
    built_at: str,
) -> str:
    build_id = f"{version}-{commit[:12]}"

    return "\n".join(
        [
            "--[[",
            "\tHarnessX verifiable build",
            "",
            f"\tRepository: {repository}",
            f"\tVersion: {version}",
            f"\tCommit: {commit}",
            f"\tBuild ID: {build_id}",
            f"\tBuild channel: {channel}",
            f"\tSource SHA-256: {source_sha256}",
            f"\tBuilt at: {built_at}",
            "",
            f"\tArtifact SHA-256: see {MANIFEST_NAME} or {CHECKSUMS_NAME}",
            f"\tVerify provenance: gh attestation verify {ARTIFACT_NAME} -R {repository}",
            "",
            "\tThis banner is metadata, not cryptographic proof.",
            "\tOnly a matching digest plus a valid GitHub attestation from the",
            f"\t{repository} repository identifies an official HarnessX build.",
            "]]",
            "",
        ]
    )


def build_artifact(
    *,
    source_path: Path,
    output_dir: Path,
    repository: str,
    version: str,
    commit: str,
    channel: str,
    built_at: str | None = None,
) -> dict[str, Any]:
    if not source_path.is_file():
        raise FileNotFoundError(f"Plugin source not found: {source_path}")

    source_bytes = source_path.read_bytes()
    source_sha256 = sha256_bytes(source_bytes)
    timestamp = normalized_timestamp(built_at)

    banner = build_banner(
        repository=repository,
        version=version,
        commit=commit,
        channel=channel,
        source_sha256=source_sha256,
        built_at=timestamp,
    )
    artifact_bytes = banner.encode("utf-8") + source_bytes
    artifact_sha256 = sha256_bytes(artifact_bytes)

    output_dir.mkdir(parents=True, exist_ok=True)
    artifact_path = output_dir / ARTIFACT_NAME
    manifest_path = output_dir / MANIFEST_NAME
    checksums_path = output_dir / CHECKSUMS_NAME

    artifact_path.write_bytes(artifact_bytes)

    manifest: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "project": PROJECT_NAME,
        "repository": repository,
        "version": version,
        "commit": commit,
        "buildId": f"{version}-{commit[:12]}",
        "buildChannel": channel,
        "builtAt": timestamp,
        "verification": {
            "attestationCommand": (
                f"gh attestation verify {ARTIFACT_NAME} -R {repository}"
            ),
            "bannerIsProof": False,
        },
        "source": {
            "path": source_path.as_posix(),
            "sha256": source_sha256,
        },
        "artifact": {
            "path": ARTIFACT_NAME,
            "sha256": artifact_sha256,
            "sizeBytes": len(artifact_bytes),
        },
    }

    manifest_bytes = (
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    manifest_path.write_bytes(manifest_bytes)
    manifest_sha256 = sha256_bytes(manifest_bytes)

    checksums_path.write_text(
        "\n".join(
            [
                f"{artifact_sha256}  {ARTIFACT_NAME}",
                f"{manifest_sha256}  {MANIFEST_NAME}",
                "",
            ]
        ),
        encoding="utf-8",
        newline="\n",
    )

    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a verifiable HarnessX plugin artifact."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("roblox/Plugin.lua"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("dist"),
    )
    parser.add_argument("--repository", default=DEFAULT_REPOSITORY)
    parser.add_argument("--version", default="development")
    parser.add_argument("--commit", default="source-tree")
    parser.add_argument("--channel", default="development")
    parser.add_argument("--built-at")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    manifest = build_artifact(
        source_path=args.source,
        output_dir=args.output_dir,
        repository=args.repository,
        version=args.version,
        commit=args.commit,
        channel=args.channel,
        built_at=args.built_at,
    )
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
