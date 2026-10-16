#!/usr/bin/env bash
#
# Test suite for clean-my-ubuntu.sh.
#
# Safe to run anywhere: every test uses a throwaway HOME, `sudo` and `pgrep`
# are replaced by stubs (so system items can never run and results don't depend
# on which apps are open), and each cleanup test switches on only the items it
# is testing. Needs no root and no network.
#
# Usage: tests/run.sh [-v] [NAME_FILTER]

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${CMU_SCRIPT:-$ROOT/clean-my-ubuntu.sh} # CMU_SCRIPT: test another copy
WORK=$(mktemp -d -t cmu-tests.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
VERBOSE=0
[[ ${1:-} == -v ]] && { VERBOSE=1; shift; }
FILTER=${1:-}

# stubs: no privilege escalation, no "is the app running?" surprises, and no
# real Docker on the machine leaking into results (the Docker test brings its own)
mkdir -p "$WORK/stubs"
printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/sudo"
printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/pgrep"
printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/docker"
printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/podman" # CI machines ship podman and conda: keep them out too
printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/conda"
chmod +x "$WORK/stubs/"*
# your own ~/… commands (e.g. an installed cmu) must not leak into the tests
BASE_PATH="$WORK/stubs:$(tr ':' '\n' <<<"$PATH" | grep -v "^$HOME/" | grep -vx "$HOME" | paste -sd: -)"

if [[ -t 1 ]]; then G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' D=$'\e[2m' N=$'\e[0m'; else G="" R="" Y="" D="" N=""; fi

# ── helpers ──────────────────────────────────────────────────────────────────

fresh_home() { HOME_DIR=$(mktemp -d -p "$WORK" home.XXXX); mkdir -p "$HOME_DIR/.config/clean-my-ubuntu"; }

cmu() { # run the app non-interactively inside the fake home
  env -i HOME="$HOME_DIR" PATH="$HOME_DIR/.local/bin:$BASE_PATH" LANG=C.UTF-8 TERM=dumb \
    CMU_NO_UPDATE_CHECK=1 ${CMU_UPDATE_URL:+CMU_UPDATE_URL=$CMU_UPDATE_URL} bash "$SCRIPT" "$@"
}

in_app() { # run bash code with the script's functions loaded (sourced, nothing starts)
  env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 bash -c "source \"\$1\"; $1" _ "$SCRIPT"
}

select_only() { # ID... — selection file with exactly these items switched on
  local id w on ids
  ids=$(in_app 'printf "%s\n" "${ITEM_IDS[@]}"')
  for id in $ids; do
    on=0
    for w in "$@"; do [[ $id == "$w" ]] && on=1; done
    echo "$id=$on"
  done >"$HOME_DIR/.config/clean-my-ubuntu/selection"
}

old() { # FILE [DAYS] — create FILE, last modified and read DAYS (default 200) days ago
  mkdir -p "$(dirname "$1")"
  printf 'data\n' >"$1"
  touch -d "${2:-200} days ago" "$1"
  touch -a -d "${2:-200} days ago" "$1"
}
new() { mkdir -p "$(dirname "$1")"; printf 'data\n' >"$1"; }

fail() { printf '    %s✘ %s%s\n' "$R" "$*" "$N"; FAILED=1; }
ok_() { ((VERBOSE)) && printf '    %s✔ %s%s\n' "$D" "$*" "$N"; return 0; }
assert_exists() { if [[ -e $1 || -L $1 ]]; then ok_ "exists: ${1#"$HOME_DIR"/}"; else fail "should exist: ${1#"$HOME_DIR"/}"; fi; }
assert_missing() { if [[ -e $1 || -L $1 ]]; then fail "should be gone: ${1#"$HOME_DIR"/}"; else ok_ "gone: ${1#"$HOME_DIR"/}"; fi; }
assert_eq() { if [[ $1 == "$2" ]]; then ok_ "$3"; else fail "$3: expected '$2', got '$1'"; fi; }
assert_contains() { if [[ $1 == *"$2"* ]]; then ok_ "contains '$2'"; else fail "output should contain '$2'"; ((VERBOSE)) && printf '%s\n' "$1" | sed 's/^/      | /'; fi; }

# ── tests ────────────────────────────────────────────────────────────────────

test_syntax() {
  bash -n "$SCRIPT" && ok_ "bash -n" || fail "syntax error"
}

test_help_and_version() {
  fresh_home
  local v h
  v=$(cmu --version)
  [[ $v =~ ^clean-my-ubuntu\ [0-9]+\.[0-9]+\.[0-9]+$ ]] && ok_ "$v" || fail "bad --version: $v"
  h=$(cmu --help)
  assert_contains "$h" "--install"
  assert_contains "$h" "github.com/homielab/clean-my-ubuntu"
}

test_human_sizes_match_numfmt() {
  fresh_home
  local b mine theirs
  for b in 0 1023 1024 1536 999999 1048576 2000000 1932735283 5368709120 1099511627776; do
    mine=$(in_app "humanv x $b; echo \"\$x\"")
    if ((b < 1024)); then theirs="$b B"
    else theirs=$(numfmt --to=iec --round=nearest --suffix=B --format='%.1f' "$b" | sed 's/\([0-9]\)\([KMGTP]\)/\1 \2/'); fi
    assert_eq "$mine" "$theirs" "human $b"
  done
}

test_plural_and_versions() {
  fresh_home
  assert_eq "$(in_app 'plural 1 file')" "1 file" "plural 1"
  assert_eq "$(in_app 'plural 3 entry')" "3 entries" "plural y→ies"
  assert_eq "$(in_app 'plural 2 day')" "2 days" "plural vowel+y"
  in_app 'version_gt 1.10.0 1.9.0' && ok_ "1.10.0 > 1.9.0" || fail "1.10.0 should be newer than 1.9.0"
  in_app 'version_gt 1.0.0 1.0.0' && fail "1.0.0 is not newer than itself" || ok_ "equal versions"
}

test_protected_paths() {
  fresh_home
  local p
  for p in / /usr /etc /var "$HOME_DIR" "$HOME_DIR/.config" "$HOME_DIR/.local" "$HOME_DIR/.cache/.."; do
    in_app "is_protected '$p'" && ok_ "protected: $p" || fail "should be protected: $p"
  done
  in_app "is_protected '$HOME_DIR/.cache/thing'" && fail "~/.cache/thing should be allowed" || ok_ "allowed: ~/.cache/thing"
}

test_scan_report() {
  fresh_home
  local out
  out=$(cmu --scan 2>&1) || fail "--scan exited with an error"
  assert_contains "$out" "scan report"
  assert_contains "$out" "Found"
}

# Regression: -prune is ignored under -delete; excluded caches must survive.
test_stale_app_cache_keeps_excluded_caches() {
  fresh_home
  local c=$HOME_DIR/.cache
  old "$c/pip/http/old.whl"; old "$c/google-chrome/Default/Cache/old"
  old "$c/someapp/old.bin"; new "$c/someapp/fresh.bin"
  select_only app_cache
  cmu --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_missing "$c/someapp/old.bin"
  assert_exists "$c/someapp/fresh.bin"
  assert_exists "$c/pip/http/old.whl"
  assert_exists "$c/google-chrome/Default/Cache/old"
}

test_trash_is_emptied_in_place() {
  fresh_home
  local t=$HOME_DIR/.local/share/Trash
  mkdir -p "$t/files/folder" "$t/info"
  echo x >"$t/files/a.txt"; echo y >"$t/files/folder/b"
  printf '[Trash Info]\nPath=/x/a.txt\nDeletionDate=2026-01-01T00:00:00\n' >"$t/info/a.txt.trashinfo"
  select_only trash
  cmu --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_eq "$(find "$t/files" "$t/info" -mindepth 1 | wc -l)" 0 "this Trash is empty"
  assert_exists "$t/files"; assert_exists "$t/info"
}

test_browser_items_are_separate() {
  fresh_home
  new "$HOME_DIR/.cache/google-chrome/Default/Cache/a"
  new "$HOME_DIR/.cache/mozilla/firefox/x/cache2/b"
  select_only browser_firefox
  cmu --clean --yes --only browser >/dev/null 2>&1 </dev/null
  assert_missing "$HOME_DIR/.cache/mozilla/firefox/x/cache2/b"
  assert_exists "$HOME_DIR/.cache/google-chrome/Default/Cache/a"
}

test_app_cache_keeps_app_data() {
  fresh_home
  new "$HOME_DIR/.config/Slack/Cache/c"
  new "$HOME_DIR/.config/Slack/Local Storage/login"
  select_only app_slack
  cmu --clean --yes --only apps >/dev/null 2>&1 </dev/null
  assert_missing "$HOME_DIR/.config/Slack/Cache/c"
  assert_exists "$HOME_DIR/.config/Slack/Local Storage/login"
}

test_stale_node_modules_rules() {
  fresh_home
  local d=$HOME_DIR/code p
  for p in idle-with-lock idle-no-lock active; do
    new "$d/$p/node_modules/pkg/index.js"; new "$d/$p/package.json"
  done
  new "$d/idle-with-lock/package-lock.json"; new "$d/active/package-lock.json"
  new "$HOME_DIR/Applications/ide/resources/app/node_modules/x/i.js"
  new "$HOME_DIR/Applications/ide/resources/app/package.json"
  new "$HOME_DIR/Applications/ide/resources/app/package-lock.json"
  for p in "$d/idle-with-lock" "$d/idle-no-lock" "$HOME_DIR/Applications/ide/resources/app"; do
    touch -d '200 days ago' "$p"/* "$p"
  done
  mkdir -p "$WORK/nodebin" && printf '#!/bin/sh\n' >"$WORK/nodebin/node" && chmod +x "$WORK/nodebin/node"
  select_only node_modules
  BASE_PATH="$WORK/nodebin:$BASE_PATH" cmu --clean --yes --only dev >/dev/null 2>&1 </dev/null
  assert_missing "$d/idle-with-lock/node_modules"
  assert_exists "$d/idle-no-lock/node_modules"
  assert_exists "$d/active/node_modules"
  assert_exists "$HOME_DIR/Applications/ide/resources/app/node_modules"
}

test_ai_tools_keep_memory_and_logins() {
  fresh_home
  local P=$HOME_DIR/.claude/projects/-home-x-proj
  old "$P/aaaa-old.jsonl"; old "$P/aaaa-old/tool-results/r1.txt"; touch -d '200 days ago' "$P/aaaa-old"
  new "$P/bbbb-new.jsonl"
  old "$P/memory/MEMORY.md"; touch -d '200 days ago' "$P/memory"
  old "$HOME_DIR/.claude/.credentials.json"; old "$HOME_DIR/.claude/settings.json"
  old "$HOME_DIR/.claude/plugins/p/plugin.json"; old "$HOME_DIR/.claude/cache/c.bin"
  old "$HOME_DIR/.codex/auth.json"; old "$HOME_DIR/.codex/memories_1.sqlite"; old "$HOME_DIR/.codex/.tmp/plugins/x"
  old "$HOME_DIR/.codex/sessions/2026/01/01/old.jsonl"; new "$HOME_DIR/.codex/sessions/2026/10/01/new.jsonl"
  old "$HOME_DIR/.gemini/oauth_creds.json"
  select_only ai_claude_cache ai_claude_history ai_codex_cache ai_codex_history
  cmu --clean --yes --only ai >/dev/null 2>&1 </dev/null
  assert_missing "$P/aaaa-old.jsonl"; assert_missing "$P/aaaa-old"
  assert_missing "$HOME_DIR/.claude/cache/c.bin"; assert_missing "$HOME_DIR/.codex/.tmp/plugins"
  assert_missing "$HOME_DIR/.codex/sessions/2026/01/01/old.jsonl"
  assert_exists "$P/bbbb-new.jsonl"; assert_exists "$P/memory/MEMORY.md"
  assert_exists "$HOME_DIR/.claude/.credentials.json"; assert_exists "$HOME_DIR/.claude/settings.json"
  assert_exists "$HOME_DIR/.claude/plugins/p/plugin.json"
  assert_exists "$HOME_DIR/.codex/auth.json"; assert_exists "$HOME_DIR/.codex/memories_1.sqlite"
  assert_exists "$HOME_DIR/.codex/sessions/2026/10/01/new.jsonl"; assert_exists "$HOME_DIR/.gemini/oauth_creds.json"
}

test_privacy_clears_in_place() {
  fresh_home
  printf 'ls\nssh host\n' >"$HOME_DIR/.bash_history"; chmod 600 "$HOME_DIR/.bash_history"
  printf ': 1:0;git push\n' >"$HOME_DIR/.zsh_history"
  printf '"x\n' >"$HOME_DIR/.viminfo"
  mkdir -p "$HOME_DIR/.local/share"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<xbel version="1.0">' \
    '<bookmark href="file:///secret.pdf"/>' '</xbel>' >"$HOME_DIR/.local/share/recently-used.xbel"
  select_only priv_bash priv_zsh priv_editor priv_recent
  cmu --clean --yes --only privacy >/dev/null 2>&1 </dev/null
  assert_eq "$(stat -c %s "$HOME_DIR/.bash_history")" 0 "bash history emptied"
  assert_eq "$(stat -c %a "$HOME_DIR/.bash_history")" 600 "bash history keeps mode 600"
  assert_eq "$(stat -c %s "$HOME_DIR/.zsh_history")" 0 "zsh history emptied"
  assert_missing "$HOME_DIR/.viminfo"
  if grep -q '<bookmark' "$HOME_DIR/.local/share/recently-used.xbel"; then fail "recent files not cleared"
  else ok_ "recent files cleared"; fi
  grep -q '</xbel>' "$HOME_DIR/.local/share/recently-used.xbel" && ok_ "xbel still valid" || fail "xbel broken"
}

test_old_app_logs() {
  fresh_home
  old "$HOME_DIR/.config/Code/logs/20260101T100000/window1/renderer.log"
  touch -d '200 days ago' "$HOME_DIR/.config/Code/logs/20260101T100000/window1"
  new "$HOME_DIR/.config/Code/logs/20261012T150000/main.log"
  old "$HOME_DIR/.config/Code/User/settings.json"
  select_only app_logs
  cmu --clean --yes --only logs >/dev/null 2>&1 </dev/null
  assert_missing "$HOME_DIR/.config/Code/logs/20260101T100000"
  assert_exists "$HOME_DIR/.config/Code/logs/20261012T150000/main.log"
  assert_exists "$HOME_DIR/.config/Code/User/settings.json"
}

test_dry_run_changes_nothing() {
  fresh_home
  local before after
  old "$HOME_DIR/.cache/someapp/old.bin"; new "$HOME_DIR/.cache/thumbnails/large/a.png"
  new "$HOME_DIR/.cache/pip/x"; new "$HOME_DIR/.cache/google-chrome/c"; new "$HOME_DIR/.config/Slack/Cache/c"
  printf 'secret\n' >"$HOME_DIR/.bash_history"
  old "$HOME_DIR/.claude/cache/c.bin"
  in_app 'printf "%s=1\n" "${ITEM_IDS[@]}"' >"$HOME_DIR/.config/clean-my-ubuntu/selection" # everything on
  # compare every file (size + mtime); the app's own state and GLib's dconf cache don't count
  before=$(cd "$HOME_DIR" && find . \( -path ./.local/state -o -path ./.cache/dconf \) -prune -o -type f -printf '%p %s %T@\n' | sort)
  cmu --clean --yes --dry-run --only user,browser,apps,ai,dev,privacy >/dev/null 2>&1 </dev/null
  after=$(cd "$HOME_DIR" && find . \( -path ./.local/state -o -path ./.cache/dconf \) -prune -o -type f -printf '%p %s %T@\n' | sort)
  assert_eq "$after" "$before" "file tree unchanged by --dry-run"
}

test_install_cmu_and_uninstall() {
  fresh_home
  local out bin=$HOME_DIR/.local/bin
  out=$(cmu --install 2>&1)
  assert_contains "$out" "Shorthand: "
  assert_exists "$bin/clean-my-ubuntu"
  assert_eq "$(readlink "$bin/cmu")" "clean-my-ubuntu" "cmu points to clean-my-ubuntu"
  local desktop=$HOME_DIR/.local/share/applications/com.homielab.CleanMyUbuntu.desktop
  local icon=$HOME_DIR/.local/share/icons/hicolor/scalable/apps/com.homielab.CleanMyUbuntu.svg
  assert_exists "$desktop"
  assert_exists "$icon"
  assert_contains "$(<"$desktop")" "Icon=com.homielab.CleanMyUbuntu"
  if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$desktop" >/dev/null && ok_ "launcher is valid" || fail "invalid launcher: $(desktop-file-validate "$desktop")"
  fi
  assert_eq "$(env -i HOME="$HOME_DIR" PATH="$bin:$BASE_PATH" cmu --version)" "$(cmu --version)" "cmu runs"
  printf 'y\ny\n' | cmu --uninstall >/dev/null 2>&1
  assert_missing "$bin/clean-my-ubuntu"; assert_missing "$bin/cmu"
  assert_missing "$desktop"; assert_missing "$icon"
}

# A script downloaded on its own (the curl install) fetches the desktop app and icon.
test_install_downloads_app_files() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  command -v curl >/dev/null || command -v wget >/dev/null || { SKIPPED="neither curl nor wget installed"; return; }
  fresh_home
  local www=$WORK/bundle lone=$WORK/lone port srv out
  mkdir -p "$www" "$lone"
  tar -czf "$www/main.tar.gz" -C "$ROOT/.." --transform "s,^$(basename "$ROOT"),clean-my-ubuntu-main," \
    "$(basename "$ROOT")/gui" "$(basename "$ROOT")/data"
  cp "$SCRIPT" "$lone/clean-my-ubuntu.sh"
  port=$((20000 + RANDOM % 20000))
  (cd "$www" && exec python3 -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
  srv=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.3; done
  out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 CMU_BUNDLE_URL="http://127.0.0.1:$port/main.tar.gz" \
    bash "$lone/clean-my-ubuntu.sh" --install 2>&1)
  kill "$srv" 2>/dev/null
  assert_contains "$out" "Downloaded the desktop app and icon"
  assert_exists "$HOME_DIR/.local/share/clean-my-ubuntu/gui/cmu-gui"
  assert_exists "$HOME_DIR/.local/share/icons/hicolor/scalable/apps/com.homielab.CleanMyUbuntu.svg"
  # offline: still installs the terminal app
  fresh_home
  out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 CMU_BUNDLE_URL="http://127.0.0.1:9/x.tar.gz" \
    bash "$lone/clean-my-ubuntu.sh" --install 2>&1)
  assert_contains "$out" "Couldn't get the desktop app"
  assert_exists "$HOME_DIR/.local/bin/clean-my-ubuntu"
}

test_install_never_shadows_another_cmu() {
  fresh_home
  local out
  mkdir -p "$WORK/othercmu" && printf '#!/bin/sh\necho other\n' >"$WORK/othercmu/cmu" && chmod +x "$WORK/othercmu/cmu"
  out=$(BASE_PATH="$WORK/othercmu:$BASE_PATH" cmu --install 2>&1)
  assert_contains "$out" "Skipped the"
  assert_missing "$HOME_DIR/.local/bin/cmu"
  assert_contains "$out" "Start it any time with: clean-my-ubuntu"
}

test_update_flow() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  command -v curl >/dev/null || command -v wget >/dev/null || { SKIPPED="neither curl nor wget installed"; return; }
  fresh_home
  local www=$WORK/www port srv out
  mkdir -p "$www"
  sed 's/^VERSION="[0-9.]*"$/VERSION="99.0.0"/' "$SCRIPT" >"$www/new.sh"
  printf '<html>404</html>\n' >"$www/bad.sh"
  port=$((20000 + RANDOM % 20000))
  (cd "$www" && exec python3 -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
  srv=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.3; done
  cmu --install >/dev/null 2>&1

  out=$(CMU_UPDATE_URL="http://127.0.0.1:$port/bad.sh" cmu --update 2>&1 </dev/null)
  assert_contains "$out" "doesn't look like Clean My Ubuntu"
  out=$(CMU_UPDATE_URL="http://127.0.0.1:$port/missing.sh" cmu --update 2>&1 </dev/null)
  assert_contains "$out" "No published version"
  out=$(CMU_UPDATE_URL="http://127.0.0.1:9/x.sh" cmu --update 2>&1 </dev/null)
  assert_contains "$out" "Could not reach"
  out=$(printf 'y\n' | CMU_UPDATE_URL="http://127.0.0.1:$port/new.sh" cmu --update 2>&1)
  assert_contains "$out" "Updated to 99.0.0"
  assert_eq "$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" bash "$HOME_DIR/.local/bin/clean-my-ubuntu" --version)" \
    "clean-my-ubuntu 99.0.0" "installed copy updated"
  assert_eq "$(readlink "$HOME_DIR/.local/bin/cmu")" "clean-my-ubuntu" "cmu link survives the update"
  out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 CMU_UPDATE_URL="http://127.0.0.1:$port/new.sh" \
    bash "$HOME_DIR/.local/bin/clean-my-ubuntu" --update 2>&1 </dev/null)
  assert_contains "$out" "up to date"
  kill "$srv" 2>/dev/null
}

test_trash_and_undo() {
  fresh_home
  local f="$HOME_DIR/Docs/sub dir/Tài liệu 50%.pdf" out info expected
  mkdir -p "$HOME_DIR/Docs/sub dir" "$HOME_DIR/Other" "$HOME_DIR/Docs/folder"
  echo a >"$f"; echo b >"$HOME_DIR/Docs/report.txt"; echo c >"$HOME_DIR/Other/report.txt"; echo d >"$HOME_DIR/Docs/folder/x"
  out=$(in_app '
    for p in "$HOME/Docs/sub dir/Tài liệu 50%.pdf" "$HOME/Docs/report.txt" "$HOME/Other/report.txt" "$HOME/Docs/folder"; do
      move_to_trash "$p" || echo "FAILED $p"
    done
    ls "$TRASH_DIR/files" | LC_ALL=C sort | paste -sd"|" -
    undo_trash; echo "restored=$UNDO_OK failed=$UNDO_FAILED"')
  assert_contains "$out" "Tài liệu 50%.pdf|folder|report.txt|report.txt.2" # same-name files don't collide
  assert_contains "$out" "restored=4 failed=0"
  assert_exists "$f"; assert_exists "$HOME_DIR/Docs/report.txt"; assert_exists "$HOME_DIR/Other/report.txt"
  assert_exists "$HOME_DIR/Docs/folder/x"
  # the .trashinfo must be spec-compliant (percent-encoded path), so GNOME Files can restore it too
  in_app 'move_to_trash "$HOME/Docs/sub dir/Tài liệu 50%.pdf"' >/dev/null
  info=$(sed -n 's/^Path=//p' "$HOME_DIR/.local/share/Trash/info/Tài liệu 50%.pdf.trashinfo")
  if command -v python3 >/dev/null; then
    expected=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/._~-"))' "$f")
    assert_eq "$info" "$expected" "trashinfo Path is percent-encoded like the spec"
  fi
  in_app 'move_to_trash /etc/hostname' >/dev/null 2>&1 && fail "should refuse protected paths" || ok_ "refuses /etc paths"
}

test_kernel_rules_keep_a_fallback() {
  fresh_home
  local r
  r=$(in_app 'printf "6.1\n6.2\n" | kernel_extras 6.2 | paste -sd" " -'); assert_eq "$r" "" "two kernels: keep both"
  r=$(in_app 'printf "6.1\n6.2\n6.3\n" | kernel_extras 6.3 | paste -sd" " -'); assert_eq "$r" "6.1" "keep newest two"
  r=$(in_app 'printf "6.1\n6.2\n6.3\n6.4\n" | kernel_extras 6.1 | paste -sd" " -'); assert_eq "$r" "6.2" "never the running one"
  r=$(in_app 'printf "6.8.0-9\n6.8.0-10\n6.8.0-11\n" | kernel_extras 6.8.0-11 | paste -sd" " -'); assert_eq "$r" "6.8.0-9" "version sort, not text sort"
}

test_docker_items_prune_only_what_is_selected() {
  fresh_home
  local log=$WORK/docker.log out
  : >"$log"
  mkdir -p "$WORK/dockerbin"
  cat >"$WORK/dockerbin/docker" <<EOF
#!/bin/sh
echo "\$*" >>"$log"
case "\$*" in
  info*) exit 0 ;;
  "system df --format"*) printf 'Images\t1.5GB (60%%)\nContainers\t200MB (100%%)\nLocal Volumes\t50MB (10%%)\nBuild Cache\t2GB\n' ;;
  "images -f dangling=true --format {{.Size}}") printf '120MB\n80MB\n' ;;
  "ps -aq"*) printf 'a1\nb2\n' ;;
  "volume ls -qf dangling=true") printf 'v1\n' ;;
esac
EOF
  chmod +x "$WORK/dockerbin/docker"
  out=$(BASE_PATH="$WORK/dockerbin:$BASE_PATH" cmu --scan --only dev 2>&1)
  assert_contains "$out" "Docker: dangling images"
  assert_contains "$out" "2 images"
  assert_contains "$out" "2 containers"
  assert_contains "$out" "1 volume — may contain data"
  select_only docker_dangling docker_build
  BASE_PATH="$WORK/dockerbin:$BASE_PATH" cmu --clean --yes --only dev >/dev/null 2>&1 </dev/null
  out=$(<"$log")
  assert_contains "$out" "image prune -f"
  assert_contains "$out" "builder prune -f"
  [[ $out == *"volume prune"* ]] && fail "volumes must not be pruned unless selected" || ok_ "volumes untouched"
  [[ $out == *"container prune"* ]] && fail "containers must not be pruned unless selected" || ok_ "containers untouched"
  [[ $out == *"image prune -a"* ]] && fail "unused images must not be pruned unless selected" || ok_ "unused images untouched"
}

test_free_space_history() {
  fresh_home
  local out today
  printf -v today '%(%Y-%m-%d)T' -1
  in_app 'record_disk_usage; record_disk_usage' >/dev/null
  assert_eq "$(grep -c "^$today" "$HOME_DIR/.local/state/clean-my-ubuntu/disk-history.tsv")" 1 "one row per day"
  assert_eq "$(in_app 'sparkline s 50 40 45 30 20 25 10; echo "$s"')" "█▆▇▄▂▃▁" "sparkline"
  printf '%s\t%s\t%s\n' 2026-01-01 50000000000 100000000000 2026-01-15 40000000000 100000000000 \
    >"$HOME_DIR/.local/state/clean-my-ubuntu/disk-history.tsv"
  out=$(in_app 'disk_history_lines')
  assert_contains "$out" "Losing about"
  assert_contains "$out" "is full in ~"
}

test_auto_clean_reports_what_is_left() {
  fresh_home
  local log=$WORK/notify.log out
  : >"$log"
  mkdir -p "$WORK/notifybin" "$HOME_DIR/.cache/google-chrome/Default/Cache"
  printf '#!/bin/sh\necho "$*" >>"%s"\n' "$log" >"$WORK/notifybin/notify-send"
  chmod +x "$WORK/notifybin/notify-send"
  head -c 120000000 /dev/zero >"$HOME_DIR/.cache/google-chrome/Default/Cache/big" # 120 MB, never auto-cleaned
  new "$HOME_DIR/.cache/thumbnails/large/a.png"
  out=$(BASE_PATH="$WORK/notifybin:$BASE_PATH" cmu --auto 2>&1 </dev/null)
  assert_missing "$HOME_DIR/.cache/thumbnails/large/a.png" # user junk is cleaned
  assert_exists "$HOME_DIR/.cache/google-chrome/Default/Cache/big" # browsers are only reported
  out=$(<"$log")
  assert_contains "$out" "Worth a look: "
  assert_contains "$out" "Google Chrome"
}

test_json_protocol() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out check
  mkdir -p "$HOME_DIR/.cache/thumbnails/large"; echo x >"$HOME_DIR/.cache/thumbnails/large/a.png"
  check='import sys, json
ev = [json.loads(l) for l in sys.stdin if l.strip()]   # every line must be JSON
kinds = {}
for e in ev: kinds[e["event"]] = kinds.get(e["event"], 0) + 1
print(" ".join(f"{k}={v}" for k, v in sorted(kinds.items())), "last=" + ev[-1]["event"])'
  out=$(cmu --json items | python3 -c "$check" 2>&1); assert_contains "$out" "last=done"
  out=$(cmu --json scan | python3 -c "$check" 2>&1)
  assert_contains "$out" "progress="; assert_contains "$out" "item="; assert_contains "$out" "last=done"
  out=$(cmu --json scan | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e.get("id") == "thumbs": print(e["status"], e["bytes"] > 0, e["selected"], e["root"])')
  assert_eq "$out" "found True True False" "thumbs item in scan"
  out=$(cmu --json details thumbs | python3 -c "$check" 2>&1); assert_contains "$out" "details=1"
  out=$(cmu --json --dry-run clean thumbs 2>&1); assert_contains "$out" '"state":"ok"'
  assert_exists "$HOME_DIR/.cache/thumbnails/large/a.png"
  out=$(cmu --json clean thumbs 2>&1); assert_contains "$out" '"event":"done"'
  assert_missing "$HOME_DIR/.cache/thumbnails/large/a.png"
  out=$(cmu --json clean thumbs nope 2>&1); assert_contains "$out" "Unknown item: nope"
  in_app 'json_allowed journal 0' && ok_ "root may clean system items" || fail "root should clean journal"
  in_app 'json_allowed thumbs 0' && fail "root must not clean home items" || ok_ "root refused for home items"
  in_app 'json_allowed thumbs 1000' && ok_ "user may clean home items" || fail "user should clean thumbs"
}

test_gui_selftest() {
  command -v gtk4-broadwayd >/dev/null || { SKIPPED="gtk4-broadwayd not installed (package libgtk-4-bin)"; return; }
  local py="" c
  for c in python3 /usr/bin/python3; do # a Python with GTK bindings (a virtualenv may come first)
    "$c" -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw; assert (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 5)' 2>/dev/null &&
      { py=$c; break; }
  done
  [[ -n $py ]] || { SKIPPED="GTK 4 + libadwaita 1.5 not available"; return; }
  fresh_home
  local out srv display=$((50 + RANDOM % 40))
  mkdir -p "$HOME_DIR/.cache/thumbnails/large"; echo x >"$HOME_DIR/.cache/thumbnails/large/a.png"
  local rt=$WORK/runtime-$display # the display's socket lives here; shared by server and app
  mkdir -p "$rt" && chmod 700 "$rt"
  XDG_RUNTIME_DIR=$rt gtk4-broadwayd ":$display" >/dev/null 2>&1 &
  srv=$!
  sleep 1
  # a private, invisible display; dry run; the self-test never touches system items
  out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 XDG_RUNTIME_DIR="$rt" \
    GDK_BACKEND=broadway BROADWAY_DISPLAY=":$display" \
    timeout 120 "$py" "$ROOT/gui/cmu-gui" --engine "$SCRIPT" --dry-run --selftest 2>&1)
  kill "$srv" 2>/dev/null
  ((VERBOSE)) && grep SELFTEST <<<"$out" | sed 's/^/      | /'
  assert_contains "$out" "SELFTEST done"
  [[ $out == *"SELFTEST FAIL"* ]] && { fail "GUI self-test reported a failure"; grep 'SELFTEST FAIL' <<<"$out" | sed 's/^/      | /'; }
  assert_contains "$out" "dry-run clean finished"
  assert_exists "$HOME_DIR/.cache/thumbnails/large/a.png" # dry run: nothing deleted
}

test_deb_package() {
  command -v dpkg-deb >/dev/null || { SKIPPED="dpkg-deb not available"; return; }
  fresh_home
  local out=$WORK/dist x=$WORK/debroot deb contents msg
  OUT=$out bash "$ROOT/packaging/build-deb.sh" >/dev/null 2>&1 || { fail "build-deb.sh failed"; return; }
  deb=$(ls "$out"/clean-my-ubuntu_*_all.deb 2>/dev/null)
  [[ -f $deb ]] && ok_ "built $(basename "$deb")" || { fail "no .deb produced"; return; }
  contents=$(dpkg-deb --contents "$deb")
  for f in ./usr/bin/clean-my-ubuntu ./usr/bin/cmu ./usr/share/clean-my-ubuntu/gui/cmu-gui \
    ./usr/share/applications/com.homielab.CleanMyUbuntu.desktop \
    ./usr/share/metainfo/com.homielab.CleanMyUbuntu.metainfo.xml \
    ./usr/share/icons/hicolor/scalable/apps/com.homielab.CleanMyUbuntu.svg \
    ./usr/share/polkit-1/actions/com.homielab.CleanMyUbuntu.policy ./usr/share/doc/clean-my-ubuntu/copyright; do
    assert_contains "$contents" "$f"
  done
  assert_eq "$(head -n 1 <<<"$contents" | cut -c1-10)" "drwxr-xr-x" "package root is 755"
  assert_eq "$(dpkg-deb --field "$deb" Version)" "$(cmu --version | awk '{print $2}')" "package version = script VERSION"
  dpkg-deb -x "$deb" "$x"
  msg=$(env -i HOME="$HOME_DIR" PATH="$x/usr/bin:$BASE_PATH" LANG=C.UTF-8 cmu --install 2>&1)
  assert_contains "$msg" "already installed as a package"
  msg=$(env -i HOME="$HOME_DIR" PATH="$x/usr/bin:$BASE_PATH" LANG=C.UTF-8 cmu --update 2>&1)
  assert_contains "$msg" "sudo apt update"
  if command -v appstreamcli >/dev/null; then
    appstreamcli validate --no-net "$x/usr/share/metainfo/com.homielab.CleanMyUbuntu.metainfo.xml" >/dev/null &&
      ok_ "metainfo valid" || fail "metainfo does not validate"
  fi
}

test_tui_smoke() {
  local out pylib
  # where pyte lives (it may be a --user install, which the throwaway HOME can't see)
  pylib=$(python3 -c 'import os, pyte; print(os.path.dirname(os.path.dirname(pyte.__file__)))' 2>/dev/null) ||
    { SKIPPED="python module pyte not installed"; return; }
  fresh_home
  if out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 PYTHONPATH="$pylib" \
    python3 "$ROOT/tests/tui_smoke.py" "$SCRIPT" 2>&1); then
    ((VERBOSE)) && printf '%s\n' "$out" | sed 's/^/      | /'
  else
    fail "TUI smoke test failed"
    printf '%s\n' "$out" | sed 's/^/      | /'
  fi
  return 0
}

test_ai_models_are_separate_and_never_remembered() {
  fresh_home
  local hub=$HOME_DIR/.cache/huggingface/hub lms=$HOME_DIR/.lmstudio/models out
  old "$hub/models--org--small/blobs/a"; old "$hub/models--org--big/blobs/b"
  old "$hub/datasets--org--data/blobs/c"; old "$lms/pub/llm-7b/model.gguf"
  out=$(cmu --scan --only models 2>&1)
  assert_contains "$out" "Hugging Face — org/small"
  assert_contains "$out" "Hugging Face — org/big"
  assert_contains "$out" "LM Studio — pub/llm-7b"
  [[ $out == *datasets* ]] && fail "datasets are not models" || ok_ "datasets not listed"
  local small lms7
  small=$(in_app 'for i in "${ITEM_IDS[@]}"; do [[ ${ITEM_LABEL[$i]} == "Hugging Face — org/small" ]] && echo "$i"; done')
  lms7=$(in_app 'for i in "${ITEM_IDS[@]}"; do [[ ${ITEM_LABEL[$i]} == "LM Studio — pub/llm-7b" ]] && echo "$i"; done')
  [[ $small == model_hf_org_small_[0-9]* ]] && ok_ "stable id $small" || fail "unexpected id: $small"
  # a remembered tick must not make an unattended clean delete a model
  echo "$small=1" >"$HOME_DIR/.config/clean-my-ubuntu/selection"
  cmu --clean --yes --only models >/dev/null 2>&1 </dev/null
  assert_exists "$hub/models--org--small"
  # the stale-cache cleaner leaves model caches alone too
  select_only app_cache
  cmu --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_exists "$hub/models--org--small/blobs/a"
  # cleaning exactly that model (what the review screen and the desktop app do)
  out=$(cmu --json clean "$small" 2>&1); assert_contains "$out" '"state":"ok"'
  assert_missing "$hub/models--org--small"
  assert_exists "$hub/models--org--big"
  assert_exists "$hub/datasets--org--data"
  out=$(cmu --json clean "$lms7" 2>&1); assert_contains "$out" '"state":"ok"'
  assert_missing "$lms/pub/llm-7b"
  assert_exists "$lms/pub"
  in_app 'model_safe_path "$HOME/.cache/huggingface/hub"' && fail "the hub itself is not a model" || ok_ "hub refused"
  in_app 'model_safe_path "$HOME/.lmstudio/models/pub"' && fail "a publisher folder is not a model" || ok_ "publisher refused"
  # regression: a symlinked "publisher" (models/mine → ~) must never turn home folders into models
  new "$HOME_DIR/Documents/thesis.odt"
  ln -s "$HOME_DIR" "$lms/mine"
  out=$(cmu --scan --only models 2>&1)
  [[ $out == *"mine/"* ]] && fail "home folders listed as models through a symlink" || ok_ "symlinked store ignored"
  in_app 'model_safe_path "$HOME/.lmstudio/models/mine/Documents"' && fail "symlinked path accepted" || ok_ "symlinked path refused"
  assert_exists "$HOME_DIR/Documents/thesis.odt"
}

test_ollama_models_use_ollama_rm() {
  fresh_home
  local log=$WORK/ollama.log out
  : >"$log"
  mkdir -p "$WORK/ollamabin"
  cat >"$WORK/ollamabin/ollama" <<EOF
#!/bin/sh
echo "\$*" >>"$log"
case "\$1" in
  list) printf 'NAME              ID              SIZE      MODIFIED\nllama3.2:latest   a80c4f17acd5    2.0 GB    3 weeks ago\nqwen3:8b          500a1f067a9f    5.2 GB    2 days ago\n' ;;
esac
EOF
  chmod +x "$WORK/ollamabin/ollama"
  out=$(BASE_PATH="$WORK/ollamabin:$BASE_PATH" cmu --scan --only models 2>&1)
  assert_contains "$out" "Ollama — llama3.2:latest"
  assert_contains "$out" "1.9 GB" # ollama says 2.0 GB in SI units; the app shows binary units
  local id
  id=$(BASE_PATH="$WORK/ollamabin:$BASE_PATH" in_app 'for i in "${ITEM_IDS[@]}"; do [[ ${ITEM_LABEL[$i]} == "Ollama — llama3.2:latest" ]] && echo "$i"; done')
  out=$(BASE_PATH="$WORK/ollamabin:$BASE_PATH" cmu --json clean "$id" 2>&1)
  assert_contains "$out" '"state":"ok"'
  assert_contains "$(<"$log")" "rm llama3.2:latest"
  [[ $(<"$log") == *"rm qwen3"* ]] && fail "only the chosen model is removed" || ok_ "other model kept"
}

test_conda_podman_and_steam_items() {
  fresh_home
  local log=$WORK/tools.log out sc=$HOME_DIR/.local/share/Steam/steamapps/shadercache
  : >"$log"
  mkdir -p "$HOME_DIR/miniconda3/bin" "$WORK/podmanbin"
  printf '#!/bin/sh\necho "conda $*" >>"%s"\n' "$log" >"$HOME_DIR/miniconda3/bin/conda"
  old "$HOME_DIR/miniconda3/pkgs/numpy-2.0.conda"
  cat >"$WORK/podmanbin/podman" <<EOF
#!/bin/sh
echo "podman \$*" >>"$log"
case "\$*" in
  info*) exit 0 ;;
  "images -f dangling=true --format {{.Size}}") printf '77.9 MB\n' ;;
  "ps -aq"*) printf 'a1\nb2\n' ;;
esac
EOF
  chmod +x "$HOME_DIR/miniconda3/bin/conda" "$WORK/podmanbin/podman"
  # regression: a scan must not run podman for someone who never used it (it would create its folders)
  BASE_PATH="$WORK/podmanbin:$BASE_PATH" cmu --scan --only dev >/dev/null 2>&1
  [[ $(<"$log") == *"podman info"* ]] && fail "podman asked although never used" || ok_ "unused podman left alone"
  assert_missing "$HOME_DIR/.local/share/containers"
  mkdir -p "$HOME_DIR/.local/share/containers" # podman is only asked once you've used it
  old "$sc/730/fozpipelinesv6/steamapprun_pipeline_cache"
  out=$(BASE_PATH="$WORK/podmanbin:$BASE_PATH" cmu --scan --only dev,apps 2>&1)
  assert_contains "$out" "Conda package cache"
  assert_contains "$out" "1 package archive"
  assert_contains "$out" "1 dangling image, 2 stopped containers"
  assert_contains "$out" "Steam — shader cache"
  select_only conda app_steam_shaders
  BASE_PATH="$WORK/podmanbin:$BASE_PATH" cmu --clean --yes --only dev,apps >/dev/null 2>&1 </dev/null
  assert_contains "$(<"$log")" "conda clean --tarballs --index-cache --logfiles -y"
  [[ $(<"$log") == *"system prune"* ]] && fail "podman must not be pruned unless selected" || ok_ "podman untouched"
  assert_missing "$sc/730"
  assert_exists "$sc"
  select_only podman
  BASE_PATH="$WORK/podmanbin:$BASE_PATH" cmu --clean --yes --only dev >/dev/null 2>&1 </dev/null
  assert_contains "$(<"$log")" "podman system prune -f"
}

test_lasting_limits_and_space_reports() {
  fresh_home
  local out
  out=$(in_app 'JOURNALD_DROPIN=$HOME/j.conf; printf "[Journal]\nSystemMaxUse=150M\n" >"$JOURNALD_DROPIN"; journal_cap')
  assert_eq "$out" "150" "journal limit read back"
  out=$(in_app 'JOURNALD_DROPIN=$HOME/none.conf; journal_cap')
  assert_eq "$out" "" "no limit of ours"
  out=$(in_app 'DRY_RUN=1; JOURNAL_KEEP_MB=120; m_journal_cap; m_snap_retain')
  assert_contains "$out" "SystemMaxUse=%sM"
  assert_contains "$out" "snap set system refresh.retain=2"
  in_app 'hidden_space_lines >/dev/null' && ok_ "space report runs" || fail "hidden_space_lines failed"
  new "$HOME_DIR/VirtualBox VMs/win/win.vdi"; new "$HOME_DIR/vms/ubuntu.QCOW2"; new "$HOME_DIR/iso/ubuntu.img"
  out=$(in_app 'find "$HOME" -type f \( "${VM_DISK_NAMES[@]}" \) -printf "%f\n" | sort | paste -sd" " -')
  assert_eq "$out" "ubuntu.QCOW2 win.vdi" "VM disks found, other images not"
}

test_app_list_shows_real_apps_and_hides_ubuntu() {
  fresh_home
  local bin=$WORK/appbin sys=$HOME_DIR/sys out row
  mkdir -p "$bin" "$sys" "$HOME_DIR/.local/share/applications"
  desk() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n%s\n' "$2" "$3" "${4:-}" >"$1"; }
  desk "$sys/gimp.desktop" "GNU Image Manipulation Program" "gimp-2.10 %U"
  desk "$sys/libreoffice-writer.desktop" "LibreOffice Writer" "libreoffice --writer %U"
  desk "$sys/libreoffice-calc.desktop" "LibreOffice Calc" "libreoffice --calc %U"
  desk "$sys/gnome-control-center.desktop" "Settings" "gnome-control-center"
  desk "$sys/busybox.desktop" "BusyBox" "busybox"
  desk "$sys/helper.desktop" "Helper" "helper" "NoDisplay=true"
  desk "$sys/hidden-by-user.desktop" "Hidden App" "hiddenapp"
  desk "$HOME_DIR/.local/share/applications/hidden-by-user.desktop" "Hidden App" "hiddenapp" "Hidden=true"
  desk "$HOME_DIR/.local/share/applications/my-appimage.desktop" "My AppImage" "/home/x/My.AppImage"
  desk "$sys/com.spotify.Client.desktop" "Spotify" "flatpak run com.spotify.Client" "X-Flatpak=com.spotify.Client"
  desk "$sys/vlc.desktop" "VLC media player" "vlc --started-from-file %U"
  desk "$sys/vlc-settings.desktop" "VLC settings" "vlc --settings" "NoDisplay=true"
  new "$HOME_DIR/.config/vlc/vlcrc"; new "$HOME_DIR/.config/run/state"
  cat >"$bin/dpkg" <<'EOF'
#!/bin/sh
[ "$1" = -S ] || exit 1; shift
for f; do case $f in
  */gimp.desktop) echo "gimp: $f" ;; */libreoffice-writer.desktop) echo "libreoffice-writer: $f" ;;
  */libreoffice-calc.desktop) echo "libreoffice-calc: $f" ;; */gnome-control-center.desktop) echo "gnome-control-center:amd64: $f" ;;
  */busybox.desktop) echo "busybox: $f" ;; */hidden-by-user.desktop) echo "hiddenapp: $f" ;;
  */vlc.desktop) echo "vlc: $f" ;; */vlc-settings.desktop) echo "vlc: $f" ;;
