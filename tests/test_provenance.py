from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.build_plugin import ARTIFACT_NAME, MANIFEST_NAME, build_artifact
from tools.verify_build import VerificationError, verify_manifest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "roblox" / "Plugin.lua"


class ProvenanceBuildTests(unittest.TestCase):
    def build(self, output: Path) -> Path:
        build_artifact(
            source_path=SOURCE,
            output_dir=output,
            repository="n4thyan/HarnessX",
            version="test-v1",
            commit="0123456789abcdef0123456789abcdef01234567",
            channel="ci",
            built_at="2026-08-03T17:00:00Z",
        )
        return output / MANIFEST_NAME

    def test_build_is_reproducible_for_identical_inputs(self) -> None:
        with (
            tempfile.TemporaryDirectory() as first_temp,
            tempfile.TemporaryDirectory() as second_temp,
        ):
            first = Path(first_temp)
            second = Path(second_temp)
            first_manifest = self.build(first)
            second_manifest = self.build(second)

            self.assertEqual(
                (first / ARTIFACT_NAME).read_bytes(),
                (second / ARTIFACT_NAME).read_bytes(),
            )
            self.assertEqual(first_manifest.read_bytes(), second_manifest.read_bytes())
            self.assertEqual(
                (first / "SHA256SUMS").read_bytes(),
                (second / "SHA256SUMS").read_bytes(),
            )

    def test_generated_build_verifies(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest_path = self.build(Path(temporary))
            manifest = verify_manifest(manifest_path)
            self.assertEqual(manifest["project"], "HarnessX")
            self.assertFalse(manifest["verification"]["bannerIsProof"])

    def test_modified_artifact_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            manifest_path = self.build(output)
            artifact_path = output / ARTIFACT_NAME
            artifact_path.write_text(
                artifact_path.read_text(encoding="utf-8") + "\n-- modified\n",
                encoding="utf-8",
                newline="\n",
            )

            with self.assertRaises(VerificationError):
                verify_manifest(manifest_path)

    def test_missing_checksum_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            manifest_path = self.build(output)
            (output / "SHA256SUMS").unlink()

            with self.assertRaises(VerificationError):
                verify_manifest(manifest_path)

    def test_banner_breakout_metadata_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                build_artifact(
                    source_path=SOURCE,
                    output_dir=Path(temporary),
                    repository="n4thyan/HarnessX",
                    version="v1]]\nprint('forged')",
                    commit="0123456789abcdef0123456789abcdef01234567",
                    channel="ci",
                    built_at="2026-08-03T17:00:00Z",
                )


if __name__ == "__main__":
    unittest.main()
