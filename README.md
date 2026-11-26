# Fedora Bootstrap

Set up a DNF-based Fedora workstation, server, or WSL environment. Run the
script as the user whose environment you want to configure. It uses sudo
for system packages and can be rerun. A direct root run is refused. If you
invoke it with `sudo ./bootstrap.sh`, it re-executes as `$SUDO_USER` so
fonts, shell, tmux, and Neovim config land in that account.

## Run it

```bash
git clone https://github.com/rvwallace/fedora-bootstrap.git
cd fedora-bootstrap
./bootstrap.sh --dry-run
./bootstrap.sh
```

Use `--dry-run` to preview the actions without sudo, network installs,
or file writes. On macOS and other non-Fedora hosts it warns and shows the
plan for Fedora 43 or newer. A regular run requires Fedora.

## What it sets up

- Creates `~/.local/bin` and adds it to the login PATH for Bash and Zsh.
- Enables RPM Fusion free and nonfree, then Terra and Flathub. Flatpak and
  Flathub setup is on by default and skipped in containers.
- Installs the `development-tools` group, then the Fedora package list and
  the Terra tools `starship`, `yazi`, and `ouch`. Fedora supplies tools
  including `helix`, `lazygit`, `eza`, `zoxide`, `uv`, `neovim`, and
  `golang`. DNF prefers Fedora packages, then Terra, then RPM Fusion with
  the default repository priorities.
- Copies the bundled Helix configuration if `~/.config/helix/config.toml`
  is absent. It can also install Rust via rustup when enabled.
- Installs GeistMono Nerd Font for the current user if fontconfig does
  not already list it. The script reuses `$PROJECTS_ROOT/nerd-font-installer`
  or clones it and runs `bash install-nerd-font.sh GeistMono`.
- Reuses existing `sc-zsh`, `toolbox`, and `tmux-conf` directories under
  `PROJECTS_ROOT`, or clones missing projects from GitHub. It runs
  `bash setup.sh` for sc-zsh, `./bootstrap.sh` then `./toolbox install`
  for toolbox, and `./scripts/install-deps.sh --install` followed by
  `./bootstrap.sh` for tmux-conf (Go, bun, sesh, and other tmux/toolbox
  dependencies). It changes the login shell to `/usr/bin/zsh` when that
  path is listed in `/etc/shells`, and only after sc-zsh setup succeeds.
- Sets up LazyVim as the default Neovim config at `~/.config/nvim`. If
  that path is not already a LazyVim checkout, the existing directory is
  renamed to `~/.config/nvim.bak-<timestamp>`. The script then links an
  existing `$PROJECTS_ROOT/lazyvim` checkout or clones `rvwallace/lazyvim`
  into `~/.config/nvim`. Launch Neovim with `nvim`; `NVIM_APPNAME` is not
  required.

## Package notes

- Fedora's `unrar` 0.3.3 wraps the libarchive-based `unrar-free`. Check
  whether your archives need RARLab-specific features.
  [Fedora package details](https://packages.fedoraproject.org/pkgs/unrar-free/unrar/)
- Fedora 43 and newer use `kubernetes1.37-client` for `kubectl`. A generic
  RPM provide across supported releases is unverified. Fedora 42 requests
  `/usr/bin/kubectl` through DNF, and older releases request
  `kubernetes-client`.
  [Fedora Kubernetes client builds](https://packages.fedoraproject.org/pkgs/kubernetes1.37/kubernetes1.37-client/)
- The bootstrap prefers the Rust `tealdeer` client when Fedora still
  ships it (releases 43 and 44). Otherwise it installs the Python `tldr`
  package, which Fedora 45 provides. Both supply a `tldr` command, so
  only one is installed.
  [Fedora tealdeer builds](https://packages.fedoraproject.org/pkgs/rust-tealdeer/tealdeer/)
  · [Fedora tldr](https://packages.fedoraproject.org/pkgs/tldr/tldr/)

## Configure

Copy `config/bootstrap.conf.example` to the Git-ignored
`config/bootstrap.conf`. The script sources this file as Bash, so use
trusted local settings.

```bash
ENABLE_FLATPAK=false    # skip Flatpak and Flathub
ENABLE_RUST=true        # install via rustup if cargo is absent (default false)
ENABLE_LAZYVIM=false    # skip LazyVim setup
PROJECTS_ROOT="$HOME/silentcastle/projects"  # default
EXTRA_PACKAGES=(podman virt-manager)
```
