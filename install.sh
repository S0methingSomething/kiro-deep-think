#!/usr/bin/env bash
set -euo pipefail

# Colors
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\033[0;32m'
  RED=$'\033[0;31m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BLUE=''; NC=''
fi

ok() { echo "${GREEN}✓${NC} $*"; }
err() { echo "${RED}✗${NC} $*"; }
warn() { echo "${YELLOW}⚠${NC} $*"; }
info() { echo "${BLUE}$*${NC}"; }

# Header
info "========================================="
info "   Kiro Deep Thinker Agent Installer"
info "========================================="
echo ""

# Check requirements
info "🔍 Checking requirements..."

if ! command -v kiro-cli >/dev/null 2>&1; then
  err "kiro-cli not found. Please install Kiro CLI first:"
  echo "   curl -fsSL https://cli.kiro.dev/install | bash"
  exit 1
fi
ok "Found kiro-cli"

if ! command -v jq >/dev/null 2>&1; then
  warn "jq not found. Task manager will have limited functionality."
  echo "   Install: sudo apt install jq  (or brew install jq on macOS)"
fi

if ! command -v python3 >/dev/null 2>&1; then
  warn "python3 not found. Advanced search features will be unavailable."
fi

# Check authentication
info ""
info "🔐 Checking Kiro authentication..."
if ! kiro-cli settings chat.defaultModel >/dev/null 2>&1; then
  err "Not authenticated with Kiro CLI. Please run:"
  echo "   kiro-cli auth login"
  exit 1
fi
ok "Authenticated with Kiro CLI"

# Install agent
info ""
info "🤖 Installing Deep Thinker Agent..."

AGENT_DIR="$HOME/.kiro/agents"
mkdir -p "$AGENT_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/agent" ]]; then
  # Local installation (from cloned repo)
  cp "$SCRIPT_DIR/agent/deep-thinker.json" "$AGENT_DIR/"
  cp "$SCRIPT_DIR/agent/deep-thinker-prompt.md" "$AGENT_DIR/"
  cp "$SCRIPT_DIR/agent/task-manager.sh" "$AGENT_DIR/"
  cp "$SCRIPT_DIR/agent/task-llm-context.py" "$AGENT_DIR/"

  chmod +x "$AGENT_DIR/task-manager.sh"
  chmod +x "$AGENT_DIR/task-llm-context.py"

  ok "Installed from local files"
else
  # Remote installation (curl | bash)
  REPO_URL="https://raw.githubusercontent.com/S0methingSomething/kiro-deep-think/main/agent"

  download() {
    local file="$1"
    local url="${REPO_URL}/${file}"
    local dest="${AGENT_DIR}/${file}"

    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
      wget -q "$url" -O "$dest"
    else
      err "Neither curl nor wget found. Cannot download files."
      exit 1
    fi
  }

  download "deep-thinker.json"
  download "deep-thinker-prompt.md"
  download "task-manager.sh"
  download "task-llm-context.py"

  chmod +x "$AGENT_DIR/task-manager.sh"
  chmod +x "$AGENT_DIR/task-llm-context.py"

  ok "Downloaded from GitHub"
fi

# Verify installation
info ""
info "✅ Installation complete!"
echo ""
echo "Agent installed to: ${AGENT_DIR}"
echo ""
echo "Usage:"
echo "  kiro-cli chat --agent deep-thinker"
echo ""
echo "Features:"
echo "  • Sequential thinking with branching & revision"
echo "  • Interweaved research and code iteration"
echo "  • Production-ready task manager with full history"
echo "  • BM25 + MMR semantic search"
echo "  • Scales 5-35 thoughts by complexity"
echo ""
echo "Documentation:"
echo "  https://github.com/S0methingSomething/kiro-deep-think"
