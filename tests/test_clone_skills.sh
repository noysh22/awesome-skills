#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="${ROOT_DIR}/clone-skills.sh"
TEMP_ROOTS=()

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_exists() {
  local path="$1"
  [[ -e "$path" ]] || fail "expected path to exist: $path"
}

assert_not_exists() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "expected path to not exist: $path"
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fq "$pattern" "$file" || fail "expected '$file' to contain: $pattern"
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -Fq "$pattern" "$file"; then
    fail "expected '$file' to not contain: $pattern"
  fi
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
    rm -rf "$temp_root"
  done
}

make_workspace() {
  local workspace="$1"

  mkdir -p "$workspace"
  cp "$SOURCE_SCRIPT" "${workspace}/clone-skills.sh"
  chmod +x "${workspace}/clone-skills.sh"
}

make_fake_git() {
  local fake_bin_dir="$1"
  local log_file="$2"

  mkdir -p "$fake_bin_dir"

  cat > "${fake_bin_dir}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${FAKE_GIT_LOG:?}"
remote_root="${FAKE_REMOTE_ROOT:?}"

log() {
  echo "$*" >> "$log_file"
}

write_repo_file() {
  local repo_dir="$1"
  local name="$2"
  local value="$3"
  printf '%s' "$value" > "${repo_dir}/.git/mock-${name}"
}

read_repo_file() {
  local repo_dir="$1"
  local name="$2"
  cat "${repo_dir}/.git/mock-${name}"
}

remote_head_for_repo() {
  local repo_key="$1"
  cat "${remote_root}/${repo_key}/REMOTE_HEAD"
}

populate_repo() {
  local repo_dir="$1"
  local repo_key="$2"
  local rev="$3"
  local snapshot_dir="${remote_root}/${repo_key}/${rev}"

  mkdir -p "$repo_dir"
  find "$repo_dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +

  if [[ -d "$snapshot_dir" ]]; then
    cp -R "${snapshot_dir}/." "$repo_dir/"
  fi
}

if [[ "${1:-}" == "-C" ]]; then
  repo_dir="$2"
  shift 2
else
  repo_dir=""
fi

cmd="${1:-}"
shift || true

case "$cmd" in
  clone)
    [[ "${1:-}" == "--depth" ]] || exit 90
    shift 2
    clone_url="$1"
    target_dir="$2"
    repo_key="$(basename "$clone_url" .git)"
    owner="$(basename "$(dirname "$clone_url")")"
    repo_key="${owner}-${repo_key}"
    head_rev="$(remote_head_for_repo "$repo_key")"

    log "clone ${clone_url} ${target_dir}"
    mkdir -p "${target_dir}/.git"
    write_repo_file "$target_dir" "url" "$clone_url"
    write_repo_file "$target_dir" "repo-key" "$repo_key"
    write_repo_file "$target_dir" "current-rev" "$head_rev"
    write_repo_file "$target_dir" "remote-rev" "$head_rev"
    write_repo_file "$target_dir" "dirty" "clean"
    populate_repo "$target_dir" "$repo_key" "$head_rev"
    ;;

  rev-parse)
    subcmd="${1:-}"
    case "$subcmd" in
      --is-inside-work-tree)
        log "rev-parse-is-inside ${repo_dir}"
        [[ -d "${repo_dir}/.git" ]] || exit 1
        echo "true"
        ;;
      HEAD)
        log "rev-parse-head ${repo_dir}"
        read_repo_file "$repo_dir" "current-rev"
        ;;
      origin/main|origin/master)
        log "rev-parse ${repo_dir} ${subcmd}"
        read_repo_file "$repo_dir" "remote-rev"
        ;;
      *)
        exit 91
        ;;
    esac
    ;;

  status)
    [[ "${1:-}" == "--porcelain" ]] || exit 92
    log "status ${repo_dir}"
    if [[ "$(read_repo_file "$repo_dir" "dirty")" == "dirty" ]]; then
      echo " M README.md"
    fi
    ;;

  remote)
    [[ "${1:-}" == "get-url" ]] || exit 93
    [[ "${2:-}" == "origin" ]] || exit 94
    log "remote-get-url ${repo_dir}"
    read_repo_file "$repo_dir" "url"
    ;;

  fetch)
    log "fetch ${repo_dir} $*"
    repo_key="$(read_repo_file "$repo_dir" "repo-key")"
    write_repo_file "$repo_dir" "remote-rev" "$(remote_head_for_repo "$repo_key")"
    ;;

  symbolic-ref)
    log "symbolic-ref ${repo_dir} $*"
    echo "refs/remotes/origin/main"
    ;;

  reset)
    [[ "${1:-}" == "--hard" ]] || exit 95
    ref="${2:-}"
    log "reset ${repo_dir} ${ref}"
    [[ "$ref" == "origin/main" || "$ref" == "origin/master" ]] || exit 96
    repo_key="$(read_repo_file "$repo_dir" "repo-key")"
    new_rev="$(read_repo_file "$repo_dir" "remote-rev")"
    write_repo_file "$repo_dir" "current-rev" "$new_rev"
    populate_repo "$repo_dir" "$repo_key" "$new_rev"
    ;;

  *)
    log "unexpected ${cmd} ${repo_dir} $*"
    exit 97
    ;;
