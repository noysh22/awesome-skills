#!/bin/bash
# Clone all Claude Skills repositories from the README

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="${SCRIPT_DIR}/skills"

mkdir -p "$SKILLS_DIR"

# Extract GitHub URLs, normalize to author/repo, dedupe, then clone
grep -oE 'https://github\.com/[^)\"]+' "$SCRIPT_DIR/README.md" | \
    grep -v '/assets/' | \
    grep -v '/network/' | \
    sed -E 's|https://github\.com/||' | \
    sed -E 's|/tree/.*||' | \
    sed -E 's|/blob/.*||' | \
    sort -u | \
while read -r repo_path; do
    # Get author and repo name
    author=$(echo "$repo_path" | cut -d'/' -f1)
    repo=$(echo "$repo_path" | cut -d'/' -f2)
    
    if [[ -z "$author" || -z "$repo" ]]; then
        continue
    fi
    
    clone_url="https://github.com/${author}/${repo}.git"
    target_dir="${SKILLS_DIR}/${author}-${repo}"
    
    if [[ -d "$target_dir" ]]; then
        echo "SKIP: ${author}/${repo} (already exists)"
        continue
    fi
    
    echo "CLONE: ${author}/${repo}"
    if git clone --depth 1 "$clone_url" "$target_dir" 2>/dev/null; then
        echo "  OK: ${target_dir}"
    else
        echo "  WARN: Failed to clone ${clone_url}"
    fi
done

echo ""
echo "Done. Skills cloned to: ${SKILLS_DIR}"
