# Fedora Bootstrap

Set up a DNF-based Fedora workstation, server, or WSL environment. Run the
script as the user whose environment you want to configure. It uses sudo
for system changes and can be rerun.

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
  including `helix`, `lazygit`, `eza`, `zoxide`, `uv`, and `neovim`.
  DNF prefers Fedora packages, then Terra, then RPM Fusion with the default
  repository priorities. The script enables no COPRs and uses no `dra`.
- Copies the bundled Helix configuration if `~/.config/helix/config.toml`
  is absent. It can also install Rust via rustup when enabled.
- Reuses existing `sc-zsh`, `toolbox`, and `tmux-conf` directories under
  `PROJECTS_ROOT`, or clones missing projects from GitHub. It runs
  `bash setup.sh` for sc-zsh, `./bootstrap.sh` then `./toolbox install`
  for toolbox, and `./bootstrap.sh` for tmux-conf. It changes the login
  shell to Zsh only after sc-zsh setup succeeds.
- Sets up LazyVim by default. If `~/.config/lazyvim` is absent, it links an
  existing `$PROJECTS_ROOT/lazyvim` checkout or clones
  `rvwallace/lazyvim` directly into `~/.config/lazyvim`. Launch it with
  `NVIM_APPNAME=lazyvim nvim`. The script leaves `~/.config/nvim` alone.

## Package notes

- Fedora's `unrar` 0.3.3 wraps the libarchive-based `unrar-free`. Check
  whether your archives need RARLab-specific features.
  [Fedora package details](https://packages.fedoraproject.org/pkgs/unrar-free/unrar/)
- Fedora 43 and newer use `kubernetes1.37-client` for `kubectl`. A generic
  RPM provide across supported releases is unverified. Fedora 42 requests
  `/usr/bin/kubectl` through DNF, and older releases request
  `kubernetes-client`.
  [Fedora Kubernetes client builds](https://packages.fedoraproject.org/pkgs/kubernetes1.37/kubernetes1.37-client/)
- Fedora lists the orphaned `tealdeer` package for releases 43 and 44.
  Fedora 45 lacks an official package. DNF uses `--skip-unavailable` so
  missing packages can be skipped.
  [Fedora tealdeer builds](https://packages.fedoraproject.org/pkgs/rust-tealdeer/tealdeer/)

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
