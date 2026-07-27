#!/usr/bin/env python3
"""Validate and resolve the curated skill-group configuration."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any

import yaml

ID_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ALLOWED_STATUSES = {"approved", "candidate"}


class ConfigError(ValueError):
    """Raised when skills.yaml is invalid."""


def _require_mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError(f"{label} must be a mapping")
    return value


def _require_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise ConfigError(f"{label} must be a list")
    return value


def _validate_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or not ID_RE.fullmatch(value):
        raise ConfigError(f"{label} must match {ID_RE.pattern}")
    return value


def _validate_relative_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ConfigError(f"{label} must be a non-empty relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise ConfigError(f"{label} must not be absolute or contain '..'")
    return value


def load_config(path: Path) -> dict[str, Any]:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise ConfigError(f"cannot read {path}: {exc}") from exc

    root = _require_mapping(data, "config")
    if root.get("version") != 1:
        raise ConfigError("version must be 1")

    defaults = _require_mapping(root.get("defaults"), "defaults")
    sources = _require_mapping(root.get("sources"), "sources")
    groups = _require_mapping(root.get("groups"), "groups")
    skills = _require_mapping(root.get("skills"), "skills")

    for source_id, raw_source in sources.items():
        _validate_id(source_id, f"source id {source_id!r}")
        source = _require_mapping(raw_source, f"source {source_id}")
        kind = source.get("kind")
        if kind == "git":
            repo = source.get("repo")
            ref = source.get("ref")
            commit = source.get("commit")
            if not isinstance(repo, str) or not repo.startswith("https://github.com/"):
                raise ConfigError(f"source {source_id}.repo must be an HTTPS GitHub URL")
            if not isinstance(ref, str) or not ref:
                raise ConfigError(f"source {source_id}.ref must be non-empty")
            if not isinstance(commit, str) or not COMMIT_RE.fullmatch(commit):
                raise ConfigError(f"source {source_id}.commit must be a 40-character SHA")
        elif kind == "http":
            url = source.get("url")
            checksum = source.get("sha256")
            if not isinstance(url, str) or not url.startswith("https://"):
                raise ConfigError(f"source {source_id}.url must be HTTPS")
            if not isinstance(checksum, str) or not SHA256_RE.fullmatch(checksum):
                raise ConfigError(f"source {source_id}.sha256 must be a SHA-256 digest")
        else:
            raise ConfigError(f"source {source_id}.kind must be git or http")

    output_owners: dict[str, str] = {}
    for skill_id, raw_skill in skills.items():
        _validate_id(skill_id, f"skill id {skill_id!r}")
        skill = _require_mapping(raw_skill, f"skill {skill_id}")
        source_id = skill.get("source")
        if source_id not in sources:
            raise ConfigError(f"skill {skill_id} references unknown source {source_id!r}")
        status = skill.get("status")
        if status not in ALLOWED_STATUSES:
            raise ConfigError(
                f"skill {skill_id}.status must be one of {sorted(ALLOWED_STATUSES)}"
            )
        rationale = skill.get("rationale")
        if not isinstance(rationale, str) or not rationale.strip():
            raise ConfigError(f"skill {skill_id}.rationale must be non-empty")
        collection = skill.get("collection", False)
        if not isinstance(collection, bool):
            raise ConfigError(f"skill {skill_id}.collection must be boolean")

        source_kind = sources[source_id]["kind"]
        if source_kind == "git":
            _validate_relative_path(skill.get("path"), f"skill {skill_id}.path")
        elif "path" in skill:
            raise ConfigError(f"HTTP skill {skill_id} must not define path")

        output = skill.get("output", skill_id)
        _validate_id(output, f"skill {skill_id}.output")
        if not collection:
            previous = output_owners.get(output)
            if previous and previous != skill_id:
                raise ConfigError(
                    f"skills {previous} and {skill_id} share output name {output}"
                )
            output_owners[output] = skill_id

    default_groups = _require_list(defaults.get("groups"), "defaults.groups")
    install_status = _require_list(
        defaults.get("install_status"), "defaults.install_status"
    )
    if not install_status:
        raise ConfigError("defaults.install_status must not be empty")
    for status in install_status:
        if status not in ALLOWED_STATUSES:
            raise ConfigError(f"unknown default install status {status!r}")

    for group_id, raw_group in groups.items():
        _validate_id(group_id, f"group id {group_id!r}")
        group = _require_mapping(raw_group, f"group {group_id}")
        if not isinstance(group.get("enabled_by_default"), bool):
            raise ConfigError(f"group {group_id}.enabled_by_default must be boolean")
        if not isinstance(group.get("description"), str) or not group["description"]:
            raise ConfigError(f"group {group_id}.description must be non-empty")
        members = _require_list(group.get("skills"), f"group {group_id}.skills")
        if not members:
            raise ConfigError(f"group {group_id}.skills must not be empty")
        seen: set[str] = set()
        for skill_id in members:
            if skill_id not in skills:
                raise ConfigError(
                    f"group {group_id} references unknown skill {skill_id!r}"
                )
            if skill_id in seen:
                raise ConfigError(f"group {group_id} repeats skill {skill_id}")
            seen.add(skill_id)

    for group_id in default_groups:
        if group_id not in groups:
            raise ConfigError(f"defaults references unknown group {group_id!r}")
        if not groups[group_id]["enabled_by_default"]:
            raise ConfigError(
                f"default group {group_id} must have enabled_by_default: true"
            )

    enabled = {
        group_id
        for group_id, group in groups.items()
        if group["enabled_by_default"]
    }
    if enabled != set(default_groups):
        missing = sorted(enabled - set(default_groups))
        extra = sorted(set(default_groups) - enabled)
        raise ConfigError(
            f"defaults.groups mismatch enabled flags; missing={missing}, extra={extra}"
        )

    return root


def resolve(
    config: dict[str, Any],
    requested_groups: list[str] | None = None,
    statuses: list[str] | None = None,
) -> dict[str, Any]:
    groups = requested_groups or list(config["defaults"]["groups"])
    selected_statuses = statuses or list(config["defaults"]["install_status"])

    unknown_groups = sorted(set(groups) - set(config["groups"]))
    if unknown_groups:
        raise ConfigError(f"unknown groups: {', '.join(unknown_groups)}")
    unknown_statuses = sorted(set(selected_statuses) - ALLOWED_STATUSES)
    if unknown_statuses:
        raise ConfigError(f"unknown statuses: {', '.join(unknown_statuses)}")

    ordered_groups = list(dict.fromkeys(groups))
    membership: dict[str, list[str]] = {}
    ordered_skills: list[str] = []
    for group_id in ordered_groups:
        for skill_id in config["groups"][group_id]["skills"]:
            membership.setdefault(skill_id, []).append(group_id)
            if skill_id not in ordered_skills:
                ordered_skills.append(skill_id)

    selections: list[dict[str, Any]] = []
    for skill_id in ordered_skills:
        skill = config["skills"][skill_id]
        if skill["status"] not in selected_statuses:
            continue
        selections.append(
            {
                "id": skill_id,
                **skill,
                "output": skill.get("output", skill_id),
                "collection": skill.get("collection", False),
                "groups": membership[skill_id],
                "source_config": config["sources"][skill["source"]],
            }
        )

    return {
        "version": config["version"],
        "groups": ordered_groups,
        "statuses": list(dict.fromkeys(selected_statuses)),
        "selections": selections,
    }


def list_groups(config: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "id": group_id,
            "default": group["enabled_by_default"],
            "description": group["description"],
            "skills": len(group["skills"]),
        }
        for group_id, group in config["groups"].items()
    ]


def _parse_args() -> argparse.Namespace:
    script_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config", type=Path, default=script_root / "skills.yaml"
    )
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--list-groups", action="store_true")
    parser.add_argument("--group", action="append", dest="groups")
    parser.add_argument(
        "--include-status",
        action="append",
        dest="statuses",
        choices=sorted(ALLOWED_STATUSES),
    )
    parser.add_argument("--format", choices=("json", "tsv"), default="json")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        config = load_config(args.config)
        if args.validate and not (args.list_groups or args.groups or args.statuses):
            print(f"OK: {args.config}")
            return 0
        if args.list_groups:
            groups = list_groups(config)
            if args.format == "json":
                print(json.dumps(groups, indent=2))
            else:
                for group in groups:
                    print(
                        f"{group['id']}\t"
                        f"{'default' if group['default'] else 'optional'}\t"
                        f"{group['skills']}\t{group['description']}"
                    )
            return 0

        result = resolve(config, args.groups, args.statuses)
        if args.format == "json":
            print(json.dumps(result, indent=2))
        else:
            for selection in result["selections"]:
                print(
                    "\t".join(
                        [
                            selection["id"],
                            selection["status"],
                            selection["source"],
                            selection.get("path", ""),
                            selection["output"],
                            ",".join(selection["groups"]),
                        ]
                    )
                )
        return 0
    except ConfigError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
