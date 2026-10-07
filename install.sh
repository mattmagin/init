#!/usr/bin/env bash
# Quick setup for a new company Mac.
#
#   ./install.sh            # interactive: mise bootstrap confirms before applying
#   ./install.sh --yes      # extra args are passed through to `mise bootstrap`
#
# Steps (each is skipped if already done, so the script is safe to re-run):
#   1. Xcode Command Line Tools
#   2. mise, into ~/.local/bin
#   3. config.toml (next to this script) -> /etc/mise/config.toml
#   4. mise activation in ~/.zshrc
#   5. mise bootstrap: packages, macOS defaults, global runtimes
#
# Written for macOS's stock bash 3.2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="$SCRIPT_DIR/config.toml"
CONFIG_DST="/etc/mise/config.toml"
MISE_BIN="$HOME/.local/bin/mise"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "this script is for macOS only"
[[ $EUID -ne 0 ]] || die "run as your normal user, not root; sudo is requested when needed"
[[ -f "$CONFIG_SRC" ]] || die "config.toml not found next to this script ($CONFIG_SRC)"

# Ask for sudo once up front and keep it alive until the script exits.
log "Requesting administrator access"
sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# --- 1. Xcode Command Line Tools ---------------------------------------------
# Provides git, make and a C compiler; /usr/bin/git is only a stub without them.
install_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    log "Xcode Command Line Tools already installed"
    return
  fi

  log "Installing Xcode Command Line Tools"
  # Headless install via softwareupdate (the same approach as Homebrew's installer).
  local marker="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
  touch "$marker"
  local label
  label="$(softwareupdate -l 2>/dev/null \
    | grep -E '^\s*\* Label: Command Line Tools' \
    | sed -e 's/^ *\* Label: //' \
    | sort -V | tail -n1 || true)"
  if [[ -n "$label" ]]; then
    sudo softwareupdate -i "$label" --verbose
  fi
  rm -f "$marker"

  # Fall back to the GUI installer and wait for it.
  if ! xcode-select -p >/dev/null 2>&1; then
    warn "headless install unavailable; finish the installer dialog that opens"
    xcode-select --install || true
    until xcode-select -p >/dev/null 2>&1; do sleep 5; done
  fi
}

# --- 2. mise -----------------------------------------------------------------
install_mise() {
  if [[ -x "$MISE_BIN" ]]; then
    log "mise already installed ($("$MISE_BIN" --version))"
    log "Updating mise"
    "$MISE_BIN" self-update --yes || warn "mise self-update failed; continuing with installed version"
  else
    log "Installing mise"
    curl -fsSL https://mise.run | sh
  fi
  [[ -x "$MISE_BIN" ]] || die "mise did not install to $MISE_BIN"
  export PATH="$HOME/.local/bin:$PATH"
}

# --- 3. System-wide mise config ----------------------------------------------
install_config() {
  if sudo cmp -s "$CONFIG_SRC" "$CONFIG_DST" 2>/dev/null; then
    log "$CONFIG_DST is up to date"
    return
  fi
  if sudo test -f "$CONFIG_DST"; then
    local backup
    backup="$CONFIG_DST.bak.$(date +%Y%m%d%H%M%S)"
    log "Backing up existing $CONFIG_DST to $backup"
    sudo cp "$CONFIG_DST" "$backup"
  fi
  log "Installing $CONFIG_DST"
  sudo mkdir -p "$(dirname "$CONFIG_DST")"
  sudo install -m 0644 -o root -g wheel "$CONFIG_SRC" "$CONFIG_DST"
}

# --- 4. Shell activation -----------------------------------------------------
# config.toml deliberately has no [bootstrap.mise_shell_activate] (see its
# comments), so activation is added here instead.
activate_shell() {
  local rc="$HOME/.zshrc"
  # shellcheck disable=SC2016  # written literally; expands when .zshrc runs
  local line='eval "$("$HOME/.local/bin/mise" activate zsh)"'
  if [[ -L "$rc" ]]; then
    warn "$rc is a symlink (dotfiles?); not editing it. Make sure it contains:"
    warn "  $line"
    return
  fi
  if [[ -f "$rc" ]] && grep -q 'mise activate' "$rc"; then
    log "mise activation already in $rc"
    return
  fi
  log "Adding mise activation to $rc"
  printf '\n# mise (added by install.sh)\n%s\n' "$line" >> "$rc"
}

# --- 5. Apply the config -----------------------------------------------------
run_bootstrap() {
  log "Running mise bootstrap"
  # Run from $HOME so no project mise.toml in the current directory gets applied.
  (cd "$HOME" && "$MISE_BIN" bootstrap "$@")
}

install_clt
install_mise
install_config
activate_shell
mkdir -p "$HOME/Screenshots"   # target of com.apple.screencapture location
run_bootstrap "$@"

# Restart the apps whose defaults changed so they take effect now.
killall Dock Finder SystemUIServer 2>/dev/null || true

log "Done. Open a new terminal (or run: exec zsh) to pick up mise."
log "Log out and back in for the trackpad settings to apply."
