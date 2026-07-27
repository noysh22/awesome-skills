#!/usr/bin/env bash

set -euo pipefail

SYNC_SCRIPT="/Users/noy/src/ai/scripts/sync-skills.sh"
TEMP_ROOTS=()

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

new_temp_root() {
  local temp_root
  temp_root="$(mktemp -d)"
  TEMP_ROOTS+=("$temp_root")
  printf '%s\n' "$temp_root"
}

cleanup() {
  local temp_root
  for temp_root in "${TEMP_ROOTS[@]}"; do
    [[ -d "$temp_root" ]] && find "$temp_root" -depth -delete
  done
}
trap cleanup EXIT

write_skill() {
  local source_root="$1"
  local skill_name="$2"
  /bin/mkdir -p "${source_root}/${skill_name}"
  printf '%s\n' "---" "name: ${skill_name}" "description: ${skill_name}" "---" > "${source_root}/${skill_name}/SKILL.md"
}

write_manifest() {
  local manifest="$1"
  shift
  {
    printf '%s\n' "version: 1" "skills:"
    local skill_name
    for skill_name in "$@"; do
      printf '  - name: %s\n' "$skill_name"
    done
    printf '%s\n' "candidates:" "  - name: candidate-only"
  } > "$manifest"
}

run_sync() {
  local source_root="$1"
  local target_root="$2"
  local manifest="$3"
  shift 3
  "$SYNC_SCRIPT" --source "$source_root" --target "$target_root" --manifest "$manifest" "$@"
}

test_links_only_manifest_approved_and_is_idempotent() {
  local temp_root source_root target_root manifest first_output second_output
  temp_root="$(new_temp_root)"
  source_root="${temp_root}/source"
  target_root="${temp_root}/target"
  manifest="${temp_root}/manifest.yaml"
  /bin/mkdir -p "$source_root"
  write_skill "$source_root" "alpha"
  write_skill "$source_root" "beta"
  write_skill "$source_root" "candidate-only"
  write_manifest "$manifest" "alpha" "beta"

  first_output="$(run_sync "$source_root" "$target_root" "$manifest")"
  [[ -L "${target_root}/alpha" ]] || fail "alpha was not linked"
  [[ -L "${target_root}/beta" ]] || fail "beta was not linked"
  [[ ! -L "${target_root}/candidate-only" ]] || fail "candidate was linked"
  [[ "$(readlink "${target_root}/alpha")" == "${source_root}/alpha" ]] || fail "alpha target mismatch"
  [[ "$first_output" == *"2 linked"* ]] || fail "first sync count mismatch"

  second_output="$(run_sync "$source_root" "$target_root" "$manifest")"
  [[ "$second_output" == *"2 unchanged"* ]] || fail "second sync was not idempotent"
}

test_removes_only_stale_managed_links_and_preserves_real_entries() {
  local temp_root source_root target_root manifest
  temp_root="$(new_temp_root)"
  source_root="${temp_root}/source"
  target_root="${temp_root}/target"
  manifest="${temp_root}/manifest.yaml"
  /bin/mkdir -p "$source_root"
  write_skill "$source_root" "alpha"
  write_skill "$source_root" "beta"
  write_manifest "$manifest" "alpha" "beta"
  run_sync "$source_root" "$target_root" "$manifest" >/dev/null

  /bin/unlink "${target_root}/beta"
  /bin/mkdir "${target_root}/beta"
  printf '%s' "preserve" > "${target_root}/beta/local.txt"
  write_manifest "$manifest" "alpha"
  run_sync "$source_root" "$target_root" "$manifest" >/dev/null

  [[ -L "${target_root}/alpha" ]] || fail "alpha was removed"
  [[ -f "${target_root}/beta/local.txt" ]] || fail "real stale entry was modified"
}

test_repairs_broken_managed_link_and_never_overwrites_real_directory() {
  local temp_root source_root target_root manifest
  temp_root="$(new_temp_root)"
  source_root="${temp_root}/source"
  target_root="${temp_root}/target"
  manifest="${temp_root}/manifest.yaml"
  /bin/mkdir -p "$source_root" "$target_root"
  write_skill "$source_root" "alpha"
  write_skill "$source_root" "beta"
  write_manifest "$manifest" "alpha" "beta"
  printf '%s\n' "alpha" > "${target_root}/.awesome-skills-managed"
  /bin/ln -s "${temp_root}/missing-alpha" "${target_root}/alpha"
  /bin/mkdir "${target_root}/beta"
  printf '%s' "local" > "${target_root}/beta/local.txt"

  run_sync "$source_root" "$target_root" "$manifest" --force >/dev/null

  [[ -L "${target_root}/alpha" ]] || fail "broken managed link was not repaired"
  [[ "$(readlink "${target_root}/alpha")" == "${source_root}/alpha" ]] || fail "alpha repair target mismatch"
  [[ -f "${target_root}/beta/local.txt" ]] || fail "force overwrote a real directory"
}

test_missing_manifest_skill_fails_before_changes() {
  local temp_root source_root target_root manifest
  temp_root="$(new_temp_root)"
  source_root="${temp_root}/source"
  target_root="${temp_root}/target"
  manifest="${temp_root}/manifest.yaml"
  /bin/mkdir -p "$source_root" "$target_root"
  write_manifest "$manifest" "missing"
  if run_sync "$source_root" "$target_root" "$manifest" >/dev/null 2>&1; then
    fail "sync succeeded with a missing manifest skill"
  fi
  [[ -z "$(find "$target_root" -mindepth 1 -print -quit)" ]] || fail "failed sync changed target"
}

main() {
  [[ -x "$SYNC_SCRIPT" ]] || fail "sync script is not executable"
  test_links_only_manifest_approved_and_is_idempotent
  test_removes_only_stale_managed_links_and_preserves_real_entries
  test_repairs_broken_managed_link_and_never_overwrites_real_directory
  test_missing_manifest_skill_fails_before_changes
  echo "PASS: sync-skills.sh"
}

main "$@"
