#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README_PATH="${SCRIPT_DIR}/README.md"
SKILLS_DIR="${SCRIPT_DIR}/skills"

declare -i cloned_count=0
declare -i updated_count=0
declare -i unchanged_count=0
declare -i skipped_dirty_count=0
declare -i skipped_non_git_count=0
declare -i skipped_remote_count=0
declare -i failed_count=0

mkdir -p "$SKILLS_DIR"

log() {
  printf '%s\n' "$*"
}

normalize_repo_path() {
  local url="$1"
  local repo_path

  repo_path="${url#https://github.com/}"
  repo_path="${repo_path%%/tree/*}"
  repo_path="${repo_path%%/blob/*}"
  repo_path="${repo_path%/}"

  if [[ "$repo_path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf '%s\n' "$repo_path"
    return 0
  fi

  return 1
}

extract_repo_paths() {
  grep -E '^[[:space:]]*-[[:space:]]+\*\*\[[^]]+\]\(https://github\.com/[^)]+' "$README_PATH" |
    grep -oE 'https://github\.com/[^)]+' |
    while read -r url; do
      normalize_repo_path "$url" || true
    done |
    sort -u
}

clone_repo() {
  local repo_path="$1"
  local clone_url="$2"
  local target_dir="$3"

  log "CLONE: ${repo_path}"
  if git clone --depth 1 "$clone_url" "$target_dir"; then
    log "  OK: ${target_dir}"
    cloned_count+=1
  else
    log "  WARN: Failed to clone ${clone_url}"
    failed_count+=1
  fi
}

get_remote_default_ref() {
  local target_dir="$1"
  local symbolic_ref

  symbolic_ref="$(git -C "$target_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$symbolic_ref" ]]; then
    printf '%s\n' "${symbolic_ref#refs/remotes/}"
    return 0
  fi

  if git -C "$target_dir" rev-parse origin/main >/dev/null 2>&1; then
    printf '%s\n' "origin/main"
    return 0
  fi

  if git -C "$target_dir" rev-parse origin/master >/dev/null 2>&1; then
    printf '%s\n' "origin/master"
    return 0
  fi

  return 1
}

update_repo() {
  local repo_path="$1"
  local clone_url="$2"
  local target_dir="$3"
  local existing_remote
  local current_rev
  local remote_ref
  local remote_rev

  if [[ ! -d "${target_dir}/.git" ]]; then
    log "SKIP NON-GIT: ${repo_path} (${target_dir})"
    skipped_non_git_count+=1
    return 0
  fi

  if [[ -n "$(git -C "$target_dir" status --porcelain)" ]]; then
    log "SKIP DIRTY: ${repo_path}"
    skipped_dirty_count+=1
    return 0
  fi

  existing_remote="$(git -C "$target_dir" remote get-url origin 2>/dev/null || true)"
  if [[ "$existing_remote" != "$clone_url" ]]; then
    log "SKIP REMOTE: ${repo_path} (origin is ${existing_remote:-missing})"
    skipped_remote_count+=1
    return 0
  fi

  current_rev="$(git -C "$target_dir" rev-parse HEAD)"

  if ! git -C "$target_dir" fetch --depth 1 origin >/dev/null 2>&1; then
    log "WARN: Failed to fetch ${repo_path}"
    failed_count+=1
    return 0
  fi

  if ! remote_ref="$(get_remote_default_ref "$target_dir")"; then
    log "WARN: Could not determine remote default branch for ${repo_path}"
    failed_count+=1
    return 0
  fi

  remote_rev="$(git -C "$target_dir" rev-parse "$remote_ref")"

  if [[ "$current_rev" == "$remote_rev" ]]; then
    log "UNCHANGED: ${repo_path}"
    unchanged_count+=1
    return 0
  fi

  if git -C "$target_dir" reset --hard "$remote_ref" >/dev/null 2>&1; then
    log "UPDATED: ${repo_path}"
    updated_count+=1
  else
    log "WARN: Failed to reset ${repo_path} to ${remote_ref}"
    failed_count+=1
  fi
}

main() {
  local repo_path
  local author
  local repo
  local clone_url
  local target_dir

  while read -r repo_path; do
    [[ -n "$repo_path" ]] || continue

    author="${repo_path%%/*}"
    repo="${repo_path##*/}"
    clone_url="https://github.com/${author}/${repo}.git"
    target_dir="${SKILLS_DIR}/${author}-${repo}"

    if [[ -d "$target_dir" ]]; then
      update_repo "$repo_path" "$clone_url" "$target_dir"
    else
      clone_repo "$repo_path" "$clone_url" "$target_dir"
    fi
  done < <(extract_repo_paths)

  log ""
  log "Done. Skills synced to: ${SKILLS_DIR}"
  log "  cloned: ${cloned_count}"
  log "  updated: ${updated_count}"
  log "  unchanged: ${unchanged_count}"
  log "  skipped dirty: ${skipped_dirty_count}"
  log "  skipped non-git: ${skipped_non_git_count}"
  log "  skipped remote mismatch: ${skipped_remote_count}"
  log "  failed: ${failed_count}"
}

main "$@"
