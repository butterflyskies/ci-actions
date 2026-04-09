#!/usr/bin/env bash
# verify-deps.sh — Verify that pinned action SHAs still resolve to expected tree hashes.
#
# This catches the exact attack Dan Lorenc described: someone rewrites a git tag
# (or force-pushes a commit) to point at different code. The commit SHA stays the
# same in your workflow file, but the tree it points to has changed.
#
# Wait — can a commit SHA actually point to a different tree? No, not through
# normal git operations. But GitHub Actions resolves refs through the API, and
# a compromised repo could serve different content. More practically, this also
# catches the case where you *think* you pinned a SHA but actually pinned a
# branch or tag ref that later moved.
#
# The deeper value: this creates an auditable record. When you update a pin,
# you must re-run lock-deps.sh and commit the new DEPS.lock. That makes every
# dependency change a visible, reviewable commit.
#
# Usage: ./scripts/verify-deps.sh [DEPS.lock]
# Exit codes:
#   0 — all hashes match
#   1 — mismatch detected (possible supply chain attack or stale lockfile)
#   2 — usage/environment error
set -euo pipefail

LOCK_FILE="${1:-DEPS.lock}"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

if [ ! -f "$LOCK_FILE" ]; then
  echo "::error::${LOCK_FILE} not found"
  exit 2
fi

failures=0
checked=0

while IFS= read -r line; do
  # Skip comments and blank lines.
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue

  # Parse: action@sha expected_tree_hash
  action_ref="${line%% *}"
  expected_hash="${line##* }"
  action="${action_ref%%@*}"
  sha="${action_ref##*@}"

  if [ "$expected_hash" = "TREE_HASH_PLACEHOLDER" ]; then
    echo "::warning::${action}@${sha} has placeholder hash — run scripts/lock-deps.sh"
    continue
  fi

  repo="https://github.com/${action}.git"
  clone_dir="${TEMP_DIR}/${action//\//_}_${sha}"

  echo "Verifying ${action}@${sha}" >&2
  git init -q "$clone_dir"

  if ! git -C "$clone_dir" fetch --depth 1 "$repo" "$sha" 2>/dev/null; then
    echo "::error::Failed to fetch ${action}@${sha} — commit may have been deleted"
    failures=$((failures + 1))
    continue
  fi

  actual_hash=$(git -C "$clone_dir" rev-parse "${sha}^{tree}")
  checked=$((checked + 1))

  if [ "$actual_hash" != "$expected_hash" ]; then
    echo "::error::INTEGRITY FAILURE: ${action}@${sha}"
    echo "  Expected tree: ${expected_hash}"
    echo "  Actual tree:   ${actual_hash}"
    echo "  This may indicate a supply chain attack (tag/commit rewrite)."
    failures=$((failures + 1))
  else
    echo "  ✓ ${action}@${sha}" >&2
  fi
done < "$LOCK_FILE"

echo ""
echo "Checked ${checked} dependencies, ${failures} failure(s)."

if [ "$failures" -gt 0 ]; then
  echo "::error::Dependency integrity check failed. See above for details."
  exit 1
fi
