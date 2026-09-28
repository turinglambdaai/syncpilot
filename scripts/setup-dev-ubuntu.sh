#!/usr/bin/env bash
# One-shot Ubuntu development environment for SyncPilot.
# Covers: Tauri system dependencies, Rust stable, Node 22, rslsync, then
# verifies the whole toolchain by building and testing the repo.
#
# Works on Ubuntu 22.04 / 24.04 (native, VM, or WSL2 with WSLg).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---- 1. Tauri system dependencies -------------------------------------------
say "installing system packages (needs sudo)"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  build-essential curl file pkg-config \
  libwebkit2gtk-4.1-dev \
  libgtk-3-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev

# ---- 2. Rust ----------------------------------------------------------------
if ! command -v cargo >/dev/null 2>&1; then
  say "installing Rust (rustup, stable)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
else
  say "rust present: $(cargo --version)"
fi
rustup component add rustfmt clippy

# ---- 3. Node.js >= 20 -------------------------------------------------------
need_node=1
if command -v node >/dev/null 2>&1; then
  major="$(node --version | sed 's/^v//' | cut -d. -f1)"
  [ "$major" -ge 20 ] && need_node=0
fi
if [ "$need_node" = "1" ]; then
  say "installing Node.js 22 (NodeSource)"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y -qq nodejs
fi
say "node present: $(node --version)"

# ---- 4. rslsync binary ------------------------------------------------------
if command -v rslsync >/dev/null 2>&1 || [ -x "$HOME/.local/bin/rslsync" ]; then
  say "rslsync present: $(command -v rslsync || echo "$HOME/.local/bin/rslsync")"
else
  say "installing rslsync (official binary, pinned checksum)"
  bash "$REPO_DIR/scripts/install-rslsync.sh"
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo 'note: ~/.local/bin is not in PATH; add:  export PATH="$HOME/.local/bin:$PATH"' ;;
esac

# ---- 5. Build + test the repo ----------------------------------------------
say "npm ci + build"
cd "$REPO_DIR"
npm ci --no-audit --no-fund
npm run build

say "cargo test"
(cd src-tauri && cargo test)

say "done. next steps:"
echo "  1. bash scripts/verify-api.sh   # probe the real rslsync API, share the report"
echo "  2. npm run tauri dev            # run the GUI (WSLg window on WSL2)"
