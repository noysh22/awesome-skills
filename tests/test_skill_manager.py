#!/usr/bin/env python3
"""Unit and integration tests for curated skill selection and extraction."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parent.parent


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config_reader = load_module(
    "test_config_reader", ROOT / "scripts" / "read-skill-config.py"
)
validator = load_module(
    "test_validator", ROOT / "scripts" / "validate-skills.py"
)
manager = load_module(
    "test_manager", ROOT / "scripts" / "skill-manager.py"
)


def run(command: list[str], cwd: Path) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def write_skill(path: Path, name: str, body: str = "") -> None:
    path.mkdir(parents=True, exist_ok=True)
    (path / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: Useful {name} workflow.\n---\n\n{body}\n",
        encoding="utf-8",
    )


class ConfigTests(unittest.TestCase):
    def test_repository_config_is_valid_and_deduplicates_shared_skills(self) -> None:
        config = config_reader.load_config(ROOT / "skills.yaml")
        resolved = config_reader.resolve(config)
        ids = [selection["id"] for selection in resolved["selections"]]
        self.assertEqual(ids.count("frontend-design"), 1)
        self.assertEqual(len(ids), len(set(ids)))
        self.assertIn("pytest", ids)
        self.assertNotIn("api-testing", ids)
        self.assertIn("using-superpowers", ids)

    def test_candidate_resolution_and_unknown_group(self) -> None:
        config = config_reader.load_config(ROOT / "skills.yaml")
        resolved = config_reader.resolve(
            config, ["coding-and-testing"], ["approved", "candidate"]
        )
        ids = [selection["id"] for selection in resolved["selections"]]
        self.assertIn("pytest", ids)
        with self.assertRaises(config_reader.ConfigError):
            config_reader.resolve(config, ["does-not-exist"])

    def test_invalid_path_and_duplicate_output_are_rejected(self) -> None:
        source = {
            "version": 1,
            "defaults": {"groups": ["daily"], "install_status": ["approved"]},
            "sources": {
                "source": {
                    "kind": "git",
                    "repo": "https://github.com/example/skills.git",
                    "ref": "0" * 40,
                    "commit": "0" * 40,
                }
            },
            "groups": {
                "daily": {
                    "enabled_by_default": True,
                    "description": "Daily",
                    "skills": ["one", "two"],
                }
            },
            "skills": {
                "one": {
                    "source": "source",
                    "path": "../escape",
                    "output": "same",
                    "status": "approved",
                    "rationale": "one",
                },
                "two": {
                    "source": "source",
                    "path": "skills/two",
                    "output": "same",
                    "status": "approved",
                    "rationale": "two",
                },
            },
        }
        with tempfile.TemporaryDirectory() as temp:
            config_path = Path(temp) / "skills.yaml"
            config_path.write_text(yaml.safe_dump(source), encoding="utf-8")
            with self.assertRaises(config_reader.ConfigError):
                config_reader.load_config(config_path)


class ValidatorTests(unittest.TestCase):
    def test_clean_skill_passes_without_executing_script(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            skill = root / "clean"
            write_skill(skill, "clean", "See [reference](references/guide.md).")
            (skill / "references").mkdir()
            (skill / "references" / "guide.md").write_text("guide", encoding="utf-8")
            script = skill / "danger.sh"
            script.write_text(
                "#!/usr/bin/env bash\nexit 99\n",
                encoding="utf-8",
            )
            report = validator.audit_root(root)
            self.assertEqual(report["errors"], 0)

    def test_reference_to_installed_sibling_skill_is_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            write_skill(
                root / "one",
                "one",
                "See [two](../two/reference.md).",
            )
            write_skill(root / "two", "two")
            (root / "two" / "reference.md").write_text("two", encoding="utf-8")
            report = validator.audit_root(root)
            self.assertEqual(report["errors"], 0)

    def test_structural_and_syntax_failures_are_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            skill = root / "broken"
            write_skill(
                skill,
                "different-name",
                "See [missing](references/missing.md).",
            )
            (skill / "bad.py").write_text("def broken(:\n", encoding="utf-8")
            os.symlink("/tmp/outside", skill / "outside")
            report = validator.audit_root(root)
            codes = {finding["code"] for finding in report["findings"]}
            self.assertIn("missing-reference", codes)
            self.assertIn("python-syntax", codes)
            self.assertIn("escaping-symlink", codes)
            self.assertGreaterEqual(report["errors"], 3)

    def test_credentials_nested_git_shell_syntax_and_absolute_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            skill = root / "unsafe"
            write_skill(skill, "unsafe", "Read /Users/alice/private/config.yaml.")
            (skill / ".git").mkdir()
            (skill / "bad.sh").write_text(
                "#!/usr/bin/env bash\nif true; then\n",
                encoding="utf-8",
            )
            (skill / "secret.txt").write_text(
                "-----BEGIN PRIVATE KEY-----\n",
                encoding="utf-8",
            )
            report = validator.audit_root(root)
            codes = {finding["code"] for finding in report["findings"]}
            self.assertIn("nested-git", codes)
            self.assertIn("shell-syntax", codes)
            self.assertIn("credential-material", codes)
            self.assertIn("absolute-path", codes)


class ManagerTests(unittest.TestCase):
    def make_source_repo(self, root: Path) -> tuple[Path, str]:
        repo = root / "source"
        repo.mkdir()
        run(["git", "init", "--quiet"], repo)
        run(["git", "config", "user.name", "Test"], repo)
        run(["git", "config", "user.email", "test@example.com"], repo)
        write_skill(repo / "skills" / "one", "one")
        write_skill(repo / "skills" / "two", "two")
        run(["git", "add", "."], repo)
        run(["git", "commit", "--quiet", "-m", "skills"], repo)
        return repo, run(["git", "rev-parse", "HEAD"], repo)

    def test_pinned_fetch_selected_extraction_and_atomic_replace(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repo, commit = self.make_source_repo(root)
            cache = root / "cache"
            source = {
                "kind": "git",
                "repo": str(repo),
                "ref": commit,
                "commit": commit,
            }
            cached = manager._ensure_git_source(cache, "fixture", source)
            self.assertEqual(run(["git", "rev-parse", "HEAD"], cached), commit)

            stage = root / "stage"
            stage.mkdir()
            selection = {
                "id": "one",
                "source": "fixture",
                "source_config": source,
                "path": "skills/one",
                "output": "one",
                "collection": False,
                "groups": ["daily"],
                "status": "approved",
            }
            records = manager._extract_selection(selection, cached, stage)
            self.assertEqual([record["name"] for record in records], ["one"])
            self.assertTrue((stage / "one" / "SKILL.md").is_file())
            self.assertFalse((stage / "two").exists())

            destination = root / "published"
            destination.mkdir()
            (destination / "old").write_text("old", encoding="utf-8")
            manager._atomic_replace(stage, destination)
            self.assertTrue((destination / "one" / "SKILL.md").is_file())
            self.assertFalse((destination / "old").exists())

    def test_collection_expands_all_skill_roots(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repo, commit = self.make_source_repo(root)
            source = {
                "kind": "git",
                "repo": str(repo),
                "ref": commit,
                "commit": commit,
            }
            stage = root / "stage"
            stage.mkdir()
            selection = {
                "id": "collection",
                "source": "fixture",
                "source_config": source,
                "path": "skills",
                "output": "collection",
                "collection": True,
                "groups": ["daily"],
                "status": "candidate",
            }
            records = manager._extract_selection(selection, repo, stage)
            self.assertEqual(
                [record["name"] for record in records],
                ["one", "two"],
            )

    def test_atomic_failure_restores_previous_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stage = root / "stage"
            destination = root / "published"
            stage.mkdir()
            destination.mkdir()
            (stage / "new").write_text("new", encoding="utf-8")
            (destination / "old").write_text("old", encoding="utf-8")
            real_replace = manager.os.replace
            calls = 0

            def fail_publish(source: Path, target: Path) -> None:
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("simulated publish failure")
                real_replace(source, target)

            with mock.patch.object(manager.os, "replace", side_effect=fail_publish):
                with self.assertRaises(OSError):
                    manager._atomic_replace(stage, destination)
            self.assertEqual(
                (destination / "old").read_text(encoding="utf-8"),
                "old",
            )
            self.assertFalse((destination / "new").exists())

    def test_candidate_only_publish_reuses_verified_approved_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            skills = root / "skills"
            write_skill(skills / "approved", "approved")
            manifest = root / "manifest.yaml"
            manifest.write_text(
                yaml.safe_dump(
                    {
                        "version": 1,
                        "skills": [{"name": "approved", "status": "approved"}],
                        "candidates": [],
                    }
                ),
                encoding="utf-8",
            )
            records = manager._existing_approved_records(manifest, skills)
            self.assertEqual([record["name"] for record in records], ["approved"])
            write_skill(skills / "unexpected", "unexpected")
            with self.assertRaises(manager.ManagerError):
                manager._existing_approved_records(manifest, skills)

    def test_dry_run_makes_no_output_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            result = subprocess.run(
                [
                    str(ROOT / "clone-skills.sh"),
                    "--dry-run",
                    "--skills-dir",
                    str(root / "skills"),
                    "--cache-dir",
                    str(root / "cache"),
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("Selections:", result.stdout)
            self.assertEqual(list(root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
