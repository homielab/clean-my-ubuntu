#!/usr/bin/env bash
#
# Regenerate the screenshots in docs/screenshots/ (README, AppStream, stores).
#
#   packaging/make-screenshots.sh
#
# Uses a throwaway demo home folder full of realistic junk, so no personal data
# ends up in a screenshot, and removes it afterwards. The desktop app runs on an
# invisible display (gtk4-broadwayd); the terminal app is rendered by
# packaging/render_terminal.py. Needs: python3-gi with GTK 4 + libadwaita,
# libgtk-4-bin, pyte (pip), Pillow, fonts-ubuntu, fonts-noto-color-emoji.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${OUT:-$ROOT/docs/screenshots}
# The demo home lives inside the project (git-ignored), not in /tmp: the app's
# "Old temporary files" cleaner looks at /tmp and must never see demo files.
mkdir -p "$ROOT/.demo"
DEMO=$(mktemp -d -p "$ROOT/.demo" home.XXXXXX)
STUBS=$DEMO/.stubs
trap 'case $DEMO in "$ROOT"/.demo/home.*) rm -rf "$DEMO" ;; esac; rmdir "$ROOT/.demo" 2>/dev/null || true' EXIT
mkdir -p "$OUT" "$STUBS"

# ── a demo home folder ──
blob() { # PATH MB [DAYS_OLD] — a file that really takes MB on disk
  mkdir -p "$(dirname "$DEMO/$1")"
  fallocate -l "${2}M" "$DEMO/$1" 2>/dev/null || head -c "$((${2} * 1048576))" /dev/zero >"$DEMO/$1"
  if [[ -n ${3:-} ]]; then touch -d "$3 days ago" "$DEMO/$1"; touch -a -d "$3 days ago" "$DEMO/$1"; fi
}
lines() { mkdir -p "$(dirname "$DEMO/$1")"; for ((i = 0; i < $2; i++)); do echo "$3 $i"; done >"$DEMO/$1"; }

blob .cache/google-chrome/Default/Cache/Cache_Data 1450
blob snap/firefox/common/.cache/mozilla/firefox/cache2 640
blob .config/Code/CachedData/1.95/chrome 520
blob .config/Code/Cache/Cache_Data 180
blob .config/Code/logs/20260801T091500/renderer.log 35 40
blob .config/Slack/Cache/Cache_Data 260
blob .config/discord/Cache/Cache_Data 190
blob .cache/thumbnails/large/thumbs 140
blob .local/share/Trash/files/old-backup.tar 900
mkdir -p "$DEMO/.local/share/Trash/info"
printf '[Trash Info]\nPath=%s/old-backup.tar\nDeletionDate=2026-09-01T10:00:00\n' "$DEMO" \
  >"$DEMO/.local/share/Trash/info/old-backup.tar.trashinfo"
blob .cache/someapp/old-data.bin 210 100
blob .npm/_cacache/content-v2/blobs 1100
blob .cache/pip/http/wheels 380
blob .cache/go-build/00/objects 720
blob .cache/yarn/v6/packages 310
blob .cargo/registry/cache/index.crates.io/crates 450
blob code/website/node_modules/.store/packages 480
echo '{}' >"$DEMO/code/website/package.json"; echo '{}' >"$DEMO/code/website/package-lock.json"
touch -d '200 days ago' "$DEMO/code/website/package.json" "$DEMO/code/website/package-lock.json" \
  "$DEMO/code/website/node_modules" "$DEMO/code/website"
blob .claude/cache/models 40
blob .codex/.tmp/plugins/catalog 95
blob .gemini/antigravity-ide/conversations/old-chat.pb 30 60
lines .bash_history 1800 "ls -la"
lines .zsh_history 3400 ": 1700000000:0;git status"
lines .python_history 120 "print"
mkdir -p "$DEMO/.local/share"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<xbel version="1.0">'
  for ((i = 0; i < 64; i++)); do echo "  <bookmark href=\"file:///home/demo/Documents/file$i.pdf\"/>"; done
  echo '</xbel>'
} >"$DEMO/.local/share/recently-used.xbel"

# ── stubs: no password prompts, no "app is running", fixed Docker numbers ──
printf '#!/bin/sh\nexit 1\n' >"$STUBS/sudo"
printf '#!/bin/sh\nexit 1\n' >"$STUBS/pgrep"
printf '#!/bin/sh\n' >"$STUBS/node"
cat >"$STUBS/docker" <<'EOF'
#!/bin/sh
case "$*" in
  info*) exit 0 ;;
  "system df --format"*) printf 'Images\t2.8GB (61%%)\nContainers\t340MB (100%%)\nLocal Volumes\t1.2GB (40%%)\nBuild Cache\t2.1GB\n' ;;
  "images -f dangling=true --format {{.Size}}") printf '450MB\n230MB\n' ;;
  "ps -aq"*) printf 'a1\nb2\nc3\n' ;;
  "volume ls -qf dangling=true") printf 'v1\nv2\n' ;;
esac
EOF
chmod +x "$STUBS"/*
DEMO_PATH="$STUBS:/usr/local/bin:/usr/bin:/bin"

# ── desktop app scenes ──
if command -v gtk4-broadwayd >/dev/null; then
  rt=$DEMO/.runtime
  mkdir -p "$rt" && chmod 700 "$rt"
  XDG_RUNTIME_DIR=$rt gtk4-broadwayd :77 >/dev/null 2>&1 &
  srv=$!
  sleep 1
  n=1
  for scene in results details confirm "done" ai privacy; do
    env -i HOME="$DEMO" PATH="$DEMO_PATH" LANG=C.UTF-8 XDG_RUNTIME_DIR="$rt" GDK_BACKEND=broadway \
      BROADWAY_DISPLAY=:77 CMU_NO_UPDATE_CHECK=1 timeout 180 /usr/bin/python3 "$ROOT/gui/cmu-gui" \
      --engine "$ROOT/clean-my-ubuntu.sh" --screenshot "$OUT/desktop-$n-$scene.png" --scene "$scene" \
      --window-size 1280x800 2>/dev/null | grep -q "screenshot saved" &&
      echo "  desktop-$n-$scene.png" || echo "  ✘ desktop scene '$scene' failed"
    n=$((n + 1))
  done
  kill "$srv"
else
  echo "  (gtk4-broadwayd missing: desktop screenshots skipped)"
fi

# ── terminal app scenes (scan only — nothing is cleaned) ──
term() { # NAME KEYS ROWS
  env -i HOME="$DEMO" PATH="$DEMO_PATH" LANG=C.UTF-8 PYTHONPATH="${PYTHONPATH:-}" \
    /usr/bin/python3 "$ROOT/packaging/render_terminal.py" "$ROOT/clean-my-ubuntu.sh" "$OUT/$1" \
    --keys "$2" --rows "$3" --live --wait 4 >/dev/null && echo "  $1" || echo "  ✘ $1 failed"
}
if /usr/bin/python3 -c 'import pyte, PIL' 2>/dev/null || PYTHONPATH=${PYTHONPATH:-} /usr/bin/python3 -c 'import pyte, PIL' 2>/dev/null; then
  term terminal-1-menu.png "" 34
  term terminal-2-smart-scan.png "1|n" 40
  term terminal-3-ai-tools.png "5" 34
else
  echo "  (pyte or Pillow missing: terminal screenshots skipped — pip install pyte)"
fi
echo "Screenshots in ${OUT/#$ROOT\//}"