esac; done
EOF
  cat >"$bin/dpkg-query" <<'EOF'
#!/bin/sh
case "$*" in
  *Status-Abbrev*) printf 'ii  ubuntu-desktop-minimal\nii  gimp\n' ;;
  *) printf 'gimp\t20000\toptional\tno\nlibreoffice-writer\t30000\toptional\tno\nlibreoffice-calc\t30000\toptional\tno\ngnome-control-center\t5000\toptional\tno\nbusybox\t900\trequired\tno\nvlc\t8000\toptional\t\n' ;;
esac
EOF
  printf '#!/bin/sh\nprintf "ubuntu-desktop-minimal\\n  Depends: gnome-control-center\\n  Depends: <gdm3>\\n"\n' >"$bin/apt-cache"
  printf '#!/bin/sh\nprintf "com.spotify.Client\\t123.0 MB\\n"\n' >"$bin/flatpak"
  chmod +x "$bin"/*
  old "$HOME_DIR/.config/GIMP/2.10/gimprc"; touch -d "200 days ago" "$HOME_DIR/.config/GIMP/2.10" "$HOME_DIR/.config/GIMP"
  new "$HOME_DIR/.config/libreoffice/4/user/registrymodifications.xcu"
  new "$HOME_DIR/.var/app/com.spotify.Client/cache/x"
  mkdir -p "$HOME_DIR/.local/share/gnome-shell"
  printf '<?xml version="1.0"?>\n<application-state>\n  <context id="">\n    <application id="gimp.desktop" open-window-count="0" score="3" last-seen="%s"/>\n  </context>\n</application-state>\n' \
    "$(( $(date +%s) - 150 * 86400 ))" >"$HOME_DIR/.local/share/gnome-shell/application_state"
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'APP_DESKTOP_DIRS=("$HOME/.local/share/applications" "$HOME/sys"); app_inventory')
  assert_contains "$out" $'#hidden\t2'
  row=$(grep $'^apt\tgimp\t' <<<"$out")
  assert_contains "$row" "GNU Image Manipulation Program"
  assert_contains "$row" "$HOME_DIR/.config/GIMP"
  assert_eq "$(cut -f4 <<<"$row")" "20480000" "gimp package size"
  local seen; seen=$(cut -f6 <<<"$row")
  (( $(date +%s) - seen > 140 * 86400 && $(date +%s) - seen < 160 * 86400 )) && ok_ "last used from GNOME" || fail "gimp last used: $seen"
  row=$(grep $'^apt\tlibreoffice-writer\t' <<<"$out")
  [[ -n $row && $row != *libreoffice/4* && $row != *"/.config/libreoffice"* ]] && ok_ "shared LibreOffice folder not claimed" || fail "writer row: $row"
  row=$(grep $'^flatpak\tcom.spotify.Client\t' <<<"$out")
  assert_eq "$(cut -f4 <<<"$row")" "123000000" "flatpak size"
  assert_contains "$row" "$HOME_DIR/.var/app/com.spotify.Client"
  [[ $row == *"/.config/run"* ]] && fail "flatpak's 'run' must not match ~/.config/run" || ok_ "flatpak run not a name"
  row=$(grep $'^apt\tvlc\t' <<<"$out")
  [[ -n $row && $row != *"/.config/vlc"* ]] && ok_ "folder shared with a hidden launcher not offered" || fail "vlc row: $row"
  for w in gnome-control-center busybox Helper "Hidden App" "My AppImage"; do
    [[ $out == *"$w"* ]] && fail "should not be listed: $w" || ok_ "not listed: $w"
  done
  # filters
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'APP_DESKTOP_DIRS=("$HOME/.local/share/applications" "$HOME/sys"); SESSION_TMP=$HOME
    ui_busy() { wait "$2"; }; load_apps; A_FILTER=unused; apps_view; for i in "${A_VIEW[@]}"; do echo "${A_ID[i]}"; done')
  assert_eq "$out" "gimp" "only gimp is unused for 90+ days"
  assert_eq "$(in_app 'used_ago 0; echo; used_ago $((EPOCHSECONDS - 86400 * 400))')" $'—\n13 months ago' "used_ago"
}

test_uninstall_never_takes_ubuntu_with_it() {
  fresh_home
  local bin=$WORK/aptbin
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase "$*" in *gimp*) printf "Purg gimp [2.10]\\nPurg gimp-data [2.10]\\n" ;; *nautilus*) printf "Purg nautilus [46]\\nPurg gnome-shell [46]\\n" ;; *foo*) printf "Purg foo [1]\\nPurg libsystemd0 [255]\\n" ;; esac\n' >"$bin/apt-get"
  cat >"$bin/dpkg-query" <<'EOF'
#!/bin/sh
for p; do case $p in -*) ;; libsystemd0) echo "libsystemd0 required " ;; *) echo "$p optional " ;; esac; done
EOF
  chmod +x "$bin/apt-get" "$bin/dpkg-query"
  BASE_PATH="$bin:$BASE_PATH" in_app 'toast() { :; }; apt_check_removal gimp && echo "ok $APT_EXTRA_N $APT_EXTRA_TEXT"' | grep -q '^ok 1 gimp-data$' &&
    ok_ "extra package reported" || fail "gimp removal should report gimp-data"
  local out
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'toast() { echo "$1"; }; apt_check_removal nautilus && echo allowed')
  assert_contains "$out" "gnome-shell, which Ubuntu needs"
  [[ $out == *allowed* ]] && fail "gnome-shell must never be removed" || ok_ "removal refused"
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'toast() { echo "$1"; }; apt_check_removal foo && echo allowed')
  assert_contains "$out" "libsystemd0 is marked as required"
  [[ $out == *allowed* ]] && fail "required packages must never go as a side effect" || ok_ "required package kept"
}

test_update_preview_lists_pending_updates() {
  fresh_home
  local bin=$WORK/updbin out
  mkdir -p "$bin"
  printf '#!/bin/sh\nprintf "Listing... Done\\nfirefox/noble-updates 131.0+build1 amd64 [upgradable from: 130.0]\\nlibc6/noble-security 2.39-0ubuntu8.4 amd64 [upgradable from: 2.39-0ubuntu8.3]\\n"\n' >"$bin/apt"
  printf '#!/bin/sh\nprintf "Name     Version  Rev   Size   Publisher  Notes\\nthunderbird  128.3  562  90MB  canonical  -\\n"\n' >"$bin/snap"
  printf '#!/bin/sh\nprintf "org.gimp.GIMP\\t2.10.38\\norg.gnome.Platform\\t\\n"\n' >"$bin/flatpak"
  chmod +x "$bin"/*
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'pending_updates')
  assert_eq "$(grep -c . <<<"$out")" "5" "five pending updates"
  assert_contains "$out" $'apt\tfirefox\t131.0+build1'
  assert_contains "$out" $'snap\tthunderbird\t128.3'
  assert_contains "$out" $'flatpak\torg.gimp.GIMP\t2.10.38'
  assert_contains "$out" $'flatpak\torg.gnome.Platform\tnew build'
}

# ── runner ───────────────────────────────────────────────────────────────────

real_dirs() { # the real user's app folders and Trash — tests must never touch them
  find "$HOME/.config/clean-my-ubuntu" "${XDG_STATE_HOME:-$HOME/.local/state}/clean-my-ubuntu" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/Trash" \
    -printf '%p %s %T@\n' 2>/dev/null | sort
}
REAL_BEFORE=$(real_dirs)

pass=0 failed=0 skipped=0
printf 'Clean My Ubuntu tests — %s\n\n' "$(bash "$SCRIPT" --version)"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  [[ -n $FILTER && $t != *"$FILTER"* ]] && continue
  result=$(
    FAILED="" SKIPPED=""
    "$t"
    if [[ -n $SKIPPED ]]; then echo "@@skip $SKIPPED"
    elif [[ -n $FAILED ]]; then echo "@@fail"
    else echo "@@pass"; fi
  )
  status=$(tail -n 1 <<<"$result")
  name=${t#test_}; name=${name//_/ }
  case $status in
    @@pass) printf '  %s✔%s %s\n' "$G" "$N" "$name"; ((++pass)) ;;
    @@skip*) printf '  %s–%s %s %s(skipped: %s)%s\n' "$Y" "$N" "$name" "$D" "${status#@@skip }" "$N"; ((++skipped)) ;;
    *) printf '  %s✘%s %s\n' "$R" "$N" "$name"; ((++failed)) ;;
  esac
  sed '$d' <<<"$result" | grep -v '^$'
done
if [[ $(real_dirs) != "$REAL_BEFORE" ]]; then
  printf '  %s✘ the tests changed your real ~/.config or ~/.local/state clean-my-ubuntu folder%s\n' "$R" "$N"
  diff <(printf '%s\n' "$REAL_BEFORE") <(real_dirs) | sed 's/^/      | /'
  ((++failed))
fi
printf '\n  %d passed, %d failed, %d skipped\n' "$pass" "$failed" "$skipped"
((failed == 0))
