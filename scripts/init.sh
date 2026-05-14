#!/usr/bin/env bash
# Bootstraps the agent-plugin-dev workspace.
#
# - Clones each repo listed in ../workspace.json (skips repos already present).
# - Creates the dev-test/ symlinks that point back to the real plugin repos.
# - If symlink creation fails, prints the ln commands so the user can run
#   them manually with the right permissions.
#
# Idempotent: safe to run multiple times.
#
# Dependencies: bash, git, jq.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
manifest="$repo_root/workspace.json"

if [[ ! -f "$manifest" ]]; then
    echo "[error] workspace.json not found at $manifest" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[error] jq is required but not installed" >&2
    exit 1
fi

echo
echo "=== Cloning sub-repos ==="

repo_count="$(jq '.repos | length' "$manifest")"
for ((i = 0; i < repo_count; i++)); do
    name="$(jq -r ".repos[$i].name" "$manifest")"
    path="$(jq -r ".repos[$i].path" "$manifest")"
    remote="$(jq -r ".repos[$i].remote" "$manifest")"
    branch="$(jq -r ".repos[$i].branch" "$manifest")"
    target="$repo_root/$path"

    if [[ -d "$target/.git" ]]; then
        echo "  [skip] $name already present at $path"
        continue
    fi
    if [[ -d "$target" && -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then
        echo "  [warn] $path exists and is not empty but has no .git — skipping"
        continue
    fi

    echo "  [clone] $name <- $remote"
    git clone --branch "$branch" "$remote" "$target"
done

echo
echo "=== Creating dev-test symlinks ==="

failed_from=()
failed_target=()

link_count="$(jq '.devTestSymlinks | length' "$manifest")"
for ((i = 0; i < link_count; i++)); do
    from_rel="$(jq -r ".devTestSymlinks[$i].from" "$manifest")"
    to_rel="$(jq -r ".devTestSymlinks[$i].to" "$manifest")"
    link_path="$repo_root/$from_rel"
    target_path="$repo_root/$to_rel"

    if [[ -e "$link_path" || -L "$link_path" ]]; then
        echo "  [skip] $from_rel already exists"
        continue
    fi
    if [[ ! -e "$target_path" ]]; then
        echo "  [warn] target $to_rel does not exist yet — skipping"
        continue
    fi

    mkdir -p "$(dirname "$link_path")"

    if ln -s "$target_path" "$link_path" 2>/dev/null; then
        echo "  [link] $from_rel -> $to_rel"
    else
        echo "  [fail] $from_rel"
        failed_from+=("$link_path")
        failed_target+=("$target_path")
    fi
done

if [[ ${#failed_from[@]} -gt 0 ]]; then
    echo
    echo "[warn] Could not create ${#failed_from[@]} symlink(s) — missing permission."
    echo "       Run these commands manually:"
    echo
    for ((i = 0; i < ${#failed_from[@]}; i++)); do
        echo "  ln -s \"${failed_target[$i]}\" \"${failed_from[$i]}\""
    done
    echo
fi

echo
echo "Done."
