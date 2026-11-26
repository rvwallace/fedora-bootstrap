#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap Fedora workstation/dev environment
# Idempotent: safe to run multiple times

# Config
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
ROOT_DIR="$SCRIPT_DIR"
CONF_FILE="${ROOT_DIR}/config/bootstrap.conf"
PKG_FILE="${ROOT_DIR}/config/packages.conf"

# Defaults (can be overridden in bootstrap.conf)
ENABLE_RUST=${ENABLE_RUST:-false}
ENABLE_FLATPAK=${ENABLE_FLATPAK:-true}
EXTRA_PACKAGES=("${EXTRA_PACKAGES[@]:-}")
INSTALL_DOTFILES=${INSTALL_DOTFILES:-false}
DOTFILES_INSTALL_PATH=${DOTFILES_INSTALL_PATH:-}

log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
warn() { printf "[WARN] %s\n" "$*" >&2; }

parse_args() {
  DRY_RUN=false
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      -h|--help)
        printf 'Usage: %s [--dry-run]\n' "$0"
        exit 0
        ;;
      *)
        warn "Unknown option: $1 (see --help)"
        exit 2
        ;;
    esac
    shift
  done
  readonly DRY_RUN
}

run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

run_sudo() {
  if [[ $EUID -ne 0 ]]; then
    run sudo "$@"
  else
    run "$@"
  fi
}

load_conf() {
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
  fi
}

load_packages() {
  if [[ -f "$PKG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PKG_FILE"
  fi
}

ensure_fedora() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" != fedora ]] || return 0
    warn "This script targets Fedora (detected ${PRETTY_NAME:-${ID:-unknown}})."
  else
    warn "Cannot identify Fedora because /etc/os-release is missing."
  fi
  if [[ "$DRY_RUN" == true ]]; then
    warn "Showing the planned steps for Fedora 43 or newer."
    VERSION_ID=
  else
    exit 1
  fi
}

enable_rpmfusion() {
  local ver
  if [[ "$DRY_RUN" == true ]]; then
    ver=${VERSION_ID:-FEDORA_VERSION}
  else
    ver=$(rpm -E %fedora)
  fi
  local free_pkg="rpmfusion-free-release-${ver}.noarch"
  local nonfree_pkg="rpmfusion-nonfree-release-${ver}.noarch"
  if rpm -q "$free_pkg" "$nonfree_pkg" >/dev/null 2>&1; then
    log "RPM Fusion already enabled"
    return 0
  fi
  log "Enabling RPM Fusion (free + nonfree)"
  run_sudo dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${ver}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${ver}.noarch.rpm"
}

is_container() {
  # Detect if we're running in a container
  [[ -f /.dockerenv || -f /run/.containerenv || -n "${container:-}" ]] ||
    systemd-detect-virt --container --quiet 2>/dev/null
}

enable_flathub() {
  # Skip if disabled in config
  if [[ "$ENABLE_FLATPAK" != true ]]; then
    log "Flatpak disabled (set ENABLE_FLATPAK=true to enable)"
    return 0
  fi

  # Skip Flatpak setup in containers as it typically won't work properly
  if is_container; then
    log "Container environment detected; skipping Flatpak setup"
    return 0
  fi

  # Install flatpak if not present
  if ! command -v flatpak >/dev/null 2>&1; then
    log "Installing flatpak"
    run_sudo dnf install -y flatpak || {
      warn "Failed to install flatpak"
      return 0
    }
  fi

  if [[ "$DRY_RUN" != true ]] && flatpak remote-list --columns=name | grep -x flathub >/dev/null; then
    log "Flathub already enabled"
    return 0
  fi

  log "Enabling Flathub"
  run flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
}

create_local_bin() {
  log "Ensuring ~/.local/bin exists and is in PATH"
  run mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
  # Add to ~/.bash_profile and ~/.zprofile if absent
  local export_line="export PATH=\"\$HOME/.local/bin:\$PATH\""
  local profile
  for profile in "$HOME/.bash_profile" "$HOME/.zprofile"; do
    if ! grep -Fxq "$export_line" "$profile" 2>/dev/null; then
      if [[ "$DRY_RUN" == true ]]; then
        log "Would add $export_line to $profile"
      else
        printf '\n%s\n' "$export_line" >>"$profile"
      fi
    fi
  done
}

install_dev_tools_group() {
  log "Installing development-tools group (if needed)"
  if [[ "$DRY_RUN" != true ]] && dnf group list --installed | grep -i "development tools" >/dev/null; then
    log "development-tools already installed"
    return 0
  fi
  run_sudo dnf group install -y 'development-tools'
}

enable_terra() {
  if [[ -f /etc/yum.repos.d/terra.repo ]] || rpm -q terra-release >/dev/null 2>&1; then
    log "Terra already enabled"
    return 0
  fi
  log "Enabling Terra"
  # DNF expands $releasever in the repository URL.
  # shellcheck disable=SC2016
  run_sudo dnf install -y --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release
}

install_package_list() {
  local label="$1"
  shift
  local package
  local to_install=()
  for package in "$@"; do
    [[ -n "$package" ]] || continue
    [[ "$DRY_RUN" != true ]] && rpm -q --whatprovides "$package" >/dev/null 2>&1 || to_install+=("$package")
  done
  if (("${#to_install[@]}" == 0)); then
    log "All $label packages already installed"
  else
    log "Installing $label packages"
    # Lower priority numbers win. Fedora repositories normally default to 99.
    run_sudo dnf --setopt='terra*.priority=100' --setopt='rpmfusion*.priority=110' \
      install -y --skip-unavailable "${to_install[@]}"
  fi
}

install_packages() {
  local kubectl_package=kubernetes1.37-client
  case "${VERSION_ID:-}" in
    42) kubectl_package=/usr/bin/kubectl ;;
    [0-3][0-9]|4[01]) kubectl_package=kubernetes-client ;;
  esac
  install_package_list Fedora "${DNF_ALL[@]}" "$kubectl_package"
  install_package_list Terra "${DNF_TERRA[@]}"
  if [[ -n "${EXTRA_PACKAGES[*]:-}" ]]; then
    install_package_list extra "${EXTRA_PACKAGES[@]}"
  fi
}

