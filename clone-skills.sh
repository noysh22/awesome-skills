#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README_PATH="${SCRIPT_DIR}/README.md"
SKILLS_DIR="${SCRIPT_DIR}/skills"
CACHE_DIR="${SCRIPT_DIR}/.skills-cache"

declare -i cloned_count=0
declare -i migrated_count=0
declare -i updated_count=0
declare -i unchanged_count=0
declare -i skipped_dirty_count=0
declare -i skipped_non_git_count=0
declare -i skipped_remote_count=0
declare -i extracted_count=0
declare -i failed_count=0

STAGING_DIR=""

log() {
  printf '%s\n' "$*"
}

cleanup() {
  if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
    rm -rf "${STAGING_DIR}"
  fi
}

trap cleanup EXIT

mkdir -p "$SKILLS_DIR" "$CACHE_DIR"

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

normalize_skill_spec() {
  local url="$1"
  local repo_path=""
  local skill_path=""

  url="${url#https://github.com/}"
  url="${url%/}"

  if [[ "$url" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]]; then
    repo_path="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(tree|blob)/[^/]+/(.+)$ ]]; then
    repo_path="${BASH_REMATCH[1]}"
    skill_path="${BASH_REMATCH[3]}"
  else
    return 1
  fi

  if [[ -n "$skill_path" && "$(basename "$skill_path")" == "SKILL.md" ]]; then
    skill_path="$(dirname "$skill_path")"
    [[ "$skill_path" == "." ]] && skill_path=""
  fi

  printf '%s|%s\n' "$repo_path" "$skill_path"
}

extract_skill_specs() {
  grep -E '^[[:space:]]*-[[:space:]]+\*\*\[[^]]+\]\(https://github\.com/[^)]+' "$README_PATH" |
    grep -oE 'https://github\.com/[^)]+' |
    while read -r url; do
      normalize_skill_spec "$url" || true
    done |
    sort -u
}

sanitize_name() {
  local value="$1"

  value="$(printf '%s' "$value" | sed -E 's/[^A-Za-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
  printf '%s\n' "$value"
}

