#!/usr/bin/env python3
"""Statically audit extracted skills without executing third-party code."""

from __future__ import annotations

import argparse
import ast
import re
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.parse import unquote

import yaml

FRONTMATTER_RE = re.compile(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)", re.DOTALL)
MARKDOWN_LINK_RE = re.compile(r"\]\(([^)]+)\)")
ABSOLUTE_PATH_RE = re.compile(r"(?<![\w:])/(?:Users|home|opt|var|tmp)/[^\s)`]+")
SECRET_PATTERNS = {
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    "OpenAI key": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
}
SKIP_LINK_PREFIXES = (
    "http:",
    "https:",
    "mailto:",
    "data:",
    "#",
    "/",
)
SKIP_DIRS = {".git", "node_modules", ".next", "target", "dist", "build", "vendor"}


def _finding(
    skill: str,
    severity: str,
    code: str,
    message: str,
    path: Path | None = None,
) -> dict[str, str]:
    finding = {
        "skill": skill,
        "severity": severity,
        "code": code,
        "message": message,
    }
    if path is not None:
        finding["path"] = str(path)
    return finding


def _frontmatter(skill_dir: Path, findings: list[dict[str, str]]) -> dict[str, Any]:
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        findings.append(
            _finding(
                skill_dir.name,
                "error",
                "missing-skill-md",
                "SKILL.md is missing",
                skill_md,
            )
        )
        return {}

    try:
        text = skill_md.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        findings.append(
            _finding(
                skill_dir.name,
                "error",
                "unreadable-skill-md",
                f"cannot read SKILL.md: {exc}",
                skill_md,
            )
        )
        return {}

    match = FRONTMATTER_RE.match(text)
    if not match:
        findings.append(
            _finding(
                skill_dir.name,
                "error",
                "invalid-frontmatter",
                "SKILL.md must start with YAML frontmatter",
                skill_md,
            )
        )
        return {}

    try:
        metadata = yaml.safe_load(match.group(1))
    except yaml.YAMLError as exc:
        findings.append(
            _finding(
                skill_dir.name,
                "error",
                "invalid-frontmatter",
                f"frontmatter is not valid YAML: {exc}",
                skill_md,
            )
        )
        return {}

    if not isinstance(metadata, dict):
        findings.append(
            _finding(
                skill_dir.name,
                "error",
                "invalid-frontmatter",
                "frontmatter must be a mapping",
                skill_md,
            )
        )
        return {}

    description = metadata.get("description")
    if not isinstance(description, str) or not description.strip():
        findings.append(
            _finding(
                skill_dir.name,
                "error",
                "missing-description",
                "frontmatter description must be non-empty",
                skill_md,
            )
        )

    declared_name = metadata.get("name")
    if declared_name and declared_name != skill_dir.name:
        findings.append(
            _finding(
                skill_dir.name,
                "warning",
                "name-mismatch",
                f"frontmatter name {declared_name!r} differs from output directory",
                skill_md,
            )
        )

    line_count = len(text.splitlines())
    if line_count > 500:
        findings.append(
            _finding(
                skill_dir.name,
                "warning",
                "oversized-skill",
                f"SKILL.md has {line_count} lines; review context cost",
                skill_md,
            )
        )

    for match_path in ABSOLUTE_PATH_RE.finditer(text):
        findings.append(
            _finding(
                skill_dir.name,
                "warning",
                "absolute-path",
                f"contains local absolute path {match_path.group(0)!r}",
                skill_md,
            )
        )
    return metadata


def _audit_links(
    skill_dir: Path,
    install_root: Path,
    findings: list[dict[str, str]],
) -> None:
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        return
    try:
        text = skill_md.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return

    root = install_root.resolve()
    for raw_target in MARKDOWN_LINK_RE.findall(text):
        target = raw_target.strip().strip("<>")
        if not target or target.startswith(SKIP_LINK_PREFIXES):
            continue
        if any(marker in target for marker in ("{", "}", "$(", "${")):
            continue
        target = target.split(maxsplit=1)[0]
        target = unquote(target.split("#", 1)[0].split("?", 1)[0])
        if not target:
            continue
        candidate = (skill_dir / target).resolve(strict=False)
        try:
            candidate.relative_to(root)
        except ValueError:
            findings.append(
                _finding(
                    skill_dir.name,
                    "error",
                    "escaping-reference",
                    f"relative reference escapes the installed root: {raw_target}",
                    skill_md,
                )
            )
            continue
        if not candidate.exists():
            findings.append(
                _finding(
                    skill_dir.name,
                    "error",
                    "missing-reference",
                    f"referenced path does not exist: {raw_target}",
                    skill_md,
                )
            )