install_rust_and_cargo_tools() {
  [[ "$ENABLE_RUST" == true ]] || {
    log "Rust installation disabled (set ENABLE_RUST=true to enable)"
    return 0
  }

  # Install Rust if not available
  if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust toolchain via rustup"
    if [[ "$DRY_RUN" == true ]]; then
      log "Would download and run the Rust installer from https://sh.rustup.rs"
      return 0
    fi
    if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; then
      warn "Failed to install Rust"
      return 0
    fi
    # shellcheck disable=SC1090
    # shellcheck disable=SC1091
    if [[ -f "$HOME/.cargo/env" ]]; then
      source "$HOME/.cargo/env"
    else
      warn "Rust installed but environment file not found"
      return 0
    fi
  fi
}

setup_helix_config() {
  local hx_dir="$HOME/.config/helix"
  local hx_conf="$hx_dir/config.toml"
  local source_conf="${ROOT_DIR}/files/helix/config.toml"

  if [[ -e "$hx_conf" || -L "$hx_conf" ]]; then
    log "Helix config already exists; leaving as-is"
    return 0
  fi

  if [[ ! -f "$source_conf" ]]; then
    warn "Source helix config not found at $source_conf; skipping"
    return 1
  fi

  log "Installing Helix config from ${source_conf#"$ROOT_DIR"/} to ${hx_conf#"$HOME"/}"
  run mkdir -p "$hx_dir"
  run cp "$source_conf" "$hx_conf"
}

setup_lazyvim() {
  # Only if not already configured
  local nvconf="$HOME/.config/nvim"
  if [[ -d "$nvconf" && -f "$nvconf/init.lua" ]]; then
    log "Neovim config already present; skipping LazyVim clone"
    return 0
  fi
  log "Setting up LazyVim starter"
  if ! run git clone https://github.com/LazyVim/starter "$nvconf"; then
    warn "Failed to setup LazyVim"
    return 0
  fi
  run rm -rf "$nvconf/.git"
}

install_dotfiles_from_path() {
  if [[ "$INSTALL_DOTFILES" != true ]]; then
    log "Dotfiles install disabled"
    return 2
  fi

  if [[ -z "$DOTFILES_INSTALL_PATH" ]]; then
    warn "DOTFILES_INSTALL_PATH not set; skipping dotfiles install"
    return 1
  fi

  if [[ ! -d "$DOTFILES_INSTALL_PATH" ]]; then
    warn "Dotfiles path '$DOTFILES_INSTALL_PATH' not found; skipping dotfiles install"
    return 1
  fi

  local install_script="$DOTFILES_INSTALL_PATH/install.sh"
  if [[ ! -f "$install_script" ]]; then
    warn "Dotfiles install script not found at $install_script; skipping dotfiles install"
    return 1
  fi

  log "Running dotfiles installer from $DOTFILES_INSTALL_PATH"
  if ! (cd "$DOTFILES_INSTALL_PATH" && run bash ./install.sh); then
    warn "Dotfiles installer reported failure"
    return 1
  fi

  return 0
}

change_default_shell_to_zsh() {
  if [[ "${SHELL##*/}" == zsh ]]; then
    log "Default shell already zsh"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "Would set the default shell to zsh after successful setup"
  elif command -v zsh >/dev/null 2>&1; then
    local zsh_path
    zsh_path="$(command -v zsh)"
    log "Changing default shell to $zsh_path"
    run_sudo chsh -s "$zsh_path" "$USER" || warn "Could not change default shell"
  else
    warn "zsh not found; skipping chsh"
  fi
}


main() {
  parse_args "$@"
  ensure_fedora
  load_conf
  load_packages
  create_local_bin
  enable_rpmfusion
  enable_terra
  enable_flathub
  install_dev_tools_group
  install_packages
  setup_helix_config
  install_rust_and_cargo_tools
  setup_lazyvim
  local dotfiles_status
  if install_dotfiles_from_path; then
    dotfiles_status=0
  else
    dotfiles_status=$?
  fi

  if [[ "$dotfiles_status" -eq 0 ]]; then
    change_default_shell_to_zsh
  elif [[ "$dotfiles_status" -eq 2 ]]; then
    log "Default shell left unchanged (dotfiles install skipped)"
  else
    warn "Skipping default shell change because dotfiles install did not run"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "Dry run complete."
  else
    log "Bootstrap complete. You may need to log out and back in."
  fi
}

main "$@"
