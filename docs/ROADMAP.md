# Roadmap

Where Clean My Ubuntu is going, and the decisions behind it. Ideas and votes are welcome in
[issues](https://github.com/homielab/clean-my-ubuntu/issues).

## Done in 1.0

- [x] **Engine + terminal app** — Smart Scan over 50+ locations, cleanup sections, Space Lens,
      Large & Old Files, Duplicates, Uninstaller, Startup Items, Maintenance, System Overview,
      Settings, undo, automatic cleaning, updates.
- [x] **Engine protocol** — `clean-my-ubuntu.sh --json items|scan|details|clean`, one JSON event per line.
- [x] **Desktop app core** — Smart Scan and the six cleanup sections, details, confirm dialog,
      live progress; system items through the standard password dialog (pkexec + polkit policy).
- [x] **Distribution** — app icon, *Show Apps* launcher, one-line install, `.deb` built by CI on
      every release, AppStream metainfo.

## Next

- [ ] **Desktop app: file tools** — Space Lens (drill-down list), Large & Old Files, Duplicates,
      each with an *Undo* toast that uses the engine's Trash code.
- [ ] **Desktop app: apps & system** — Uninstaller, Startup Items, Maintenance, System Overview with
      the free-space graph, and a Settings page (automatic cleaning, updates, retention).
- [x] **Launchpad PPA** — `ppa:homielab/clean-my-ubuntu`, uploaded by CI on every release (1.0.1).
- [ ] **Snap Store** — classic confinement was declined for now (project too new); ask again once
      the project has a track record.
- [ ] **Translations** — the UI is English-only today.

Until the desktop app has every tool, its *All tools (terminal)* entry opens `cmu`.

## Design decisions

| Topic | Decision | Why |
|---|---|---|
| Engine | One Bash script (`clean-my-ubuntu.sh`) | Runs everywhere with nothing to install; the terminal app, the desktop app and the timer share every rule and test |
| Desktop app | Python 3 + PyGObject, GTK 4 + libadwaita 1.5 | Preinstalled on Ubuntu 24.04; native GNOME look, dark mode and accent colours for free |
| GUI ↔ engine | JSON lines over a pipe | The GUI never decides what to delete; the engine can be rewritten later without touching the GUI |
| Privileges | GUI runs as you; system items via `pkexec` | Standard password dialog; as root the engine refuses anything in a home folder |
| Older Ubuntu | 22.04 gets the terminal app only | It ships libadwaita 1.1 (no split view, dialogs, toasts) |
| Packaging | `.deb` first, then a PPA | Flathub doesn't accept host system utilities; Snap needs classic confinement |

## Engine protocol

Every line on stdout is one JSON object with an `"event"` field; sizes are bytes.

| Command | Events |
|---|---|
| `--json items` | `item` (`id`, `category`, `label`, `description`, `default`, `root`) …, `done` |
| `--json scan [--only LIST]` | `progress` (`done`, `total`, `current`) …, `item` (+ `status` found/clean/timeout, `bytes`, `note`, `selected`) …, `done` (`ms`, `total_bytes`, `locations`) |
| `--json details ID` | `details` (`id`, `lines`), `done` |
| `--json [--dry-run] clean ID…` | `task` (`id`, `state` run/ok/skip/fail, `info`, `freed`) …, `done` (`freed`, `avail_before`, `avail_after`) |
| any error | `error` (`message`), non-zero exit |
