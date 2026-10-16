# Contributing to Clean My Ubuntu

Thanks for helping! This page explains how the project fits together, how to add something new
to clean, and how to check your change. Questions: open an
[issue](https://github.com/homielab/clean-my-ubuntu/issues) or write to contact@homielab.com.

## How it fits together

```
clean-my-ubuntu.sh          the engine + terminal app (one Bash script, the source of truth)
gui/                        the desktop app (Python, GTK 4 + libadwaita) — talks to the engine
data/                       launcher, AppStream metainfo, icon
packaging/                  .deb build script, polkit policy
snap/                       Snap Store draft
tests/                      test suite (run.sh) and the terminal-UI smoke test
docs/                       screenshots, roadmap, publishing guide
```

- **One engine.** Everything that scans or deletes lives in `clean-my-ubuntu.sh`. The desktop app
  never decides what to delete: it runs `clean-my-ubuntu.sh --json …` and reads one JSON event per
  line (`items`, `scan`, `details ID`, `clean ID…`). Both apps share the same rules, tests and
  remembered selections.
- **The registry.** Every cleanable thing is an *item*: `reg ID CATEGORY "Label" DEFAULT "Description"`
  plus three functions — `scan_ID` (how much is there?), `clean_ID` (remove it) and, optionally,
  `details_ID` (what exactly?). Scans run in parallel, one subshell per item.
- **Privileges.** Items that need root are listed in `ITEM_ROOT`. The terminal app uses `sudo`;
  the desktop app uses `pkexec`, and the engine refuses non-system items when it runs as root.

## Adding something to clean

```bash
reg my_cache user "My app cache" 1 "What it is, and why it's safe to remove."
scan_my_cache()    { dev_scan "~/.cache/my-app" "$HOME/.cache/my-app"; }  # sets SCAN_BYTES/SCAN_NOTE
clean_my_cache()   { empty_dir "$HOME/.cache/my-app"; }                    # removes it
details_my_cache() { detail_paths "$HOME/.cache/my-app"; }                 # optional
```

`scan_*` returns 0 when there's something to clean, 2 when it's clean, 1 when it doesn't apply
(the app isn't installed). For a whole family of folders, look at `reg_cache_item` (browsers,
apps), `reg_list_item` (AI tools), `reg_model_item` (one item per downloaded AI model) and
`reg_privacy_item` (histories) — they generate the three
functions for you.

Rules of thumb:

- **Delete only through the helpers** — `run`, `run_root`, `empty_dir`, `move_to_trash` — so
  `--dry-run`, the protected-path checks and the activity log keep working.
- **Prefer the tool's own cleanup command** (`npm cache clean`, `docker image prune`, …).
- **Be conservative.** Personal data starts unselected; anything a running app might use gets a
  `precheck_ID`; history items only remove things older than a limit.
- **Add a test** that creates the files your item should remove *and* the ones it must keep.

## Checking your change

```bash
tests/run.sh               # all tests, ~45 s — safe on your own machine
tests/run.sh -v docker     # only tests with "docker" in the name, with details
shellcheck -S warning clean-my-ubuntu.sh tests/run.sh packaging/build-deb.sh
bash clean-my-ubuntu.sh --dry-run   # try it for real without deleting anything
```

The tests use a throwaway home folder, stub out `sudo`, `pgrep` and `docker`, and fail if your real
`~/.config` or `~/.local/state` folders change. The terminal-UI test needs `pip install pyte`; the
desktop-app test needs `gtk4-broadwayd` (package `libgtk-4-bin`) and runs on an invisible display.
CI runs everything on Ubuntu 22.04 and 24.04 for every pull request.

## Desktop app

```bash
bash clean-my-ubuntu.sh --gui --dry-run     # run it from your clone
```

Pages live in `gui/cmu_gui/scanpage.py`, the window and sidebar in `window.py`, the engine
wrapper in `engine.py`. Keep all deletion logic in the engine.

## Releasing

Bump `VERSION` in `clean-my-ubuntu.sh` and `snap/snapcraft.yaml`, update `CHANGELOG.md` and the
metainfo release notes, merge to `main`, push a `vX.Y.Z` tag — CI tests, builds the `.deb` and
creates the GitHub release with the `.deb` and the snap.