copy_tree_contents() {
  local source_dir="$1"
  local destination_dir="$2"

  mkdir -p "$destination_dir"
  if [[ -n "$(find "$source_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    cp -R "$source_dir"/. "$destination_dir"/
  fi
}

copy_referenced_paths() {
  local repo_dir="$1"
  local skill_dir="$2"
  local destination_dir="$3"
  local repo_dir_real
  local skill_dir_real
  local skill_md_path
  local link_target
  local resolved_path
  local relative_path
  local destination_path

  repo_dir_real="$(realpath "$repo_dir")"
  skill_dir_real="$(realpath "$skill_dir")"
  skill_md_path="${skill_dir_real}/SKILL.md"

  [[ -f "$skill_md_path" ]] || return 0

  { grep -oE '\]\([^)]*\)' "$skill_md_path" || true; } |
    sed -E 's/^\]\((.*)\)$/\1/' |
    while read -r link_target; do
      link_target="${link_target%%#*}"
      [[ -n "$link_target" ]] || continue

      case "$link_target" in
        http:*|https:*|mailto:*|/*)
          continue
          ;;
      esac

      resolved_path="$(cd "$(dirname "$skill_md_path")" && realpath "$link_target" 2>/dev/null || true)"
      [[ -n "$resolved_path" ]] || continue
      [[ "$resolved_path" == "$repo_dir_real"* ]] || continue

      if [[ "$skill_dir_real" != "$repo_dir_real" && "$resolved_path" == "$skill_dir_real"* ]]; then
        continue
      fi

      relative_path="${resolved_path#${repo_dir_real}/}"
      destination_path="${destination_dir}/${relative_path}"

      if [[ -d "$resolved_path" ]]; then
        copy_tree_contents "$resolved_path" "$destination_path"
      elif [[ -f "$resolved_path" ]]; then
        mkdir -p "$(dirname "$destination_path")"
        cp "$resolved_path" "$destination_path"
      fi
    done
}

skill_destination_name() {
  local repo_slug="$1"
  local repo_dir="$2"
  local skill_dir="$3"
  local relative_dir
  local sanitized_relative

  if [[ "$skill_dir" == "$repo_dir" ]]; then
    printf '%s\n' "$repo_slug"
    return 0
  fi

  relative_dir="${skill_dir#${repo_dir}/}"
  sanitized_relative="$(sanitize_name "$relative_dir")"
  printf '%s-%s\n' "$repo_slug" "$sanitized_relative"
}

discover_skill_roots() {
  local repo_dir="$1"

  find "$repo_dir" \
    \( -name .git -o -name node_modules -o -name .next -o -name target -o -name dist -o -name build -o -name vendor -o -name __pycache__ \) -prune -o \
    -name SKILL.md -type f -print |
    while read -r skill_md; do
      dirname "$skill_md"
    done |
    sort -u
}

extract_skill_dir() {
  local repo_path="$1"
  local cache_repo_dir="$2"
  local repo_slug="$3"
  local skill_dir="$4"
  local destination_name
  local destination_dir

  destination_name="$(skill_destination_name "$repo_slug" "$cache_repo_dir" "$skill_dir")"
  destination_dir="${STAGING_DIR}/${destination_name}"

  rm -rf "$destination_dir"

  if [[ "$skill_dir" == "$cache_repo_dir" ]]; then
    mkdir -p "$destination_dir"
    cp "${skill_dir}/SKILL.md" "${destination_dir}/SKILL.md"
  else
    copy_tree_contents "$skill_dir" "$destination_dir"
  fi

  copy_referenced_paths "$cache_repo_dir" "$skill_dir" "$destination_dir"

  log "EXTRACT: ${repo_path} -> ${destination_name}"
  extracted_count+=1
}

discover_nested_skill_roots() {
  local base_dir="$1"
  local skill_dir

  [[ -d "$base_dir" ]] || return 0

  while read -r skill_dir; do
    [[ -n "$skill_dir" ]] || continue
    [[ "$skill_dir" == "$base_dir" ]] && continue
    printf '%s\n' "$skill_dir"
  done < <(discover_skill_roots "$base_dir")
}

token_overlap_score() {
  local left="$1"
  local right="$2"
  local left_tokens=()
  local right_tokens=()
  local token
  local candidate
  local score=0
  local found=0

  IFS='-' read -r -a left_tokens <<< "$left"
  IFS='-' read -r -a right_tokens <<< "$right"

  for token in "${left_tokens[@]}"; do
    [[ -n "$token" ]] || continue
    found=0

    for candidate in "${right_tokens[@]}"; do
      if [[ "$token" == "$candidate" ]]; then
        found=1
        break
      fi
    done

    score=$((score + found))
  done

  printf '%s\n' "$score"
}

canonicalize_name() {
  local value="$1"

  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+//g')"
  printf '%s\n' "$value"
}

resolve_fuzzy_skill_dir() {
  local cache_repo_dir="$1"
  local requested_path="$2"
  local requested_name
  local requested_full
  local requested_name_canon
  local requested_full_canon
  local skill_dir
  local relative_dir
  local candidate_name
  local candidate_full
  local candidate_name_canon
  local candidate_full_canon
  local name_score
  local full_score
  local score
  local best_score=0
  local best_dir=""
  local tie=0

  requested_name="$(sanitize_name "${requested_path##*/}")"
  requested_full="$(sanitize_name "$requested_path")"
  requested_name_canon="$(canonicalize_name "${requested_path##*/}")"
  requested_full_canon="$(canonicalize_name "$requested_path")"

  while read -r skill_dir; do
    [[ -n "$skill_dir" ]] || continue
    [[ "$skill_dir" == "$cache_repo_dir" ]] && continue

    relative_dir="${skill_dir#${cache_repo_dir}/}"
    candidate_name="$(sanitize_name "${relative_dir##*/}")"
    candidate_full="$(sanitize_name "$relative_dir")"
    candidate_name_canon="$(canonicalize_name "${relative_dir##*/}")"
    candidate_full_canon="$(canonicalize_name "$relative_dir")"

    if [[ "$candidate_name" == "$requested_name" || "$candidate_full" == "$requested_full" ]]; then
      score=100
    elif [[ "$candidate_name_canon" == "$requested_name_canon" || "$candidate_full_canon" == "$requested_full_canon" ]]; then
      score=95
    else
      name_score="$(token_overlap_score "$requested_name" "$candidate_name")"
      full_score="$(token_overlap_score "$requested_name" "$candidate_full")"
      if [[ "$name_score" -ge "$full_score" ]]; then
        score="$name_score"
      else
        score="$full_score"
      fi
    fi

    if [[ "$score" -gt "$best_score" ]]; then
      best_score="$score"
      best_dir="$skill_dir"
      tie=0
    elif [[ "$score" -eq "$best_score" && "$score" -gt 0 ]]; then
      tie=1
    fi
  done < <(discover_skill_roots "$cache_repo_dir")

  if [[ -z "$best_dir" || "$tie" -eq 1 ]]; then
    return 1
  fi

  if [[ "$best_score" -lt 2 && "$best_score" -lt 95 ]]; then
    return 1
  fi

  printf '%s\n' "$best_dir"
}

extract_requested_path() {
  local repo_path="$1"
  local cache_repo_dir="$2"
  local repo_slug="$3"
  local requested_path="$4"
  local skill_dir
  local child_skill_dir
  local extracted_any=0
  local fuzzy_match
  local fuzzy_relative

  if [[ -z "$requested_path" ]]; then
    while read -r skill_dir; do
      [[ -n "$skill_dir" ]] || continue
      extract_skill_dir "$repo_path" "$cache_repo_dir" "$repo_slug" "$skill_dir"
    done < <(discover_skill_roots "$cache_repo_dir")
    return 0
  fi

  skill_dir="${cache_repo_dir}/${requested_path}"

  if [[ -d "$skill_dir" && -f "${skill_dir}/SKILL.md" ]]; then
    extract_skill_dir "$repo_path" "$cache_repo_dir" "$repo_slug" "$skill_dir"
    return 0
  fi

  if [[ -d "$skill_dir" ]]; then
    while read -r child_skill_dir; do
      [[ -n "$child_skill_dir" ]] || continue
      extract_skill_dir "$repo_path" "$cache_repo_dir" "$repo_slug" "$child_skill_dir"
      extracted_any=1
    done < <(discover_nested_skill_roots "$skill_dir")

    if [[ "$extracted_any" -eq 1 ]]; then
      log "EXPAND: ${repo_path} -> ${requested_path}"
      return 0
    fi
  fi

  fuzzy_match="$(resolve_fuzzy_skill_dir "$cache_repo_dir" "$requested_path" || true)"
  if [[ -n "$fuzzy_match" ]]; then
    fuzzy_relative="${fuzzy_match#${cache_repo_dir}/}"
    log "MAP: ${repo_path} -> ${requested_path} => ${fuzzy_relative}"
    extract_skill_dir "$repo_path" "$cache_repo_dir" "$repo_slug" "$fuzzy_match"
    return 0
  fi

  log "WARN: Missing skill path for ${repo_path}: ${requested_path}"
  failed_count+=1
  return 0
}

extract_requested_skills_from_repo() {
  local repo_path="$1"
  local cache_repo_dir="$2"
  local repo_slug="$3"
  shift 3
  local requested_paths=("$@")
  local requested_path

  for requested_path in "${requested_paths[@]}"; do
    extract_requested_path "$repo_path" "$cache_repo_dir" "$repo_slug" "$requested_path"
  done
}

repo_has_root_skill() {
  local cache_repo_dir="$1"

  [[ -f "${cache_repo_dir}/SKILL.md" ]]
}

repo_requests_subpaths() {
  local requested_path

  for requested_path in "$@"; do
    if [[ -n "$requested_path" ]]; then
      return 0
    fi
  done

  return 1
}

extract_repo_selection() {
  local repo_path="$1"
  local cache_repo_dir="$2"
  local repo_slug="$3"
  shift 3
  local requested_paths=("$@")

  if repo_has_root_skill "$cache_repo_dir" && repo_requests_subpaths "${requested_paths[@]}"; then
    extract_skill_dir "$repo_path" "$cache_repo_dir" "$repo_slug" "$cache_repo_dir"
    return 0
  fi

  if repo_has_root_skill "$cache_repo_dir" && [[ "${#requested_paths[@]}" -eq 1 && -z "${requested_paths[0]}" ]]; then
    extract_skill_dir "$repo_path" "$cache_repo_dir" "$repo_slug" "$cache_repo_dir"
    return 0
  fi

  extract_requested_skills_from_repo "$repo_path" "$cache_repo_dir" "$repo_slug" "${requested_paths[@]}"
}

process_repo_specs() {
  local repo_path="$1"
  shift
  local requested_paths=("$@")
  local author
  local repo
  local repo_slug
  local clone_url
  local cache_repo_dir

  [[ -n "$repo_path" ]] || return 0

  author="${repo_path%%/*}"
  repo="${repo_path##*/}"
  repo_slug="${author}-${repo}"
  clone_url="https://github.com/${author}/${repo}.git"
  cache_repo_dir="${CACHE_DIR}/${repo_slug}"

  migrate_legacy_repo_if_needed "$repo_path" "$repo_slug" "$cache_repo_dir"

  if sync_cache_repo "$repo_path" "$clone_url" "$cache_repo_dir"; then
    extract_repo_selection "$repo_path" "$cache_repo_dir" "$repo_slug" "${requested_paths[@]}"
  fi
}

get_remote_default_ref() {
  local repo_dir="$1"
  local symbolic_ref

  symbolic_ref="$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$symbolic_ref" ]]; then
    printf '%s\n' "${symbolic_ref#refs/remotes/}"
    return 0
  fi

  if git -C "$repo_dir" rev-parse origin/main >/dev/null 2>&1; then
    printf '%s\n' "origin/main"
    return 0
  fi

  if git -C "$repo_dir" rev-parse origin/master >/dev/null 2>&1; then
    printf '%s\n' "origin/master"
    return 0
  fi

  return 1
}

migrate_legacy_repo_if_needed() {
  local repo_path="$1"
  local repo_slug="$2"
  local cache_repo_dir="$3"
  local legacy_repo_dir="${SKILLS_DIR}/${repo_slug}"

  if [[ -d "${cache_repo_dir}" ]]; then
    return 0
  fi

  if [[ -d "${legacy_repo_dir}/.git" ]]; then
    log "MIGRATE: ${repo_path}"
    mv "${legacy_repo_dir}" "${cache_repo_dir}"
    migrated_count+=1
  fi
}

clone_repo_to_cache() {
  local repo_path="$1"
  local clone_url="$2"
  local cache_repo_dir="$3"

  log "CLONE: ${repo_path}"
  if git clone --depth 1 "$clone_url" "$cache_repo_dir"; then
    cloned_count+=1
    return 0
  fi

  log "  WARN: Failed to clone ${clone_url}"
  failed_count+=1
  return 1
}

sync_cache_repo() {
  local repo_path="$1"
  local clone_url="$2"
  local cache_repo_dir="$3"
  local existing_remote
  local current_rev
  local remote_ref
  local remote_rev

  if [[ ! -d "${cache_repo_dir}" ]]; then
    clone_repo_to_cache "$repo_path" "$clone_url" "$cache_repo_dir"
    return $?
  fi

  if [[ ! -d "${cache_repo_dir}/.git" ]]; then
    log "SKIP NON-GIT CACHE: ${repo_path}"
    skipped_non_git_count+=1
    return 1
  fi

  if [[ -n "$(git -C "$cache_repo_dir" status --porcelain)" ]]; then
    log "SKIP UPDATE DIRTY: ${repo_path}"
    skipped_dirty_count+=1
    return 0
  fi

  existing_remote="$(git -C "$cache_repo_dir" remote get-url origin 2>/dev/null || true)"
  if [[ "$existing_remote" != "$clone_url" ]]; then
    log "SKIP REMOTE: ${repo_path} (origin is ${existing_remote:-missing})"
    skipped_remote_count+=1
    return 0
  fi

  current_rev="$(git -C "$cache_repo_dir" rev-parse HEAD)"

  if ! git -C "$cache_repo_dir" fetch --depth 1 origin >/dev/null 2>&1; then
    log "WARN: Failed to fetch ${repo_path}"
    failed_count+=1
    return 0
  fi

  if ! remote_ref="$(get_remote_default_ref "$cache_repo_dir")"; then
    log "WARN: Could not determine remote default branch for ${repo_path}"
    failed_count+=1
    return 0
  fi

  remote_rev="$(git -C "$cache_repo_dir" rev-parse "$remote_ref")"
  if [[ "$current_rev" == "$remote_rev" ]]; then
    log "UNCHANGED: ${repo_path}"
    unchanged_count+=1
    return 0
  fi

  if git -C "$cache_repo_dir" reset --hard "$remote_ref" >/dev/null 2>&1; then
    log "UPDATED: ${repo_path}"
    updated_count+=1
    return 0
  fi

  log "WARN: Failed to reset ${repo_path} to ${remote_ref}"
  failed_count+=1
  return 0
}

replace_skills_directory() {
  mkdir -p "$SKILLS_DIR"
  find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

  if [[ -n "$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -exec mv {} "$SKILLS_DIR"/ \;
  fi
}

main() {
  local repo_path
  local requested_path
  local pending_repo_path=""
  local -a pending_requested_paths=()
  local current_repo_path=""

  STAGING_DIR="$(mktemp -d "${SCRIPT_DIR}/.skills-staging.XXXXXX")"

  while IFS='|' read -r repo_path requested_path; do
    [[ -n "$repo_path" ]] || continue

    if [[ -n "$current_repo_path" && "$repo_path" != "$current_repo_path" ]]; then
      process_repo_specs "$current_repo_path" "${pending_requested_paths[@]}"
      pending_requested_paths=()
    fi

    current_repo_path="$repo_path"
    pending_requested_paths+=("$requested_path")
  done < <(extract_skill_specs)

  process_repo_specs "$current_repo_path" "${pending_requested_paths[@]}"

  replace_skills_directory

  log ""
  log "Done. Skills synced to: ${SKILLS_DIR}"
  log "  cloned: ${cloned_count}"
  log "  migrated: ${migrated_count}"
  log "  updated: ${updated_count}"
  log "  unchanged: ${unchanged_count}"
  log "  skipped dirty updates: ${skipped_dirty_count}"
  log "  skipped non-git cache repos: ${skipped_non_git_count}"
  log "  skipped remote mismatch: ${skipped_remote_count}"
  log "  extracted skills: ${extracted_count}"
  log "  failed: ${failed_count}"
}

main "$@"
