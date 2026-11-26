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
ENABLE_LAZYVIM=${ENABLE_LAZYVIM:-true}
PROJECTS_ROOT=${PROJECTS_ROOT:-"$HOME/silentcastle/projects"}

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

# Refuse a direct root login. If the script was invoked with sudo, re-exec
# as $SUDO_USER so fonts, dotfiles, and chsh target that account. System
# package installs still go through run_sudo.
resolve_target_user() {
  [[ $EUID -eq 0 ]] || return 0
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) return 0 ;;
    esac
  done
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    log "Running as root; re-executing as $SUDO_USER for user-level setup"
    exec sudo -u "$SUDO_USER" -H -- "$0" "$@"
  fi
  warn "Refusing to run as root. Run ./bootstrap.sh as the user whose environment should be configured; it uses sudo for system packages."
  exit 1
}

# Prefer a zsh path listed in /etc/shells. Fedora's /usr/sbin/zsh is often
# the first hit on PATH but is not a valid chsh target.
resolve_zsh_path() {
  local candidate
  local -a candidates=()
  [[ -x /usr/bin/zsh ]] && candidates+=(/usr/bin/zsh)
  [[ -x /bin/zsh ]] && candidates+=(/bin/zsh)
  if command -v zsh >/dev/null 2>&1; then
    candidates+=("$(command -v zsh)")
  fi
  for candidate in "${candidates[@]}"; do
    if [[ -r /etc/shells ]] && grep -Fxq "$candidate" /etc/shells; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if [[ "${DRY_RUN:-false}" == true && ${#candidates[@]} -gt 0 ]]; then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi
  return 1
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
  if [[ "$DRY_RUN" != true ]] && rpm -q "$free_pkg" "$nonfree_pkg" >/dev/null 2>&1; then
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
  run_sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
}

create_local_bin() {
  log "Ensuring user bin dirs exist and are in PATH"
  local dir
  for dir in "$HOME/.local/bin" "$HOME/go/bin" "$HOME/.bun/bin"; do
    run mkdir -p "$dir"
  done
  export PATH="$HOME/.local/bin:$HOME/go/bin:$HOME/.bun/bin:$PATH"
  # Add to ~/.bash_profile and ~/.zprofile if absent
  local export_line="export PATH=\"\$HOME/.local/bin:\$HOME/go/bin:\$HOME/.bun/bin:\$PATH\""
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
  if [[ -f /etc/yum.repos.d/terra.repo ]] ||
    { [[ "$DRY_RUN" != true ]] && rpm -q terra-release >/dev/null 2>&1; }; then
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
  install_tldr_client
  install_package_list Terra "${DNF_TERRA[@]}"
  if [[ -n "${EXTRA_PACKAGES[*]:-}" ]]; then
    install_package_list extra "${EXTRA_PACKAGES[@]}"
  fi
}

# tealdeer and tldr both provide a tldr command; install only one.
install_tldr_client() {
  if [[ "$DRY_RUN" != true ]] &&
    { rpm -q tealdeer >/dev/null 2>&1 || rpm -q tldr >/dev/null 2>&1 || command -v tldr >/dev/null 2>&1; }; then
    log "tldr client already installed"
    return 0
  fi

  log "Installing tealdeer if available, otherwise tldr"
  local dnf_install=(dnf --setopt='terra*.priority=100' --setopt='rpmfusion*.priority=110' install -y)
  if [[ "$DRY_RUN" == true ]]; then
    printf '[DRY-RUN]'
    printf ' %q' sudo "${dnf_install[@]}" tealdeer
    printf ' ||'
    printf ' %q' sudo "${dnf_install[@]}" tldr
    printf '\n'
    return 0
  fi

  run_sudo "${dnf_install[@]}" tealdeer ||
    run_sudo "${dnf_install[@]}" tldr ||
    warn "Neither tealdeer nor tldr could be installed."
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

ensure_project() {
  local name="$1"
  local project_dir="$PROJECTS_ROOT/$name"
  if [[ -d "$project_dir" ]]; then
    log "Using $project_dir as-is"
    return 0
  fi
  if [[ -e "$project_dir" || -L "$project_dir" ]]; then
    warn "Cannot use $project_dir as a project directory"
    return 1
  fi
  run mkdir -p "$PROJECTS_ROOT" &&
    run git clone "https://github.com/rvwallace/$name.git" "$project_dir"
}

run_in_project() {
  local project_dir="$PROJECTS_ROOT/$1"
  shift
  log "In $project_dir"
  if [[ "$DRY_RUN" == true ]]; then
    run "$@"
  else
    (cd -- "$project_dir" && run "$@")
  fi
}

install_geistmono() {
  if [[ "$DRY_RUN" != true ]] &&
    fc-list -f '%{family}\n' | grep -E '^GeistMono (Nerd Font|NF)([ ,]|$)' >/dev/null; then
    log "GeistMono Nerd Font already installed"
    return 0
  fi

  ensure_project nerd-font-installer &&
    run_in_project nerd-font-installer bash install-nerd-font.sh GeistMono
}

is_lazyvim_config() {
  local dir="$1"
  local resolved="$dir"
  if [[ -L "$dir" ]]; then
    resolved=$(readlink "$dir")
    [[ "$resolved" == /* ]] || resolved="$(dirname -- "$dir")/$resolved"
  fi
  [[ -n "${PROJECTS_ROOT:-}" && "$resolved" == "$PROJECTS_ROOT/lazyvim" ]] && return 0
  if [[ -d "$resolved/.git" ]] && command -v git >/dev/null 2>&1; then
    git -C "$resolved" remote -v 2>/dev/null | grep -Eq 'github.com[/:]rvwallace/lazyvim(\.git)?' && return 0
  fi
  return 1
}

setup_lazyvim() {
  if [[ "$ENABLE_LAZYVIM" != true ]]; then
    log "LazyVim setup disabled"
    return 0
  fi

  local nvim_dir="$HOME/.config/nvim"
  local project_dir="$PROJECTS_ROOT/lazyvim"
  local backup

  if [[ -e "$nvim_dir" || -L "$nvim_dir" ]]; then
    if is_lazyvim_config "$nvim_dir"; then
      log "LazyVim already configured at $nvim_dir"
      return 0
    fi
    backup="${nvim_dir}.bak-$(date +%Y%m%dT%H%M%S)"
    log "Backing up existing Neovim config to $backup"
    run mv "$nvim_dir" "$backup" || return 1
  fi

  run mkdir -p "$HOME/.config" || return 1
  if [[ -d "$project_dir" ]]; then
    [[ "$project_dir" == /* ]] || project_dir="$PWD/$project_dir"
    run ln -s "$project_dir" "$nvim_dir" || return 1
  else
    run git clone https://github.com/rvwallace/lazyvim.git "$nvim_dir" || return 1
  fi
  log "LazyVim is the default Neovim config at $nvim_dir"
}


change_default_shell_to_zsh() {
  local target_user current_shell zsh_path
  target_user="$(id -un)"
  if command -v getent >/dev/null 2>&1; then
    current_shell="$(getent passwd "$target_user" | cut -d: -f7)"
  else
    current_shell="${SHELL:-}"
  fi
  if [[ "${current_shell##*/}" == zsh ]]; then
    log "Default shell already zsh ($current_shell)"
    return 0
  fi
  if ! zsh_path="$(resolve_zsh_path)"; then
    warn "zsh not found or not listed in /etc/shells; skipping chsh"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "Would set the default shell for $target_user to $zsh_path"
    return 0
  fi
  log "Changing default shell for $target_user to $zsh_path"
  run_sudo chsh -s "$zsh_path" "$target_user" || warn "Could not change default shell"
}


main() {
  resolve_target_user "$@"
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
  local setup_failed=false
  local sc_zsh_ready=false
  if ! install_geistmono; then
    warn "GeistMono Nerd Font installation failed."
    setup_failed=true
  fi
  if ensure_project sc-zsh && run_in_project sc-zsh bash setup.sh; then
    sc_zsh_ready=true
  else
    warn "sc-zsh setup failed. Skipping the default shell change."
    setup_failed=true
  fi
  if ! (ensure_project toolbox &&
    run_in_project toolbox ./bootstrap.sh &&
    run_in_project toolbox ./toolbox install); then
    warn "Toolbox setup failed."
    setup_failed=true
  fi
  if ! (ensure_project tmux-conf &&
    run_in_project tmux-conf ./scripts/install-deps.sh --install &&
    run_in_project tmux-conf ./bootstrap.sh); then
    warn "tmux-conf setup failed."
    setup_failed=true
  fi
  if ! setup_lazyvim; then
    warn "LazyVim setup failed."
    setup_failed=true
  fi
  if [[ "$sc_zsh_ready" == true ]]; then
    change_default_shell_to_zsh
  fi
  if [[ "$setup_failed" == true ]]; then
    return 1
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "Dry run complete."
  else
    log "Bootstrap complete. You may need to log out and back in."
  fi
}

main "$@"