def _audit_tree(skill_dir: Path, findings: list[dict[str, str]]) -> None:
    root = skill_dir.resolve()
    for entry in skill_dir.rglob("*"):
        relative_parts = entry.relative_to(skill_dir).parts
        if any(part in SKIP_DIRS for part in relative_parts):
            if ".git" in relative_parts:
                findings.append(
                    _finding(
                        skill_dir.name,
                        "error",
                        "nested-git",
                        "installed output contains nested .git metadata",
                        entry,
                    )
                )
            continue
        if entry.is_symlink():
            resolved = entry.resolve(strict=False)
            try:
                resolved.relative_to(root)
            except ValueError:
                findings.append(
                    _finding(
                        skill_dir.name,
                        "error",
                        "escaping-symlink",
                        f"symlink escapes the installed skill: {entry.readlink()}",
                        entry,
                    )
                )
            if not entry.exists():
                findings.append(
                    _finding(
                        skill_dir.name,
                        "error",
                        "broken-symlink",
                        "installed output contains a broken symlink",
                        entry,
                    )
                )


def _audit_files(skill_dir: Path, findings: list[dict[str, str]]) -> None:
    for file_path in skill_dir.rglob("*"):
        if not file_path.is_file() or file_path.is_symlink():
            continue
        if any(part in SKIP_DIRS for part in file_path.relative_to(skill_dir).parts):
            continue
        try:
            content = file_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue

        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(content):
                findings.append(
                    _finding(
                        skill_dir.name,
                        "error",
                        "credential-material",
                        f"contains material matching {label}",
                        file_path,
                    )
                )

        if file_path.suffix == ".py":
            try:
                ast.parse(content, filename=str(file_path))
            except SyntaxError as exc:
                findings.append(
                    _finding(
                        skill_dir.name,
                        "error",
                        "python-syntax",
                        f"Python syntax error at line {exc.lineno}: {exc.msg}",
                        file_path,
                    )
                )
        elif file_path.suffix == ".sh":
            result = subprocess.run(
                ["bash", "-n", str(file_path)],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode:
                message = result.stderr.strip().splitlines()[-1]
                findings.append(
                    _finding(
                        skill_dir.name,
                        "error",
                        "shell-syntax",
                        message,
                        file_path,
                    )
                )


def audit_root(root: Path) -> dict[str, Any]:
    findings: list[dict[str, str]] = []
    if not root.is_dir():
        return {
            "root": str(root),
            "skills": 0,
            "errors": 1,
            "warnings": 0,
            "findings": [
                _finding(
                    root.name,
                    "error",
                    "missing-root",
                    "audit root does not exist",
                    root,
                )
            ],
        }

    skill_dirs = sorted(
        (
            child
            for child in root.iterdir()
            if child.is_dir() and not child.name.startswith(".")
        ),
        key=lambda item: item.name,
    )
    seen_names: set[str] = set()
    for skill_dir in skill_dirs:
        if skill_dir.name in seen_names:
            findings.append(
                _finding(
                    skill_dir.name,
                    "error",
                    "duplicate-name",
                    "duplicate top-level skill output name",
                    skill_dir,
                )
            )
            continue
        seen_names.add(skill_dir.name)
        _frontmatter(skill_dir, findings)
        _audit_links(skill_dir, root, findings)
        _audit_tree(skill_dir, findings)
        _audit_files(skill_dir, findings)

    errors = sum(item["severity"] == "error" for item in findings)
    warnings = sum(item["severity"] == "warning" for item in findings)
    return {
        "root": str(root),
        "skills": len(skill_dirs),
        "errors": errors,
        "warnings": warnings,
        "findings": findings,
    }


def render_report(reports: list[tuple[str, dict[str, Any]]]) -> str:
    lines = ["# Skill Audit", ""]
    for label, report in reports:
        lines.extend(
            [
                f"## {label}",
                "",
                f"- Skills: {report['skills']}",
                f"- Blocking errors: {report['errors']}",
                f"- Warnings: {report['warnings']}",
                "",
            ]
        )
        if not report["findings"]:
            lines.extend(["No findings.", ""])
            continue
        lines.extend(
            [
                "| Severity | Skill | Code | Finding |",
                "|---|---|---|---|",
            ]
        )
        for finding in report["findings"]:
            message = finding["message"].replace("|", "\\|").replace("\n", " ")
            lines.append(
                f"| {finding['severity']} | `{finding['skill']}` | "
                f"`{finding['code']}` | {message} |"
            )
        lines.append("")
    return "\n".join(lines)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument(
        "--allow-errors",
        action="store_true",
        help="Report blocking findings without returning a failing status.",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    report = audit_root(args.root)
    rendered = render_report([("Skills", report)])
    if args.report:
        args.report.write_text(rendered, encoding="utf-8")
    else:
        print(rendered)
    if report["errors"] and not args.allow_errors:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
