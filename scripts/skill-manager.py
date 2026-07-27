#!/usr/bin/env python3
"""Download pinned skill groups, audit them, and publish atomically."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path
from typing import Any

import yaml

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent


def _load_local_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config_reader = _load_local_module(
    "awesome_skills_config_reader", SCRIPT_DIR / "read-skill-config.py"
)
validator = _load_local_module(
    "awesome_skills_validator", SCRIPT_DIR / "validate-skills.py"
)

SKIP_COPY_NAMES = {
    ".git",
    ".DS_Store",
    "__pycache__",
    "node_modules",
    ".next",
    "target",
    "dist",
    "build",
    "vendor",
}


class ManagerError(RuntimeError):
    """Raised when a build cannot be completed safely."""


def _run(
    command: list[str],
    *,
    cwd: Path | None = None,
    capture: bool = False,
) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        text=True,
        capture_output=capture,
    )
    if result.returncode:
        detail = result.stderr.strip() if capture else ""
        raise ManagerError(f"command failed ({result.returncode}): {' '.join(command)} {detail}")
    return result.stdout.strip() if capture else ""


def _git_cache_path(cache_dir: Path, source_id: str) -> Path:
    candidate = cache_dir / source_id
    if candidate.parent != cache_dir:
        raise ManagerError(f"unsafe cache path for source {source_id}")
    return candidate


def _ensure_git_source(
    cache_dir: Path, source_id: str, source: dict[str, Any]
) -> Path:
    repo_dir = _git_cache_path(cache_dir, source_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    if repo_dir.exists():
        if not (repo_dir / ".git").is_dir():
            raise ManagerError(f"cache path is not a Git repository: {repo_dir}")
        remote = _run(
            ["git", "remote", "get-url", "origin"], cwd=repo_dir, capture=True
        )
        if remote != source["repo"]:
            raise ManagerError(
                f"cache remote mismatch for {source_id}: {remote!r} != {source['repo']!r}"
            )
        dirty = _run(["git", "status", "--porcelain"], cwd=repo_dir, capture=True)
        if dirty:
            raise ManagerError(f"cache repository is dirty: {repo_dir}")
    else:
        repo_dir.mkdir()
        _run(["git", "init", "--quiet"], cwd=repo_dir)
        _run(["git", "remote", "add", "origin", source["repo"]], cwd=repo_dir)

    _run(
        ["git", "fetch", "--quiet", "--depth", "1", "origin", source["ref"]],
        cwd=repo_dir,
    )
    _run(
        ["git", "checkout", "--quiet", "--detach", "--force", source["commit"]],
        cwd=repo_dir,
    )
    actual = _run(["git", "rev-parse", "HEAD"], cwd=repo_dir, capture=True)
    if actual != source["commit"]:
        raise ManagerError(
            f"pin verification failed for {source_id}: {actual} != {source['commit']}"
        )
    return repo_dir


def _download_http_source(
    temp_root: Path, source_id: str, source: dict[str, Any]
) -> Path:
    source_dir = temp_root / source_id
    source_dir.mkdir(parents=True)
    try:
        with urllib.request.urlopen(source["url"], timeout=30) as response:
            content = response.read()
    except OSError as exc:
        raise ManagerError(f"failed to download {source['url']}: {exc}") from exc
    digest = hashlib.sha256(content).hexdigest()
    if digest != source["sha256"]:
        raise ManagerError(
            f"checksum mismatch for {source_id}: {digest} != {source['sha256']}"
        )
    (source_dir / "SKILL.md").write_bytes(content)
    return source_dir


def _ignore_copy(_: str, names: list[str]) -> set[str]:
    return {name for name in names if name in SKIP_COPY_NAMES}


def _copy_skill(source_dir: Path, destination: Path) -> None:
    if destination.exists() or destination.is_symlink():
        raise ManagerError(f"duplicate output name: {destination.name}")
    shutil.copytree(
        source_dir,
        destination,
        symlinks=True,
        ignore=_ignore_copy,
    )


def _skill_roots(base_dir: Path) -> list[Path]:
    roots: list[Path] = []
    for skill_md in base_dir.rglob("SKILL.md"):
        if any(part in SKIP_COPY_NAMES for part in skill_md.relative_to(base_dir).parts):
            continue
        roots.append(skill_md.parent)
    return sorted(set(roots), key=lambda item: item.as_posix())


def _resolve_git_selection(repo_dir: Path, selection: dict[str, Any]) -> Path:
    requested = repo_dir / selection["path"]
    root = repo_dir.resolve()
    resolved = requested.resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ManagerError(
            f"configured path escapes source {selection['id']}: {selection['path']}"
        ) from exc
    if not resolved.is_dir():
        raise ManagerError(
            f"configured path is missing for {selection['id']}: {selection['path']}"
        )
    return resolved


def _extract_selection(
    selection: dict[str, Any],
    source_root: Path,
    destination_root: Path,
) -> list[dict[str, Any]]:
    if selection["source_config"]["kind"] == "http":
        roots = [source_root]
    else:
        configured_root = _resolve_git_selection(source_root, selection)
        if selection["collection"]:
            roots = _skill_roots(configured_root)
            if not roots:
                raise ManagerError(f"collection contains no skills: {selection['id']}")
        else:
            roots = [configured_root]

    records: list[dict[str, Any]] = []
    for skill_root in roots:
        if not (skill_root / "SKILL.md").is_file():
            raise ManagerError(f"SKILL.md missing for {selection['id']}: {skill_root}")
        output = skill_root.name if selection["collection"] else selection["output"]
        if not config_reader.ID_RE.fullmatch(output):
            raise ManagerError(
                f"discovered output name is invalid for {selection['id']}: {output}"
            )
        _copy_skill(skill_root, destination_root / output)
        records.append(
            {
                "name": output,
                "selection": selection["id"],
                "source": selection["source"],
                "pin": selection["source_config"].get(
                    "commit", selection["source_config"].get("sha256")
                ),
                "path": (
                    selection.get("path", "")
                    if not selection["collection"]
                    else str(skill_root.relative_to(source_root.resolve()))
                ),
                "groups": selection["groups"],
                "status": selection["status"],
            }
        )
    return records


def _atomic_replace(staged: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    backup = destination.parent / f".{destination.name}.backup"
    if backup.exists() or backup.is_symlink():
        if backup.is_dir() and not backup.is_symlink():
            shutil.rmtree(backup)
        else:
            backup.unlink()
    if destination.exists() or destination.is_symlink():
        os.replace(destination, backup)
    try:
        os.replace(staged, destination)
    except BaseException:
        if backup.exists() or backup.is_symlink():
            os.replace(backup, destination)
        raise
    if backup.exists() or backup.is_symlink():
        if backup.is_dir() and not backup.is_symlink():
            shutil.rmtree(backup)
        else:
            backup.unlink()


def _atomic_yaml(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        yaml.safe_dump(data, handle, sort_keys=False, allow_unicode=True)
        temp_path = Path(handle.name)
    os.replace(temp_path, path)


def _atomic_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        handle.write(content)
        temp_path = Path(handle.name)
    os.replace(temp_path, path)


def _config_digest(config_path: Path) -> str:
    return hashlib.sha256(config_path.read_bytes()).hexdigest()


def _write_lock(path: Path, config: dict[str, Any], digest: str) -> None:
    sources: dict[str, Any] = {}
    for source_id, source in config["sources"].items():
        if source["kind"] == "git":
            sources[source_id] = {
                "kind": "git",
                "repo": source["repo"],
                "requested_ref": source["ref"],
                "resolved_commit": source["commit"],
            }
        else:
            sources[source_id] = {
                "kind": "http",
                "url": source["url"],
                "sha256": source["sha256"],
            }
    _atomic_yaml(
        path,
        {
            "version": 1,
            "config_sha256": digest,
            "sources": sources,
        },
    )


def _existing_approved_records(
    manifest_path: Path,
    skills_dir: Path,
) -> list[dict[str, Any]]:
    if not manifest_path.is_file() or not skills_dir.is_dir():
        raise ManagerError(
            "candidate-only audit requires an existing approved build and manifest"
        )
    try:
        manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise ManagerError(f"cannot read existing manifest: {exc}") from exc
    records = manifest.get("skills") if isinstance(manifest, dict) else None
    if not isinstance(records, list) or not records:
        raise ManagerError("existing manifest contains no approved skills")
    names = sorted(
        record.get("name")
        for record in records
        if isinstance(record, dict) and isinstance(record.get("name"), str)
    )
    directories = sorted(
        child.name
        for child in skills_dir.iterdir()
        if child.is_dir() and not child.name.startswith(".")
    )
    if names != directories:
        raise ManagerError(
            "existing approved output does not match its manifest; run a full build"
        )
    return sorted(records, key=lambda item: item["name"])


def _prune_cache(cache_dir: Path, selected_source_ids: set[str]) -> None:
    if not cache_dir.is_dir():
        return
    for child in cache_dir.iterdir():
        if child.name.startswith(".") or child.name in selected_source_ids:
            continue
        if child.parent != cache_dir:
            raise ManagerError(f"refusing unsafe cache prune target: {child}")
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def _dry_run(result: dict[str, Any]) -> None:
    print("Groups:", ", ".join(result["groups"]))
    print("Statuses:", ", ".join(result["statuses"]))
    print(f"Selections: {len(result['selections'])}")
    for selection in result["selections"]:
        source = selection["source_config"]
        pin = source.get("commit", source.get("sha256"))
        kind = "collection" if selection["collection"] else "skill"
        print(
            f"- {selection['id']} [{selection['status']}] {kind} "
            f"{selection['source']}@{pin} {selection.get('path', '')} "
            f"-> {selection['output']}"
        )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT_DIR / "skills.yaml")
    parser.add_argument("--group", action="append", dest="groups")
    parser.add_argument("--list-groups", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--write-lock-only", action="store_true")
    parser.add_argument("--audit-candidates", action="store_true")
    parser.add_argument("--prune-cache", action="store_true")
    parser.add_argument("--cache-dir", type=Path, default=ROOT_DIR / ".skills-cache")
    parser.add_argument("--skills-dir", type=Path, default=ROOT_DIR / "skills")
    parser.add_argument(
        "--candidates-dir", type=Path, default=ROOT_DIR / ".skills-candidates"
    )
    parser.add_argument(
        "--manifest", type=Path, default=ROOT_DIR / "skills.manifest.yaml"
    )
    parser.add_argument("--lock", type=Path, default=ROOT_DIR / "skills.lock.yaml")
    parser.add_argument(
        "--audit-report", type=Path, default=ROOT_DIR / "skill-audit.md"
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        config = config_reader.load_config(args.config)
        if args.list_groups:
            for group in config_reader.list_groups(config):
                mode = "default" if group["default"] else "optional"
                print(
                    f"{group['id']}\t{mode}\t{group['skills']}\t"
                    f"{group['description']}"
                )
            return 0
        if args.write_lock_only:
            digest = _config_digest(args.config)
            _write_lock(args.lock, config, digest)
            print(f"Wrote lock file: {args.lock}")
            return 0

        statuses = ["approved", "candidate"] if args.audit_candidates else None
        result = config_reader.resolve(config, args.groups, statuses)
        if args.dry_run:
            _dry_run(result)
            return 0
        if not result["selections"]:
            raise ManagerError(
                "selection is empty; use --audit-candidates for candidate-only groups"
            )

        args.cache_dir = args.cache_dir.resolve()
        args.skills_dir = args.skills_dir.resolve()
        args.candidates_dir = args.candidates_dir.resolve()
        staging_parent = args.skills_dir.parent
        staging_parent.mkdir(parents=True, exist_ok=True)
        approved_stage = Path(
            tempfile.mkdtemp(prefix=".skills-staging.", dir=staging_parent)
        )
        candidate_stage = Path(
            tempfile.mkdtemp(prefix=".candidate-staging.", dir=staging_parent)
        )
        http_temp = Path(tempfile.mkdtemp(prefix=".http-sources."))

        records: list[dict[str, Any]] = []
        source_roots: dict[str, Path] = {}
        try:
            for selection in result["selections"]:
                source_id = selection["source"]
                if source_id not in source_roots:
                    source = selection["source_config"]
                    print(f"FETCH: {source_id}")
                    if source["kind"] == "git":
                        source_roots[source_id] = _ensure_git_source(
                            args.cache_dir, source_id, source
                        )
                    else:
                        source_roots[source_id] = _download_http_source(
                            http_temp, source_id, source
                        )
                destination = (
                    approved_stage
                    if selection["status"] == "approved"
                    else candidate_stage
                )
                extracted = _extract_selection(
                    selection, source_roots[source_id], destination
                )
                records.extend(extracted)
                for record in extracted:
                    print(
                        f"EXTRACT: {record['name']} "
                        f"[{record['status']}] from {record['source']}"
                    )

            has_approved_selection = any(
                selection["status"] == "approved"
                for selection in result["selections"]
            )
            approved_audit_root = (
                approved_stage if has_approved_selection else args.skills_dir
            )
            approved_report = validator.audit_root(approved_audit_root)
            candidate_report = validator.audit_root(candidate_stage)
            audit_text = validator.render_report(
                [
                    ("Approved skills", approved_report),
                    ("Candidate quarantine", candidate_report),
                ]
            )
            # Failed builds still need a durable report explaining why nothing
            # was published.
            _atomic_text(args.audit_report, audit_text)
            if approved_report["errors"]:
                raise ManagerError(
                    f"approved validation failed with {approved_report['errors']} errors"
                )

            if has_approved_selection:
                approved_records = sorted(
                    (record for record in records if record["status"] == "approved"),
                    key=lambda item: item["name"],
                )
            else:
                approved_records = _existing_approved_records(
                    args.manifest, args.skills_dir
                )
            candidate_records = sorted(
                (record for record in records if record["status"] == "candidate"),
                key=lambda item: item["name"],
            )
            digest = _config_digest(args.config)
            if has_approved_selection:
                _atomic_replace(approved_stage, args.skills_dir)
            _atomic_replace(candidate_stage, args.candidates_dir)
            _atomic_yaml(
                args.manifest,
                {
                    "version": 1,
                    "config_sha256": digest,
                    "skills_root": str(args.skills_dir),
                    "skills": approved_records,
                    "candidates": candidate_records,
                },
            )
            _write_lock(args.lock, config, digest)
            if args.prune_cache:
                _prune_cache(args.cache_dir, set(source_roots))

            print(f"Installed approved skills: {len(approved_records)}")
            print(f"Quarantined candidates: {len(candidate_records)}")
            print(f"Approved warnings: {approved_report['warnings']}")
            print(f"Candidate errors: {candidate_report['errors']}")
            print(f"Candidate warnings: {candidate_report['warnings']}")
            return 0
        finally:
            shutil.rmtree(http_temp, ignore_errors=True)
            if approved_stage.exists():
                shutil.rmtree(approved_stage, ignore_errors=True)
            if candidate_stage.exists():
                shutil.rmtree(candidate_stage, ignore_errors=True)
    except (config_reader.ConfigError, ManagerError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
