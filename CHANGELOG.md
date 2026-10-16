# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [1.1.1] — 2026-10-17

### Fixed

- Scanning no longer runs Podman for people who have it installed but never used it — `podman
  info` would create Podman's folders in your home, and a scan must change nothing.
- A Conda installed in your home folder (`~/miniconda3`, …) is preferred over one on the `PATH`.

1.1.1 is the first GitHub release with the 1.1.0 features (1.1.0's release build stopped at the
tests).

## [1.1.0] — 2026-10-17

### Cleaning

- **AI Models** — every downloaded Ollama, Hugging Face and LM Studio model is listed on its own
  with its size. They're never pre-selected, automatic cleaning never touches them, and a tick is
  not remembered for the next scan. Ollama models are removed with `ollama rm`.
- **Conda** package cache (`conda clean --all`), **Podman** stopped containers and dangling
  images (`podman system prune`), and **Steam's shader cache**.
- *Stale app caches* no longer removes Hugging Face or LM Studio files from `~/.cache` — models
  are only removed when you pick them.

### Tools

- **Maintenance → Keep fewer snap versions** (`snap set system refresh.retain=2`) and **Limit
  journal size** (a journald drop-in using *Settings → Journal size limit*), so the same junk
  doesn't come back after a clean. Both can be undone from the same menu.
- **System Overview → Space outside your folders:** Timeshift snapshots, the swap file and ext4's
  reserved space — explained, never deleted.
- **Large & Old Files → Virtual machine disks:** VirtualBox, VMware, GNOME Boxes, virt-manager and
  Multipass disk images.
- **Uninstaller, rebuilt:** opens straight to the list of your apps (from their launchers — no
  libraries or drivers), each with its total size (app + its folders in your home) and when you
  last used it (GNOME's record of opened apps, or the newest change in its folders). `s` sorts by
  size, last use or name; `f` shows only apps unused for 90+ days or over 500 MB; `enter` shows
  the details. Parts of Ubuntu itself are hidden. The old search over every package is under `p`.
- **Safer uninstalling:** a removal is refused when apt would also take something Ubuntu needs
  (GNOME Shell, GDM, systemd, sudo, NetworkManager, the running kernel, …), and folders shared by
  several apps are never offered for the Trash.
- **Update everything** first lists what will be updated (apt, snap, flatpak) before asking.
- Flatpak apps now show their size in the Uninstaller.

## [1.0.1] — 2026-10-15

### Packaging

- **PPA** — install with `sudo add-apt-repository ppa:homielab/clean-my-ubuntu`
  and `sudo apt install clean-my-ubuntu`, with updates through Software Updater.
- The snap is now a single build for all architectures.

## [1.0.0] — 2026-10-13

First public release.

### Cleaning

- **Smart Scan** — 50+ locations scanned in parallel in about a second; one checklist with sizes,
  remembered choices, and a confirm dialog that lists exactly what will be removed.
- **System Junk** — APT cache, unused packages, extra old kernels (a fallback always stays),
  leftover configs, old Snap revisions, old temp files.
- **Logs** — systemd journal, rotated and oversized live logs, crash reports, core dumps, old app logs.
- **User & App Junk** — Trash, thumbnails, stale caches, and every browser and app cache as its own choice.
- **AI Tools** — caches, logs and old sessions of Claude Code, Claude Desktop, Codex,
  Gemini/Antigravity, opencode, Zed, Copilot CLI and Continue; memory and logins are never touched.
- **Developer Junk** — npm, Yarn, pnpm, Bun, pip, Go, Cargo, Gradle, Maven, idle `node_modules`,
  and Docker images, build cache, containers and volumes as separate items.
- **Privacy** — shell, Recent files, REPL, Vim, Alt+F2 and emoji history.

### Tools

- Space Lens, Large & Old Files, Duplicates (with **undo** via the Trash), Uninstaller (apt, Snap,
  Flatpak and leftovers), Startup Items, Maintenance, System Overview with free-space history.
- **Automatic cleaning** — daily/weekly/monthly systemd user timer; the notification reports what
  was freed and what's left to review; low-disk alert.

### Apps

- **Desktop app** (Ubuntu 24.04+) — GTK 4 + libadwaita, Smart Scan and the six cleanup sections;
  system items use the standard password dialog.
- **Terminal app** (`cmu`) — keyboard and mouse, `/` find, `z` undo, `?` help, works from 60×20.
- **Command line** — `--scan`, `--clean [--yes]`, `--only`, `--dry-run`, `--auto`, `--json`.

### Install & updates

- `--install` adds `cmu`, the desktop app and a *Show Apps* entry with icon (downloading the app
  files when the script was installed on its own); `--update` and `--uninstall` cover all of it.
- `.deb` package with AppStream metadata and a polkit policy, built by CI for every release.

### Quality

- 27 tests (`tests/run.sh`) in a throwaway home folder, including the terminal UI and a headless
  desktop-app self-test; CI with ShellCheck on Ubuntu 22.04 and 24.04.

[1.1.1]: https://github.com/homielab/clean-my-ubuntu/releases/tag/v1.1.1
[1.1.0]: https://github.com/homielab/clean-my-ubuntu/releases/tag/v1.1.0
[1.0.1]: https://github.com/homielab/clean-my-ubuntu/releases/tag/v1.0.1
[1.0.0]: https://github.com/homielab/clean-my-ubuntu/releases/tag/v1.0.0
