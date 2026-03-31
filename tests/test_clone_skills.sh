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

make_fake_git() {
  local fake_bin_dir="$1"
  local log_file="$2"

  mkdir -p "$fake_bin_dir"

  cat > "${fake_bin_dir}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${FAKE_GIT_LOG:?}"

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
    repo_name="$(basename "$target_dir")"
    log "clone ${clone_url} ${target_dir}"
    mkdir -p "${target_dir}/.git"
    write_repo_file "$target_dir" "url" "$clone_url"
    write_repo_file "$target_dir" "current-rev" "initial-${repo_name}"
    write_repo_file "$target_dir" "remote-rev" "initial-${repo_name}"
    write_repo_file "$target_dir" "dirty" "clean"
    ;;

  rev-parse)
    subcmd="${1:-}"
    if [[ "$subcmd" == "--is-inside-work-tree" ]]; then
      log "rev-parse-is-inside ${repo_dir}"
      [[ -d "${repo_dir}/.git" ]] || exit 1
      echo "true"
    elif [[ "$subcmd" == "HEAD" ]]; then
      log "rev-parse-head ${repo_dir}"
      read_repo_file "$repo_dir" "current-rev"
    else
      log "rev-parse ${repo_dir} ${subcmd}"
      ref="$subcmd"
      if [[ "$ref" == "origin/main" ]]; then
        read_repo_file "$repo_dir" "remote-rev"
      else
        exit 91
      fi
    fi
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
    ;;

  symbolic-ref)
    log "symbolic-ref ${repo_dir} $*"
    echo "refs/remotes/origin/main"
    ;;

  reset)
    [[ "${1:-}" == "--hard" ]] || exit 95
    ref="${2:-}"
    log "reset ${repo_dir} ${ref}"
    if [[ "$ref" == "origin/main" ]]; then
      write_repo_file "$repo_dir" "current-rev" "$(read_repo_file "$repo_dir" "remote-rev")"
    else
      exit 96
    fi
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

make_workspace() {
  local workspace="$1"

  mkdir -p "$workspace"
  cp "$SOURCE_SCRIPT" "${workspace}/clone-skills.sh"
  chmod +x "${workspace}/clone-skills.sh"
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

run_script() {
  local workspace="$1"
  local fake_bin_dir="$2"
  local log_file="$3"
  (
    cd "$workspace"
    PATH="${fake_bin_dir}:$PATH" \
    FAKE_GIT_LOG="$log_file" \
    ./clone-skills.sh
  )
}

test_clones_only_skill_repositories() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
<a href="https://github.com/VoltAgent/voltagent">header</a>

- **[owner-one/repo-one](https://github.com/owner-one/repo-one/tree/main/skills/first)** - first skill
- **[owner-two/repo-two](https://github.com/owner-two/repo-two)** - second skill

Official marketing skills by [Corey Haines](https://github.com/coreyhaines31), covering SaaS marketing.
Please [open an issue](https://github.com/VoltAgent/awesome-agent-skills/issues) if something is wrong.
EOF

  run_script "$workspace" "$fake_bin" "$git_log" >/dev/null

  assert_exists "${workspace}/skills/owner-one-repo-one/.git"
  assert_exists "${workspace}/skills/owner-two-repo-two/.git"
  assert_not_exists "${workspace}/skills/VoltAgent-voltagent"
  assert_not_exists "${workspace}/skills/coreyhaines31-"
  assert_not_exists "${workspace}/skills/VoltAgent-awesome-agent-skills"
}

test_updates_existing_clean_repositories() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local target_repo

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/repo-one](https://github.com/owner-one/repo-one)** - first skill
EOF

  run_script "$workspace" "$fake_bin" "$git_log" >/dev/null

  target_repo="${workspace}/skills/owner-one-repo-one"
  printf 'remote-repo-one' > "${target_repo}/.git/mock-remote-rev"

  run_script "$workspace" "$fake_bin" "$git_log" >/dev/null

  assert_file_contains "$git_log" "fetch ${target_repo}"
  assert_file_contains "$git_log" "reset ${target_repo} origin/main"
  assert_file_contains "${target_repo}/.git/mock-current-rev" "remote-repo-one"
}

test_skips_dirty_repositories_without_resetting_them() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local target_repo
  local output_file="${temp_root}/output.log"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/repo-one](https://github.com/owner-one/repo-one)** - first skill
EOF

  run_script "$workspace" "$fake_bin" "$git_log" >/dev/null

  target_repo="${workspace}/skills/owner-one-repo-one"
  printf 'dirty' > "${target_repo}/.git/mock-dirty"
  printf 'remote-repo-one' > "${target_repo}/.git/mock-remote-rev"

  run_script "$workspace" "$fake_bin" "$git_log" >"$output_file"

  assert_file_contains "$git_log" "status ${target_repo}"
  assert_file_not_contains "$git_log" "reset ${target_repo} origin/main"
  assert_file_not_contains "${target_repo}/.git/mock-current-rev" "remote-repo-one"
  assert_file_contains "$output_file" "SKIP DIRTY: owner-one/repo-one"
}

test_skips_non_git_directories() {
  local temp_root
  temp_root="$(new_temp_root)"

  local workspace="${temp_root}/workspace"
  local fake_bin="${temp_root}/bin"
  local git_log="${temp_root}/git.log"
  local output_file="${temp_root}/output.log"

  make_workspace "$workspace"
  make_fake_git "$fake_bin" "$git_log"

  cat > "${workspace}/README.md" <<'EOF'
- **[owner-one/repo-one](https://github.com/owner-one/repo-one)** - first skill
EOF

  mkdir -p "${workspace}/skills/owner-one-repo-one"

  run_script "$workspace" "$fake_bin" "$git_log" >"$output_file"

  assert_file_contains "$output_file" "SKIP NON-GIT: owner-one/repo-one"
  assert_file_not_contains "$git_log" "clone https://github.com/owner-one/repo-one.git"
}

main() {
  test_clones_only_skill_repositories
  test_updates_existing_clean_repositories
  test_skips_dirty_repositories_without_resetting_them
  test_skips_non_git_directories
  echo "PASS: clone-skills.sh"
}

trap cleanup EXIT

main "$@"
