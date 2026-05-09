#!/bin/bash
# Sync the SOT SKILL.md to all host adapter copies.
# Run this whenever packaging/skill/double-wechat/SKILL.md changes.
# CI should run this and `git diff --exit-code` to catch drift.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOT="$ROOT/packaging/skill/double-wechat/SKILL.md"

[[ -f "$SOT" ]] || { echo "SOT missing: $SOT" >&2; exit 1; }

TARGETS=(
    "$ROOT/packaging/claude-code/skills/double-wechat/SKILL.md"
    "$ROOT/packaging/codex/skills/double-wechat/SKILL.md"
)

for t in "${TARGETS[@]}"; do
    mkdir -p "$(dirname "$t")"
    cp "$SOT" "$t"
    echo "synced: ${t#$ROOT/}"
done
