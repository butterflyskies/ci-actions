#!/usr/bin/env bash
# lock-deps.sh — Populate DEPS.lock with tree hashes for all pinned actions.
#
# For each action@sha in DEPS.lock, clones the repo at that exact commit and
# records the tree SHA. This is the immutable content hash — if someone
# force-pushes to rewrite the commit, the tree hash changes.
#
# Usage: ./scripts/lock-deps.sh
# Requires: git, a network connection (clones are shallow + ephemeral).
set -euo pipefail

LOCK_FILE="${1:-DEPS.lock}"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

if [ ! -f "$LOCK_FILE" ]; then
  echo "ERROR: ${LOCK_FILE} not found" >&2
  exit 1
fi

OUTPUT=""

while IFS= read -r line; do
  # Skip comments and blank lines.
  [[ "$line" =~ ^[[:space:]]*# ]] && OUTPUT+="${line}"$'\n' && continue
  [[ -z "${line// }" ]] && OUTPUT+=$'\n' && continue

  # Parse: action@sha old_hash
  action_ref="${line%% *}"
  action="${action_ref%%@*}"
  sha="${action_ref##*@}"

  # Derive the clone URL.
  repo="https://github.com/${action}.git"

  echo "Locking ${action}@${sha}" >&2
  clone_dir="${TEMP_DIR}/${action//\//_}_${sha}"

  # Shallow clone at exact commit. --depth 1 + fetch by sha works on GitHub.
  git init -q "$clone_dir"
  git -C "$clone_dir" fetch --depth 1 "$repo" "$sha" 2>/dev/null
  tree_hash=$(git -C "$clone_dir" rev-parse "${sha}^{tree}")

  OUTPUT+="${action}@${sha} ${tree_hash}"$'\n'
  echo "  -> tree ${tree_hash}" >&2
done < "$LOCK_FILE"

printf '%s' "$OUTPUT" > "$LOCK_FILE"
echo "DEPS.lock updated." >&2