esac
EOF

  chmod +x "${fake_bin_dir}/git"
  : > "$log_file"
}

write_remote_file() {
  local remote_root="$1"
  local repo_key="$2"
  local rev="$3"
  local relative_path="$4"
  local content="$5"
  local target_path="${remote_root}/${repo_key}/${rev}/${relative_path}"

  mkdir -p "$(dirname "$target_path")"
  printf '%s' "$content" > "$target_path"
}

set_remote_head() {
  local remote_root="$1"
  local repo_key="$2"
  local rev="$3"

  mkdir -p "${remote_root}/${repo_key}"
  printf '%s' "$rev" > "${remote_root}/${repo_key}/REMOTE_HEAD"
}

run_script() {
  local workspace="$1"
  local fake_bin_dir="$2"
  local log_file="$3"
  local remote_root="$4"
  (
    cd "$workspace"
    PATH="${fake_bin_dir}:$PATH" \
    FAKE_GIT_LOG="$log_file" \
    FAKE_REMOTE_ROOT="$remote_root" \
    ./clone-skills.sh --all-from-readme
  )
}

test_extracts_only_requested_skill_path() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local remote_root="${temp_root}/remotes"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/first](https://github.com/owner-one/repo-one/tree/main/skills/first)** - first skill repo
EOF

  set_remote_head "$remote_root" "owner-one-repo-one" "rev1"
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/first/SKILL.md" $'---\nname: first\ndescription: first\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/first/helper.txt" 'first-helper'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/second/SKILL.md" $'---\nname: second\ndescription: second\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "docs/ignore.md" 'ignore-me'

  run_script "$workspace" "$fake_bin" "$git_log" "$remote_root" >/dev/null

  assert_exists "${workspace}/.skills-cache/owner-one-repo-one/.git"
  assert_exists "${workspace}/skills/owner-one-repo-one-skills-first/SKILL.md"
  assert_exists "${workspace}/skills/owner-one-repo-one-skills-first/helper.txt"
  assert_not_exists "${workspace}/skills/owner-one-repo-one-skills-second/SKILL.md"
  assert_not_exists "${workspace}/skills/owner-one-repo-one"
  assert_not_exists "${workspace}/skills/owner-one-repo-one-skills-first/.git"
  assert_not_exists "${workspace}/skills/owner-one-repo-one-skills-first/docs/ignore.md"
}

test_extracts_root_skill_without_copying_whole_repo() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local remote_root="${temp_root}/remotes"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/repo-one](https://github.com/owner-one/repo-one)** - first skill repo
EOF

  set_remote_head "$remote_root" "owner-one-repo-one" "rev1"
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "SKILL.md" $'---\nname: collection\ndescription: root skill\n---\n\nSee [child](skills/child/SKILL.md).\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/child/SKILL.md" $'---\nname: child\ndescription: child skill\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "docs/ignore.md" 'ignore-me'

  run_script "$workspace" "$fake_bin" "$git_log" "$remote_root" >/dev/null

  assert_exists "${workspace}/skills/owner-one-repo-one/SKILL.md"
  assert_exists "${workspace}/skills/owner-one-repo-one/skills/child/SKILL.md"
  assert_not_exists "${workspace}/skills/owner-one-repo-one/docs/ignore.md"
}

