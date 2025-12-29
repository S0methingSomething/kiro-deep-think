#!/usr/bin/env bash
set -euo pipefail

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
NC=$'\033[0m'

ok() { echo "${GREEN}✓${NC} $*"; }
err() { echo "${RED}✗${NC} $*"; }

AGENT_DIR="$HOME/.kiro/agents"
mkdir -p "$AGENT_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/agent" ]]; then
  cp "$SCRIPT_DIR/agent/"* "$AGENT_DIR/"
  chmod +x "$AGENT_DIR/task-manager.sh" "$AGENT_DIR/task-llm-context.py"
  ok "Installed deep-thinker agent to ~/.kiro/agents/"
  echo "Usage: kiro-cli chat --agent deep-thinker"
else
  err "agent/ directory not found"
  exit 1
fi