test_extracts_multiple_requested_paths_from_same_repo() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local remote_root="${temp_root}/remotes"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/first](https://github.com/owner-one/repo-one/tree/main/skills/first)** - first skill repo
- **[owner-one/second](https://github.com/owner-one/repo-one/tree/main/skills/second)** - second skill repo
EOF

  set_remote_head "$remote_root" "owner-one-repo-one" "rev1"
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/first/SKILL.md" $'---\nname: first\ndescription: first\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/second/SKILL.md" $'---\nname: second\ndescription: second\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/third/SKILL.md" $'---\nname: third\ndescription: third\n---\n'

  run_script "$workspace" "$fake_bin" "$git_log" "$remote_root" >/dev/null

  assert_exists "${workspace}/skills/owner-one-repo-one-skills-first/SKILL.md"
  assert_exists "${workspace}/skills/owner-one-repo-one-skills-second/SKILL.md"
  assert_not_exists "${workspace}/skills/owner-one-repo-one-skills-third/SKILL.md"
}

test_collapses_collection_repo_to_root_skill() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local remote_root="${temp_root}/remotes"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/first](https://github.com/owner-one/repo-one/tree/main/skills/first)** - first skill repo
- **[owner-one/second](https://github.com/owner-one/repo-one/tree/main/skills/second)** - second skill repo
EOF

  set_remote_head "$remote_root" "owner-one-repo-one" "rev1"
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "SKILL.md" $'---\nname: collection\ndescription: root collection\n---\n\nSee [first](skills/first/SKILL.md).\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/first/SKILL.md" $'---\nname: first\ndescription: first\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/second/SKILL.md" $'---\nname: second\ndescription: second\n---\n'

  run_script "$workspace" "$fake_bin" "$git_log" "$remote_root" >/dev/null

  assert_exists "${workspace}/skills/owner-one-repo-one/SKILL.md"
  assert_exists "${workspace}/skills/owner-one-repo-one/skills/first/SKILL.md"
  assert_not_exists "${workspace}/skills/owner-one-repo-one-skills-first/SKILL.md"
  assert_not_exists "${workspace}/skills/owner-one-repo-one-skills-second/SKILL.md"
}

test_expands_container_directory_without_root_skill() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local remote_root="${temp_root}/remotes"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/repo-one](https://github.com/owner-one/repo-one/tree/main/skills)** - skill collection folder
EOF

  set_remote_head "$remote_root" "owner-one-repo-one" "rev1"
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/first/SKILL.md" $'---\nname: first\ndescription: first\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/second/SKILL.md" $'---\nname: second\ndescription: second\n---\n'

  run_script "$workspace" "$fake_bin" "$git_log" "$remote_root" >/dev/null

  assert_exists "${workspace}/skills/owner-one-repo-one-skills-first/SKILL.md"
  assert_exists "${workspace}/skills/owner-one-repo-one-skills-second/SKILL.md"
  assert_not_exists "${workspace}/skills/owner-one-repo-one/SKILL.md"
}

test_maps_stale_requested_path_to_unique_skill() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local remote_root="${temp_root}/remotes"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/vercel-deploy-claimable](https://github.com/owner-one/repo-one/tree/main/skills/claude.ai/vercel-deploy-claimable)** - stale path
EOF

  set_remote_head "$remote_root" "owner-one-repo-one" "rev1"
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/deploy-to-vercel/SKILL.md" $'---\nname: deploy\ndescription: deploy\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/react-best-practices/SKILL.md" $'---\nname: react\ndescription: react\n---\n'

  run_script "$workspace" "$fake_bin" "$git_log" "$remote_root" >/dev/null

  assert_exists "${workspace}/skills/owner-one-repo-one-skills-deploy-to-vercel/SKILL.md"
  assert_not_exists "${workspace}/skills/owner-one-repo-one-skills-react-best-practices/SKILL.md"
}

test_maps_canonicalized_skill_name() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local remote_root="${temp_root}/remotes"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/hugging-face-datasets](https://github.com/owner-one/repo-one/tree/main/skills/hugging-face-datasets)** - canonical rename
EOF

  set_remote_head "$remote_root" "owner-one-repo-one" "rev1"
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/huggingface-datasets/SKILL.md" $'---\nname: datasets\ndescription: datasets\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/huggingface-jobs/SKILL.md" $'---\nname: jobs\ndescription: jobs\n---\n'

  run_script "$workspace" "$fake_bin" "$git_log" "$remote_root" >/dev/null

  assert_exists "${workspace}/skills/owner-one-repo-one-skills-huggingface-datasets/SKILL.md"
  assert_not_exists "${workspace}/skills/owner-one-repo-one-skills-huggingface-jobs/SKILL.md"
}

test_updates_cache_and_refreshes_extracted_skills() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local remote_root="${temp_root}/remotes"
  local cache_repo="${workspace}/.skills-cache/owner-one-repo-one"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/first](https://github.com/owner-one/repo-one/tree/main/skills/first)** - first skill repo
EOF

  set_remote_head "$remote_root" "owner-one-repo-one" "rev1"
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/first/SKILL.md" $'---\nname: first\ndescription: first\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/first/content.txt" 'v1'

  run_script "$workspace" "$fake_bin" "$git_log" "$remote_root" >/dev/null
  assert_file_contains "${workspace}/skills/owner-one-repo-one-skills-first/content.txt" 'v1'

  set_remote_head "$remote_root" "owner-one-repo-one" "rev2"
  write_remote_file "$remote_root" "owner-one-repo-one" "rev2" "skills/first/SKILL.md" $'---\nname: first\ndescription: first\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev2" "skills/first/content.txt" 'v2'

  run_script "$workspace" "$fake_bin" "$git_log" "$remote_root" >/dev/null

  assert_file_contains "$git_log" "fetch ${cache_repo} --depth 1 origin"
  assert_file_contains "$git_log" "reset ${cache_repo} origin/main"
  assert_file_contains "${workspace}/skills/owner-one-repo-one-skills-first/content.txt" 'v2'
}

test_migrates_legacy_repo_clone_out_of_skills() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local remote_root="${temp_root}/remotes"
  local legacy_repo="${workspace}/skills/owner-one-repo-one"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/first](https://github.com/owner-one/repo-one/tree/main/skills/first)** - first skill repo
EOF

  set_remote_head "$remote_root" "owner-one-repo-one" "rev1"
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/first/SKILL.md" $'---\nname: first\ndescription: first\n---\n'
  write_remote_file "$remote_root" "owner-one-repo-one" "rev1" "skills/first/content.txt" 'v1'

  mkdir -p "${workspace}/skills"
  PATH="${fake_bin}:$PATH" FAKE_GIT_LOG="$git_log" FAKE_REMOTE_ROOT="$remote_root" \
    git clone --depth 1 "https://github.com/owner-one/repo-one.git" "$legacy_repo" >/dev/null

  run_script "$workspace" "$fake_bin" "$git_log" "$remote_root" >/dev/null

  assert_exists "${workspace}/.skills-cache/owner-one-repo-one/.git"
  assert_exists "${workspace}/skills/owner-one-repo-one-skills-first/SKILL.md"
  assert_not_exists "${workspace}/skills/owner-one-repo-one/.git"
}

main() {
  test_extracts_only_requested_skill_path
  test_extracts_root_skill_without_copying_whole_repo
  test_extracts_multiple_requested_paths_from_same_repo
  test_collapses_collection_repo_to_root_skill
  test_expands_container_directory_without_root_skill
  test_maps_stale_requested_path_to_unique_skill
  test_maps_canonicalized_skill_name
  test_updates_cache_and_refreshes_extracted_skills
  test_migrates_legacy_repo_clone_out_of_skills
  echo "PASS: clone-skills.sh"
}

trap cleanup EXIT

main "$@"
