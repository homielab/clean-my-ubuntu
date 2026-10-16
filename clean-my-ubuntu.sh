#!/usr/bin/env bash
#
# clean-my-ubuntu.sh — an interactive system cleaner for Ubuntu,
# inspired by CleanMyMac.
#
# Source, issues and updates: https://github.com/homielab/clean-my-ubuntu
# Copyright (c) 2026 HomieLab (https://homielab.com) — License: MIT
#
#   Smart Scan · System Junk · User & App Junk · Developer Junk · Space Lens
#   Large & Old Files · Duplicates · Uninstaller · Startup Items · Maintenance
#   System Overview · Settings (automatic cleaning via a systemd user timer)
#
# Usage:  ./clean-my-ubuntu.sh [--dry-run] [--scan|--clean [--yes]] [--only LIST] [--auto] [--help]
#         ./clean-my-ubuntu.sh --install      # then just type: cmu
#
# Run it as your normal user; sudo is requested only for system-level tasks.
# Keys: ↑↓/jk move · space select · enter/→ open · q/esc/← back

set -o pipefail
shopt -s extglob

VERSION="1.1.1"
MOUSE=1
DRY_RUN=0
MODE=menu
ASSUME_YES=0
INTERACTIVE=1
SUDO_ASKED=0
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/clean-my-ubuntu"
LOG_FILE="$LOG_DIR/clean.log"

UPDATE_REPO=${CMU_REPO:-homielab/clean-my-ubuntu}
REPO_URL="https://github.com/$UPDATE_REPO"
UPDATE_BRANCH=main
RUN_LOG="$LOG_DIR/last-run.log"

# ───────────────────────────── colors & output ──────────────────────────────

if [[ -t 1 && -z ${NO_COLOR:-} ]] && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' NC=$'\e[0m' REV=$'\e[7m'
  RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' BLUE=$'\e[34m'
  MAGENTA=$'\e[35m' CYAN=$'\e[36m'
  if [[ $(tput colors 2>/dev/null) -ge 256 ]]; then ACCENT=$'\e[38;5;44m'; else ACCENT=$CYAN; fi
else
  BOLD="" DIM="" NC="" REV="" RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" ACCENT=""
fi

info() { printf '  %s•%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '  %s✘%s %s\n' "$RED" "$NC" "$*" >&2; }

log() {
  mkdir -p "$LOG_DIR" 2>/dev/null && printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

repeat() { local s="" i; for ((i = 0; i < $2; i++)); do s+=$1; done; printf '%s' "$s"; }
repeatv() { # VAR CHAR N — like repeat, without a subshell
  local -n __rv=$1
  local i
  __rv=""
  for ((i = 0; i < $3; i++)); do __rv+=$2; done
}

humanv() { # VAR BYTES — "1.8 GB" into VAR, pure bash (no subshell: used while redrawing)
  local -n __hv=$1
  local __b=${2:-0} __i=0 __d=1 __t __u=(B KB MB GB TB PB)
  if ((__b < 1024)); then __hv="$__b B"; return; fi
  while ((__b / __d >= 1024 && __i < 5)); do __d=$((__d * 1024)) __i=$((__i + 1)); done
  __t=$(((__b * 10 + __d / 2) / __d)) # tenths, rounded to nearest
  if ((__t >= 10240 && __i < 5)); then __d=$((__d * 1024)) __i=$((__i + 1)) __t=$(((__b * 10 + __d / 2) / __d)); fi
  __hv="$((__t / 10)).$((__t % 10)) ${__u[__i]}"
}
human() { local __h; humanv __h "$1"; printf '%s' "$__h"; }

size_color() {
  local b=${1:-0}
  if ((b >= 1073741824)); then printf '%s' "$RED"
  elif ((b >= 104857600)); then printf '%s' "$YELLOW"
  elif ((b > 0)); then printf '%s' "$GREEN"
  else printf '%s' "$DIM"; fi
}
size_colorv() { # VAR BYTES
  local b=${2:-0}
  if ((b >= 1073741824)); then printf -v "$1" '%s' "$RED"
  elif ((b >= 104857600)); then printf -v "$1" '%s' "$YELLOW"
  elif ((b > 0)); then printf -v "$1" '%s' "$GREEN"
  else printf -v "$1" '%s' "$DIM"; fi
}

confirm() { # plain-mode yes/no, default No
  ((ASSUME_YES)) && return 0
  local ans; read -rp "  $1 ${DIM}[y/N]${NC} " ans; [[ $ans =~ ^[Yy] ]]
}

# ───────────────────────────── terminal UI toolkit ──────────────────────────
#
# Screens are drawn into FRAME and written in one go on the alternate screen
# (no flicker, autowrap off so long lines are clipped instead of wrapped).
# ui_list is the scrollable list every screen is built on.

UI_ACTIVE=0
UI_RESIZED=0
TERM_DIRTY=1 # re-read the terminal size on the next frame
UI_TOAST=""
TERM_ROWS=24 TERM_COLS=80 UI_W=80
SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
SPIN_I=0

term_size() {
  local s
  s=$(stty size </dev/tty 2>/dev/null) || s="24 80"
  read -r TERM_ROWS TERM_COLS <<<"$s"
  ((TERM_ROWS > 0)) || TERM_ROWS=24
  ((TERM_COLS > 0)) || TERM_COLS=80
  UI_W=$((TERM_COLS > 110 ? 110 : TERM_COLS))
}

ui_start() {
  ((INTERACTIVE)) && [[ -t 0 && -t 1 ]] || return 0
  UI_ACTIVE=1
  printf '\e[?1049h\e[?25l\e[?7l\e[H\e[2J'
  mouse_on
  trap 'UI_RESIZED=1' WINCH # read_key notices this and triggers a redraw
}

# Mouse: wheel scrolls, click focuses (click again = select/open). SGR mode
# (1006) gives exact coordinates; hold Shift to select text as usual.
mouse_on()  { ((UI_ACTIVE && MOUSE)) && printf '\e[?1000h\e[?1006h'; return 0; }
mouse_off() { ((UI_ACTIVE)) && printf '\e[?1000l\e[?1006l'; return 0; }

ui_stop() {
  ((UI_ACTIVE)) || return 0
  printf '\e[?1000l\e[?1006l\e[?7h\e[?25h\e[?1049l'
  UI_ACTIVE=0
}

# Temporarily hand the terminal back for prompts (sudo, text input).
term_raw_on()  { ((UI_ACTIVE)) && { mouse_off; printf '\e[?25h\e[?7h'; }; return 0; }
term_raw_off() { ((UI_ACTIVE)) && { printf '\e[?25l\e[?7l'; mouse_on; }; return 0; }

fl() { FRAME+="$1"$'\e[K\n'; ((++FRAME_N)); }
frame_begin() { ((TERM_DIRTY)) && { term_size; TERM_DIRTY=0; }; FRAME="" FRAME_N=0; }
frame_flush() { printf '\e[H%s\e[J' "${FRAME%$'\n'}"; }

vlen() { # VAR TEXT — visible length (ANSI codes stripped)
  local p=${2//$'\e'\[*([0-9;])m/}
  printf -v "$1" '%d' "${#p}"
}

fitv() { # VAR TEXT WIDTH — truncate with … and pad to exactly WIDTH characters
  local s=$2 w=$3
  ((w <= 0)) && { printf -v "$1" ''; return; }
  ((${#s} > w)) && s="${s:0:w-1}…"
  printf -v "$1" '%s%*s' "$s" $((w - ${#s})) ""
}

mini_bar() { # VAR PERCENT WIDTH
  local f=$(($2 * $3 / 100)) c a b
  ((f > $3)) && f=$3
  if (($2 >= 90)); then c=$RED; elif (($2 >= 75)); then c=$YELLOW; else c=$GREEN; fi
  repeatv a ━ "$f"; repeatv b ━ $(($3 - f))
  printf -v "$1" '%s%s%s%s%s' "$c" "$a" "$DIM" "$b" "$NC"
}

size_bar() { # VAR BYTES MAX WIDTH — proportional bar coloured by size
  local f=0 c a b
  (($3 > 0)) && f=$(($2 * $4 / $3))
  (($2 > 0 && f == 0)) && f=1
  size_colorv c "$2"
  repeatv a ■ "$f"; repeatv b · $(($4 - f))
  printf -v "$1" '%s%s%s%s%s' "$c" "$a" "$DIM" "$b" "$NC"
}

refresh_sysinfo() {
  local size used avail total mavail
  read -r size used avail < <(df -B1 --output=size,used,avail / | tail -n1)
  read -r total mavail < <(free -b | awk '/^Mem:/ {print $2, $7}')
  SYS_DISK_PCT=$((used * 100 / size)) SYS_DISK_FREE=$(human "$avail")
  SYS_MEM_PCT=$(((total - mavail) * 100 / total)) SYS_MEM_FREE=$(human "$mavail")
}

draw_header() { # TITLE
  local db mb rule badge="" where
  ((DRY_RUN)) && badge="  ${MAGENTA}${BOLD}DRY-RUN${NC}"
  if [[ -n $1 ]]; then where="${DIM} › ${NC}${BOLD}$1${NC}" # version and source link on Home only
  elif ((TERM_COLS >= 70)); then where=" ${DIM}v$VERSION · ${REPO_URL#https://}${NC}"
  else where=" ${DIM}v$VERSION${NC}"; fi
  fl " ${ACCENT}${BOLD}🧹 Clean My Ubuntu${NC}$where$badge"
  mini_bar db "$SYS_DISK_PCT" 14; mini_bar mb "$SYS_MEM_PCT" 14
  if ((TERM_COLS >= 78)); then
    fl " ${DIM}Disk${NC} $db ${SYS_DISK_PCT}%${DIM} · $SYS_DISK_FREE free${NC}     ${DIM}RAM${NC} $mb ${SYS_MEM_PCT}%${DIM} · $SYS_MEM_FREE free${NC}"
  else
    fl " ${DIM}Disk${NC} $db ${SYS_DISK_PCT}%${DIM} · $SYS_DISK_FREE free${NC}"
  fi
  repeatv rule ─ $((UI_W - 2)); fl " ${DIM}$rule${NC}"
}

hints() { # KEY LABEL ... → HINTS (a key starting with ! is the primary action)
  set -- "$@" "?" help
  local k l s="" plen=0 piece max=$((TERM_COLS - 8))
  while (($# >= 2)); do
    k=$1 l=$2; shift 2
    if [[ $k == !* ]]; then piece="${GREEN}${BOLD}${k#!}${NC} ${BOLD}$l${NC}"; k=${k#!}
    else piece="${ACCENT}$k${NC} ${DIM}$l${NC}"; fi
    ((plen + ${#k} + ${#l} + 4 > max)) && break
    s+="$piece   "; plen=$((plen + ${#k} + ${#l} + 4))
  done
  HINTS=$s
}

draw_footer() { # HINTS — pads the frame so the footer sits at the bottom
  local pad=$((TERM_ROWS - FRAME_N - 3)) rule
  for ((; pad > 0; pad--)); do fl ""; done
  if [[ -n $UI_TOAST ]]; then fl " $UI_TOAST"; UI_TOAST=""; else fl ""; fi
  repeatv rule ─ $((UI_W - 2)); fl " ${DIM}$rule${NC}"
  fl " $1"
}

toast() { UI_TOAST=$1; }

# read_key [TIMEOUT] → KEY: up down left right pgup pgdn home end enter space tab
# esc backspace resize wheelup wheeldown click (MOUSE_X/MOUSE_Y) <char>.
# With TIMEOUT it returns 1 when no key arrived (used by busy screens, so that
# keys and mouse sequences are consumed whole and never leak into later screens).
read_key() {
  local k rest c seq
  if [[ -n ${1:-} ]]; then
    IFS= read -rsn1 -t "$1" k || return 1
  else
    until IFS= read -rsn1 -t 0.25 k; do
      (($? > 128)) || { KEY=q; sleep 0.1; return 0; } # EOF: back out instead of spinning
      if ((UI_RESIZED)); then UI_RESIZED=0 TERM_DIRTY=1; KEY=resize; return 0; fi
    done
  fi
  case $k in
    $'\e')
      IFS= read -rsn2 -t 0.02 rest
      case $rest in
        '[<') # SGR mouse report: ESC [ < button ; x ; y (M = press, m = release)
          seq=""
          while IFS= read -rsn1 -t 0.02 c && [[ $c != [Mm] ]]; do seq+=$c; done
          IFS=';' read -r MOUSE_B _ MOUSE_Y <<<"$seq" # only the row matters
          case $MOUSE_B in
            64) KEY=wheelup ;;
            65) KEY=wheeldown ;;
            0) if [[ $c == M ]]; then KEY=click; else KEY=other; fi ;;
            *) KEY=other ;;
          esac ;;
        '[A' | OA) KEY=up ;; '[B' | OB) KEY=down ;;
        '[C' | OC) KEY=right ;; '[D' | OD) KEY=left ;;
        '[H' | OH) KEY=home ;; '[F' | OF) KEY=end ;;
        '[5') read -rsn1 -t 0.02; KEY=pgup ;;
        '[6') read -rsn1 -t 0.02; KEY=pgdn ;;
        '') KEY=esc ;;
        *) read -rsn6 -t 0.02; KEY=other ;;
      esac ;;
    '') KEY=enter ;;
    ' ') KEY=space ;;
    $'\t') KEY=tab ;;
    $'\x7f' | $'\b') KEY=backspace ;;
    k) KEY=up ;;
    j) KEY=down ;;
    *) KEY=${k,,} ;;
  esac
  return 0
}

# ── ui_list ──
# Caller sets:
#   L_TITLE, L_HINTS            breadcrumb title and footer hints
#   L_COUNT                     number of rows
#   L_ROW fn IDX FOCUSED        appends one row with fl
#   L_FOCUSABLE fn IDX          (optional) succeeds if the row can take focus
#   L_TOP / L_BOTTOM fn         (optional) content above / below the list
#   L_VIEW=1                    read-only viewer: arrows scroll, no cursor
#   L_CUR, L_SCROLL             position, kept between calls
# Returns with KEY set to the first key it does not handle itself.
L_CUR=0 L_SCROLL=0 L_VIEW=0 L_TOP="" L_BOTTOM="" L_FOCUSABLE=""

list_focusable() { [[ -z $L_FOCUSABLE ]] || "$L_FOCUSABLE" "$1"; }

list_move() { # DELTA — move focus, skipping rows that can't take it
  ((L_COUNT > 0)) || return 0
  local step=1 t=$((L_CUR + $1)) c
  (($1 < 0)) && step=-1
  ((t < 0)) && t=0
  ((t >= L_COUNT)) && t=$((L_COUNT - 1))
  c=$t
  while ((c >= 0 && c < L_COUNT)) && ! list_focusable "$c"; do c=$((c + step)); done
  if ((c < 0 || c >= L_COUNT)); then
    c=$t
    while ((c >= 0 && c < L_COUNT)) && ! list_focusable "$c"; do c=$((c - step)); done
  fi
  ((c >= 0 && c < L_COUNT)) && L_CUR=$c
  return 0
}

input_pending() { read -t 0 2>/dev/null; } # a key is already waiting

list_click() { # a click on row MOUSE_Y: focus it; on the focused row → KEY=L_CLICK_KEY (return 1)
  local idx=$((L_SCROLL + MOUSE_Y - L_ROW0))
  ((L_VIEW == 0 && MOUSE_Y >= L_ROW0 && idx >= 0 && idx < L_COUNT && idx < L_SCROLL + L_VIS)) || return 0
  list_focusable "$idx" || return 0
  if ((idx == L_CUR)); then KEY=${L_CLICK_KEY:-space}; return 1; fi
  L_CUR=$idx
  return 0
}

list_find() { # / — jump to the next row whose text contains the query (Enter on / repeats it)
  local q i j
  if [[ -z ${L_TEXT:-} ]]; then toast "${YELLOW}!${NC} Nothing to search on this screen."; return 0; fi
  ui_input "Find:" "${L_FIND:-}" || return 0
  L_FIND=$REPLY_TEXT q=${REPLY_TEXT,,}
  for ((j = 1; j <= L_COUNT; j++)); do
    i=$(((L_CUR + j) % L_COUNT))
    list_focusable "$i" || continue
    TEXT=""
    "$L_TEXT" "$i"
    if [[ ${TEXT,,} == *"$q"* ]]; then
      L_CUR=$i
      toast "${ACCENT}/${NC} “$L_FIND” — press / and Enter for the next match"
      return 0
    fi
  done
  toast "${YELLOW}!${NC} No match for “$L_FIND”."
}

list_key() { # handle navigation keys; returns 1 when the caller must handle KEY
  if ((L_VIEW)); then
    case $KEY in
      up) ((L_SCROLL > 0)) && ((L_SCROLL--)) ;;
      down) ((L_SCROLL++)) ;;
      wheelup) L_SCROLL=$((L_SCROLL > 3 ? L_SCROLL - 3 : 0)) ;;
      wheeldown) L_SCROLL=$((L_SCROLL + 3)) ;;
      pgup) L_SCROLL=$((L_SCROLL - L_VIS)) ;;
      pgdn | space) L_SCROLL=$((L_SCROLL + L_VIS)) ;;
      home) L_SCROLL=0 ;;
      end) L_SCROLL=$L_COUNT ;;
      resize | other | click) ;;
      '?') [[ $L_TITLE == Help ]] || show_help ;;
      *) return 1 ;;
    esac
  else
    case $KEY in
      up | wheelup) list_move -1 ;;
      down | wheeldown) list_move 1 ;;
      pgup) list_move "-$L_VIS" ;;
      pgdn) list_move "$L_VIS" ;;
      home) L_CUR=0; list_move 0 ;;
      end) L_CUR=$((L_COUNT - 1)); list_move 0 ;;
      click) list_click || return 1 ;;
      resize | other) ;;
      '?') show_help ;;
      /) list_find ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

ui_list() {
  local top_n bottom bottom_n vis i saved saved_n pos
  L_VIS=${L_VIS:-10} L_ROW0=${L_ROW0:-5}
  while :; do
    if input_pending; then # catch up with typed-ahead keys first, draw once at the end
      read_key
      list_key || return 0
      continue
    fi
    frame_begin
    draw_header "$L_TITLE"
    [[ -n $L_TOP ]] && "$L_TOP"
    top_n=$FRAME_N
    saved=$FRAME saved_n=$FRAME_N FRAME="" FRAME_N=0
    [[ -n $L_BOTTOM ]] && "$L_BOTTOM"
    bottom=$FRAME bottom_n=$FRAME_N FRAME=$saved FRAME_N=$saved_n

    vis=$((TERM_ROWS - top_n - bottom_n - 3))
    ((vis < 1)) && vis=1
    L_VIS=$vis L_ROW0=$((top_n + 1))
    if ((L_VIEW)); then
      ((L_SCROLL > L_COUNT - vis)) && L_SCROLL=$((L_COUNT - vis))
      ((L_SCROLL < 0)) && L_SCROLL=0
    else
      ((L_CUR >= L_COUNT)) && L_CUR=$((L_COUNT - 1))
      ((L_CUR < 0)) && L_CUR=0
      list_focusable "$L_CUR" || list_move 0
      ((L_CUR < L_SCROLL)) && L_SCROLL=$L_CUR
      ((L_CUR >= L_SCROLL + vis)) && L_SCROLL=$((L_CUR - vis + 1))
      # keep a header row visible when the first item is focused
      ((L_SCROLL > 0 && L_CUR - L_SCROLL < 2 && L_SCROLL <= 2)) && ! list_focusable 0 && L_SCROLL=0
    fi

    for ((i = L_SCROLL; i < L_COUNT && i < L_SCROLL + vis; i++)); do
      "$L_ROW" "$i" $((!L_VIEW && i == L_CUR))
    done
    FRAME+=$bottom FRAME_N=$((FRAME_N + bottom_n))
    pos=""
    if ((L_COUNT > vis)); then
      if ((L_VIEW)); then pos="${DIM}$((L_SCROLL + 1))–$((L_SCROLL + vis > L_COUNT ? L_COUNT : L_SCROLL + vis))/$L_COUNT${NC}   "
      else pos="${DIM}$((L_CUR + 1))/$L_COUNT${NC}   "; fi
    fi
    draw_footer "$pos$L_HINTS"
    frame_flush

    read_key
    list_key || return 0
  done
}

show_help() { # key reference over the current screen; restores the screen's state
  local t=$L_TITLE tp=$L_TOP bt=$L_BOTTOM rw=$L_ROW fc=$L_FOCUSABLE vw=$L_VIEW n=$L_COUNT \
    cu=$L_CUR sc=$L_SCROLL hn=$L_HINTS ck=${L_CLICK_KEY:-} saved_lines=("${V_LINES[@]}")
  V_LINES=("" "  ${BOLD}Moving around${NC}"
    "    ${ACCENT}↑ ↓${NC}  or  ${ACCENT}j k${NC}         move"
    "    ${ACCENT}PgUp PgDn Home End${NC}  jump"
    "    ${ACCENT}mouse wheel${NC}         scroll"
    "    ${ACCENT}click${NC}               focus a row · click it again to select / open"
    "    ${ACCENT}/${NC}                   find a row by name (/ then Enter finds the next one)"
    "" "  ${BOLD}Choosing${NC}"
    "    ${ACCENT}space${NC}               select or deselect (on a group header: the whole group)"
    "    ${ACCENT}enter  →${NC}            open · show details"
    "    ${ACCENT}a  n${NC}                select all / none"
    "    ${ACCENT}h${NC}                   show or hide items that are already clean"
    "    ${ACCENT}z${NC}                   undo: put back what you just moved to the Trash"
    "" "  ${BOLD}Leaving${NC}"
    "    ${ACCENT}q  esc  ←${NC}           back"
    "    ${ACCENT}ctrl+c${NC}              quit at once"
    "" "  ${BOLD}On this screen${NC}" "    $hn"
    "" "  ${BOLD}Good to know${NC}"
    "    ${DIM}Nothing is deleted until you confirm. Try everything safely with --dry-run.${NC}"
    "    ${DIM}The mouse is captured while the app runs — hold Shift to select text.${NC}"
    "    ${DIM}Activity log: ${LOG_FILE/#$HOME/\~}${NC}"
    "" "  ${BOLD}About${NC}"
    "    Clean My Ubuntu $VERSION · MIT license"
    "    Source code:  ${ACCENT}$REPO_URL${NC}"
    "    Report a bug: ${ACCENT}$REPO_URL/issues${NC}")
  ui_view "Help"
  L_TITLE=$t L_TOP=$tp L_BOTTOM=$bt L_ROW=$rw L_FOCUSABLE=$fc L_VIEW=$vw L_COUNT=$n L_CUR=$cu L_SCROLL=$sc
  L_HINTS=$hn L_CLICK_KEY=$ck V_LINES=("${saved_lines[@]}")
  KEY=resize
}

# ── menus ──
# M_KEY / M_LABEL / M_DESC arrays (an empty label is a spacer row), and
# optionally M_BADGE (right-aligned, consumed by the next ui_menu call).
declare -A MENU_POS=()
declare -a M_BADGE=() MENU_BADGE=()

menu_text() { TEXT=${M_LABEL[$1]}; }
menu_focusable() { [[ -n ${M_LABEL[$1]} && ${M_KEY[$1]} != "#" ]]; }

menu_row() {
  local i=$1 label desc badge="" bw=0 plain
  [[ -n ${M_LABEL[i]} ]] || { fl ""; return; }
  if [[ ${M_KEY[i]} == "#" ]]; then fl "   ${BLUE}${BOLD}${M_LABEL[i]^^}${NC}"; return; fi # section header (one row)
  if [[ -n ${MENU_BADGE[i]:-} ]] && ((UI_W >= 90)); then
    bw=20
    vlen plain "${MENU_BADGE[i]}"
    printf -v badge '%*s%s' $((bw - plain)) "" "${MENU_BADGE[i]}"
  fi
  fitv label "${M_LABEL[i]}" 24
  fitv desc "${M_DESC[i]}" $((UI_W - 36 - bw))
  if (($2)); then fl "  ${ACCENT}${BOLD}▸ ${M_KEY[i]:- }  $label${NC}  $desc$badge"
  else fl "    ${DIM}${M_KEY[i]:- }${NC}  $label  ${DIM}$desc${NC}$badge"; fi
}

ui_menu() { # TITLE [TOP_FN] → MENU_IDX; returns 1 when the user goes back
  local title=$1 i
  local bi
  MENU_BADGE=()
  for bi in "${!M_BADGE[@]}"; do MENU_BADGE[bi]=${M_BADGE[bi]}; done # keep the indices
  M_BADGE=() # badges are opt-in per call
  L_TITLE=${title#Home} L_TOP=${2:-} L_BOTTOM="" L_ROW=menu_row L_FOCUSABLE=menu_focusable L_TEXT=menu_text
  L_VIEW=0 L_COUNT=${#M_LABEL[@]} L_CUR=${MENU_POS[$title]:-0} L_SCROLL=0
  hints "↑↓" move "enter" open "q" back
  L_HINTS=$HINTS
  while :; do
    L_CLICK_KEY=enter
    ui_list
    L_CLICK_KEY=""
    MENU_POS[$title]=$L_CUR
    case $KEY in
      enter | right | space) MENU_IDX=$L_CUR; return 0 ;;
      q | esc | left | backspace) return 1 ;;
      *)
        for i in "${!M_KEY[@]}"; do
          if [[ -n ${M_KEY[i]} && ${M_KEY[i]} == "$KEY" ]]; then
            MENU_IDX=$i L_CUR=$i MENU_POS[$title]=$i
            return 0
          fi
        done ;;
    esac
  done
}

# ── text viewer ──
view_row() { fl "${V_LINES[$1]}"; }

ui_view() { # TITLE [TOP_FN] — scroll through V_LINES
  L_TITLE=$1 L_TOP=${2:-} L_BOTTOM="" L_ROW=view_row L_FOCUSABLE="" L_VIEW=1 L_TEXT=""
  L_COUNT=${#V_LINES[@]} L_SCROLL=0
  hints "↑↓" scroll "q" back
  L_HINTS=$HINTS
  while :; do
    ui_list
    case $KEY in q | esc | left | enter | backspace) L_VIEW=0; return 0 ;; esac
  done
}

# ── dialogs ──

ui_confirm() { # TITLE [BODY] [DEFAULT y|n] → 0 = yes; CONFIRM_LINES (optional) are listed too
  local extra=("${CONFIRM_LINES[@]}")
  CONFIRM_LINES=()
  ((ASSUME_YES)) && return 0
  if ((!UI_ACTIVE)); then
    local l; for l in "${extra[@]}"; do printf '    %s\n' "$l"; done
    confirm "$1${2:+ ($2)}"; return
  fi
  local title=$1 body=${2:-} choice=${3:-n} w iw row col t b yes no btn pad r rule h maxl l x
  w=$((TERM_COLS - 8)); ((w > 64)) && w=64
  iw=$((w - 4))
  maxl=$((TERM_ROWS - 14))
  if ((${#extra[@]} > maxl && maxl > 1)); then
    x=$((${#extra[@]} - maxl + 1)); extra=("${extra[@]:0:maxl-1}" "… and $x more")
  elif ((maxl <= 1)); then extra=()
  fi
  h=$((8 + (${#extra[@]} ? ${#extra[@]} + 1 : 0)))
  row=$(((TERM_ROWS - h) / 2 + 1)); col=$(((TERM_COLS - w) / 2 + 1))
  local bc=$ACCENT
  [[ $title == ⚠* ]] && bc=$RED # dangerous action: red frame
  fitv t "$title" "$iw"; fitv b "$body" "$iw"
  repeatv rule ─ $((w - 2))
  while :; do
    if [[ $choice == y ]]; then yes="${REV}${GREEN}${BOLD}  Yes  ${NC}" no="${DIM}  No  ${NC}"
    else yes="${DIM}  Yes  ${NC}" no="${REV}${BOLD}  No  ${NC}"; fi
    btn="$yes    $no"
    pad=$(((iw - 17) / 2))
    r=$row
    printf '\e[%d;%dH%s╭%s╮%s' $((r++)) "$col" "$bc" "$rule" "$NC"
    printf '\e[%d;%dH%s│%s %*s %s│%s' $((r++)) "$col" "$bc" "$NC" "$iw" "" "$bc" "$NC"
    printf '\e[%d;%dH%s│%s %s%s%s %s│%s' $((r++)) "$col" "$bc" "$NC" "$BOLD" "$t" "$NC" "$bc" "$NC"
    printf '\e[%d;%dH%s│%s %s%s%s %s│%s' $((r++)) "$col" "$bc" "$NC" "$DIM" "$b" "$NC" "$bc" "$NC"
    if ((${#extra[@]})); then
      printf '\e[%d;%dH%s│%s %*s %s│%s' $((r++)) "$col" "$bc" "$NC" "$iw" "" "$bc" "$NC"
      for l in "${extra[@]}"; do
        fitv l "$l" "$iw"
        printf '\e[%d;%dH%s│%s %s %s│%s' $((r++)) "$col" "$bc" "$NC" "$l" "$bc" "$NC"
      done
    fi
    printf '\e[%d;%dH%s│%s %*s %s│%s' $((r++)) "$col" "$bc" "$NC" "$iw" "" "$bc" "$NC"
    printf '\e[%d;%dH%s│%s %*s%s%*s %s│%s' $((r++)) "$col" "$bc" "$NC" "$pad" "" "$btn" $((iw - pad - 17)) "" "$bc" "$NC"
    printf '\e[%d;%dH%s│%s %*s %s│%s' $((r++)) "$col" "$bc" "$NC" "$iw" "" "$bc" "$NC"
    printf '\e[%d;%dH%s╰%s╯%s' $((r++)) "$col" "$bc" "$rule" "$NC"
    read_key
    case $KEY in
      y) return 0 ;;
      n | q | esc) return 1 ;;
      left | right | tab) [[ $choice == y ]] && choice=n || choice=y ;;
      enter | space) [[ $choice == y ]]; return ;;
    esac
  done
}

ui_input() { # PROMPT [DEFAULT] → REPLY_TEXT; returns 1 when left empty
  if ((UI_ACTIVE)); then
    printf '\e[%d;1H\e[K' $((TERM_ROWS - 2))
    term_raw_on
    IFS= read -e -r -p " ? $1 " -i "${2:-}" REPLY_TEXT # no colours: readline would miscount the width
    term_raw_off
  else
    IFS= read -r -p "  $1 " REPLY_TEXT
    REPLY_TEXT=${REPLY_TEXT:-${2:-}}
  fi
  [[ -n $REPLY_TEXT ]]
}

ui_busy() { # MESSAGE PID [COUNT_FILE NOUN] — spinner until PID exits; q/esc cancels (returns 130)
  local n="" k
  while kill -0 "$2" 2>/dev/null; do
    if ((UI_ACTIVE)); then
      [[ -n ${3:-} ]] && n="   ${DIM}$(plural "$(wc -l <"$3" 2>/dev/null || echo 0)" "$4") found so far${NC}"
      frame_begin; draw_header "$UI_BUSY_TITLE"; fl ""
      fl "  ${ACCENT}${SPINNER[SPIN_I++ % 10]}${NC} $1$n"
      [[ -n ${UI_BUSY_STATUS:-} && -s $UI_BUSY_STATUS ]] && fl "    ${DIM}$(<"$UI_BUSY_STATUS")${NC}"
      hints q cancel
      draw_footer "$HINTS"; frame_flush
      if read_key 0.1 && [[ $KEY == q || $KEY == esc ]]; then
        kill_tree "$2"; wait "$2" 2>/dev/null
        toast "${YELLOW}!${NC} Cancelled."
        return 130
      fi
    else
      sleep 0.1
    fi
  done
  wait "$2" 2>/dev/null
  return 0 # the job's own status (e.g. permission errors) is not a cancellation
}

fl_card() { # LINE... — boxed card (lines may contain colors)
  local l w=0 n rule pad
  for l in "$@"; do vlen n "$l"; ((n > w)) && w=$n; done
  w=$((w + 4))
  repeatv rule ─ "$w"
  fl "   ${DIM}╭$rule╮${NC}"
  local sp
  for l in "$@"; do
    vlen n "$l"; pad=$((w - n - 2))
    printf -v sp '%*s' "$pad" ""
    fl "   ${DIM}│${NC}  $l$sp${DIM}│${NC}"
  done
  fl "   ${DIM}╰$rule╯${NC}"
}

# ───────────────────────────── command helpers ──────────────────────────────

# Every destructive action goes through run/run_root so --dry-run is honoured.
run() {
  if ((DRY_RUN)); then
    printf '    %s[dry-run]%s %.140s\n' "$MAGENTA" "$NC" "$*"
    return 0
  fi
  log "$*"
  "$@"
}

run_root() { # credentials are obtained up front by ensure_sudo, so never prompt here
  if ((EUID == 0)); then run "$@"; else run sudo -n "$@"; fi
}

# Use root for read-only scanning if credentials are already cached.
try_root() {
  if ((EUID == 0)); then "$@"
  elif sudo -n true 2>/dev/null; then sudo "$@"
  else "$@"; fi
}

have() { command -v "$1" >/dev/null 2>&1; }

du_sum() { # total bytes of the existing paths given
  local p ex=()
  for p in "$@"; do [[ -e $p ]] && ex+=("$p"); done
  ((${#ex[@]})) || { echo 0; return; }
  try_root du -scb -- "${ex[@]}" 2>/dev/null | tail -n1 | cut -f1
}

sum_lines() { awk '{s += $1} END {printf "%d\n", s}'; }
count_sum() { awk '{s += $1} END {printf "%d %d\n", NR, s}'; } # sizes on stdin → "COUNT BYTES"

pluralv() { # VAR N WORD → "1 file" / "3 files" / "2 entries" into VAR
  if (($2 == 1)); then printf -v "$1" '%d %s' "$2" "$3"
  elif [[ $3 == *[^aeiou]y ]]; then printf -v "$1" '%d %sies' "$2" "${3%y}"
  else printf -v "$1" '%d %ss' "$2" "$3"; fi
}
plural() { local __p; pluralv __p "$1" "$2"; printf '%s' "$__p"; }

is_protected() {
  local p
  p=$(realpath -m -- "$1")
  [[ $p == /* ]] || return 0
  case $p in
    / | /bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | /opt | /proc | /root | \
      /sbin | /srv | /sys | /usr | /usr/* | /var | /var/lib | "$HOME" | "$HOME/.config" | \
      "$HOME/.local" | "$HOME/.local/share") return 0 ;;
  esac
  return 1
}

empty_dir() { # [--root] DIR — delete the contents of DIR, keep DIR itself
  local as_root=0
  [[ $1 == --root ]] && { as_root=1; shift; }
  local d=$1
  [[ -d $d ]] || return 0
  if is_protected "$d"; then err "Refusing to touch protected path: $d"; return 1; fi
  if ((as_root)); then run_root find "$d" -mindepth 1 -delete
  else run find "$d" -mindepth 1 -delete; fi
}

# ── Trash (freedesktop.org Trash spec, like GNOME Files) ──
#
# Files in your home folder are moved into ~/.local/share/Trash by the app
# itself, so it knows where each one went and can put the last batch back
# (undo). Anything else goes through `gio trash`. Nothing is ever deleted
# permanently by these helpers.

UNDO_BATCH=() # "<name in Trash><TAB><original path>" of the last trash action

urlencode_path() { # PATH → percent-encoded, as the Trash spec wants for Path=
  local LC_ALL=C s=$1 i c out=""
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9/._~-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

trash_put() { # PATH (inside $HOME) → moved to the Trash, recorded for undo
  local p=$1 base name n=1 files=$TRASH_DIR/files info=$TRASH_DIR/info
  [[ -e $p || -L $p ]] || return 1
  if ((DRY_RUN)); then run mv -- "$p" "$files/"; return 0; fi
  if [[ ! -d $TRASH_DIR ]]; then mkdir -p "$TRASH_DIR" && chmod 700 "$TRASH_DIR" || return 1; fi
  mkdir -p "$files" "$info" || return 1
  base=${p##*/} name=${p##*/}
  while [[ -e $files/$name || -L $files/$name || -e $info/$name.trashinfo ]]; do
    n=$((n + 1)) name="$base.$n"
  done
  # write the .trashinfo first (as the spec asks), then move the file
  printf '[Trash Info]\nPath=%s\nDeletionDate=%(%Y-%m-%dT%H:%M:%S)T\n' "$(urlencode_path "$p")" -1 \
    >"$info/$name.trashinfo" || return 1
  if mv -- "$p" "$files/$name" 2>/dev/null; then
    log "trash $p"
    UNDO_BATCH+=("$name"$'\t'"$p")
    return 0
  fi
  rm -f -- "$info/$name.trashinfo"
  return 1
}

move_to_trash() { # PATH — never deletes permanently
  local p=$1
  [[ $p == /* ]] || p=$PWD/$p
  if is_protected "$p"; then err "Refusing to touch protected path: $p"; return 1; fi
  if [[ $p == "$HOME"/* ]]; then trash_put "$p"
  elif have gio; then run gio trash -- "$p"
  else err "Can't move $p to the Trash (it's outside your home folder and gio is missing)"; return 1; fi
}

undo_trash() { # put the last batch back → UNDO_OK, UNDO_FAILED
  local e name orig
  UNDO_OK=0 UNDO_FAILED=0
  for e in "${UNDO_BATCH[@]}"; do
    name=${e%%$'\t'*} orig=${e#*$'\t'}
    if [[ -e $orig || -L $orig || ! (-e $TRASH_DIR/files/$name || -L $TRASH_DIR/files/$name) ]]; then
      UNDO_FAILED=$((UNDO_FAILED + 1)); continue # already back, or emptied from the Trash
    fi
    if mkdir -p -- "${orig%/*}" && mv -- "$TRASH_DIR/files/$name" "$orig"; then
      rm -f -- "$TRASH_DIR/info/$name.trashinfo"
      log "restore $orig"
      UNDO_OK=$((UNDO_OK + 1))
    else UNDO_FAILED=$((UNDO_FAILED + 1)); fi
  done
  UNDO_BATCH=()
}

undo_toast() { # after a screen's own undo
  if ((UNDO_FAILED)); then toast "${YELLOW}!${NC} Put back $UNDO_OK, $UNDO_FAILED could not be restored."
  else toast "${GREEN}↶${NC} Put back $(plural "$UNDO_OK" item) from the Trash."; fi
}


# ───────────────────────────── cleanup registry ─────────────────────────────
#
# Each item <id> provides:
#   scan_<id>     sets SCAN_BYTES / SCAN_NOTE; returns 0 = junk found,
#                 1 = not applicable (hidden), 2 = nothing to clean
#   clean_<id>    performs the cleanup; non-zero return means skipped
#   details_<id>  (optional) shows exactly what would be removed
#
# Scans run in parallel subshells: they must only communicate through
# SCAN_BYTES / SCAN_NOTE (or files under $LOG_DIR).

declare -a ITEM_IDS=()
declare -A ITEM_CAT ITEM_LABEL ITEM_DEFAULT ITEM_DESC ITEM_ROOT
declare -A CAT_TITLE=([system]="System Junk" [logs]="Logs" [user]="User Junk" [browser]="Browsers"
  [apps]="App Caches" [ai]="AI Tools" [models]="AI Models" [dev]="Developer Junk" [privacy]="Privacy")
CATEGORIES=(system logs user browser apps ai models dev)

reg() { ITEM_IDS+=("$1"); ITEM_CAT[$1]=$2; ITEM_LABEL[$1]=$3; ITEM_DEFAULT[$1]=$4; ITEM_DESC[$1]=$5; }

#   id           category label                          default  description
reg apt_cache    system "APT package cache"                 1 "Downloaded .deb installers. apt re-downloads them if ever needed."
reg orphans      system "Unused packages & old kernels"     1 "Packages installed as dependencies that nothing needs any more (apt autoremove)."
reg residual     system "Leftover package configs"          1 "System config files of packages that were removed but not purged."
reg journal      logs   "Systemd journal logs"              1 "Archived system logs. Keeps the last 7 days and at most 100 MB."
reg old_logs     logs   "Rotated / archived logs"           1 "Compressed or rotated log files in /var/log (*.gz, *.1, *.old)."
reg big_logs     logs   "Oversized active logs"             1 "Live logs in /var/log over 50 MB, emptied in place — services keep logging normally."
reg app_logs     logs   "Old app logs"                      1 "Log files of apps (VS Code, Slack, …) not written for 3+ days."
reg crash        logs   "Crash reports"                     1 "Apport crash reports in /var/crash."
reg coredump     logs   "Core dumps"                        1 "Memory dumps of crashed programs kept by systemd-coredump."
reg snap_old     system "Old Snap revisions"                1 "Disabled previous versions of snaps, kept only for rollback."
reg old_kernels  system "Extra old kernels"                 0 "Kernels older than your two newest (never the one running), so a fallback always stays."
reg tmp          system "Old temporary files"               1 "Your files in /tmp and /var/tmp not touched for 10+ days."
reg thumbs       user   "Thumbnail cache"                   1 "Image previews generated by the file manager; rebuilt on demand."
reg trash        user   "Trash"                             1 "Files you already deleted. Review before emptying!"
reg app_cache    user   "Stale app caches (>30 days)"       1 "Files under ~/.cache not modified or read for 30+ days."
reg node_modules dev    "Stale node_modules"                0 "node_modules of projects untouched for 90+ days. Restore with npm/yarn/pnpm install."
reg npm          dev    "npm cache"                         1 "npm's package download cache (~/.npm/_cacache)."
reg yarn         dev    "Yarn cache"                        1 "Yarn's package download cache."
reg pnpm         dev    "pnpm store (unreferenced)"         1 "Packages in the pnpm store no project references (pnpm store prune)."
reg bun          dev    "Bun cache"                         1 "Bun's package install cache."
reg pip          dev    "pip cache"                         1 "pip's wheel and HTTP download cache."
reg gobuild      dev    "Go build cache"                    1 "Compiled Go build artifacts (go clean -cache)."
reg cargo        dev    "Cargo registry cache"              0 "Downloaded and extracted crates; re-downloaded on next build."
reg gradle       dev    "Gradle caches"                     0 "Gradle dependency and build caches; re-downloaded on next build."
reg maven        dev    "Maven repository"                  0 "Local Maven repository (~/.m2/repository); re-downloaded on next build."
reg conda        dev    "Conda package cache"               1 "Downloaded package archives, index cache and logs (conda clean --tarballs). Your environments are kept."
reg docker_dangling dev "Docker: dangling images"           1 "Untagged leftover image layers from rebuilds — nothing uses them."
reg docker_build dev    "Docker: build cache"               0 "BuildKit cache. Safe to remove; the next build is slower once."
reg docker_containers dev "Docker: stopped containers"      0 "Containers that aren't running. Anything stored inside them (not in volumes) is lost."
reg docker_images dev   "Docker: unused images"             0 "Images no container uses. They are pulled again when needed."
reg docker_volumes dev  "Docker: unused volumes"            0 "Volumes no container uses — they may hold databases or other data. Review before removing!"
reg podman       dev    "Podman: stopped containers & dangling images" 0 "podman system prune: stopped containers, untagged image layers and unused networks. Volumes and tagged images are kept."

for _id in apt_cache orphans residual journal old_logs big_logs crash coredump snap_old old_kernels; do ITEM_ROOT[$_id]=1; done
unset _id

# ── detail helpers ──

detail_files() { # [N] — reads "bytes<TAB>path" lines, prints the N largest
  sort -t$'\t' -k1,1rn | head -n "${1:-20}" | while IFS=$'\t' read -r b f; do
    printf '  %s%10s%s  %s\n' "$(size_color "$b")" "$(human "$b")" "$NC" "${f/#$HOME/\~}"
  done
}

detail_paths() { # PATH... — size of each path and its biggest entries
  local p
  for p in "$@"; do
    [[ -e $p ]] || continue
    printf '  %s%10s  %s%s\n' "$BOLD" "$(human "$(du_sum "$p")")" "${p/#$HOME/\~}" "$NC"
    [[ -d $p ]] || continue
    try_root find "$p" -mindepth 1 -maxdepth 1 -exec du -sb {} + 2>/dev/null | detail_files 8 | sed 's/^/  /'
  done
}

# ── System ──

scan_apt_cache() {
  have apt-get || return 1
  local debs
  mapfile -t debs < <(compgen -G '/var/cache/apt/archives/*.deb')
  ((${#debs[@]})) || return 2
  SCAN_BYTES=$(du_sum "${debs[@]}")
  SCAN_NOTE="$(plural ${#debs[@]} "downloaded installer")"
  ((SCAN_BYTES > 0)) || return 2
}
clean_apt_cache() { run_root apt-get clean; }
details_apt_cache() { find /var/cache/apt/archives -name '*.deb' -printf '%s\t%f\n' 2>/dev/null | detail_files 30; }

orphan_pkgs() { apt-get -s autoremove 2>/dev/null | awk '/^Remv / {print $2}'; }
scan_orphans() {
  have apt-get || return 1
  local pkgs kb
  mapfile -t pkgs < <(orphan_pkgs)
  ((${#pkgs[@]})) || return 2
  kb=$(dpkg-query -W -f='${Installed-Size}\n' "${pkgs[@]}" 2>/dev/null | sum_lines)
  SCAN_BYTES=$((kb * 1024))
  SCAN_NOTE="$(plural ${#pkgs[@]} package)"
}
clean_orphans() { run_root apt-get autoremove --purge -y; }
details_orphans() {
  local pkgs
  mapfile -t pkgs < <(orphan_pkgs)
  ((${#pkgs[@]})) || return 0
  dpkg-query -W -f='${Installed-Size}\t${Package}\n' "${pkgs[@]}" 2>/dev/null |
    awk -F'\t' '{print $1 * 1024 "\t" $2}' | detail_files 200
}

# Bootloader packages are skipped: their purge scripts can remove boot configuration.
residual_pkgs() { dpkg -l 2>/dev/null | awk '/^rc/ && $2 !~ /^(grub|shim|systemd-boot)/ {print $2}'; }
scan_residual() {
  have dpkg || return 1
  local pkgs
  mapfile -t pkgs < <(residual_pkgs)
  ((${#pkgs[@]})) || return 2
  SCAN_NOTE="$(plural ${#pkgs[@]} "removed package") still configured"
}
clean_residual() {
  local pkgs
  mapfile -t pkgs < <(residual_pkgs)
  ((${#pkgs[@]})) && run_root dpkg --purge "${pkgs[@]}"
}
details_residual() { residual_pkgs | column -c 100 | sed 's/^/  /'; }

# Only archived journal files (name@….journal or *.journal~) can be vacuumed:
# estimate those older than 7 days plus whatever exceeds the 100 MB cap.
JOURNAL_KEEP_DAYS=7 JOURNAL_KEEP_BYTES=$((100 * 1024 * 1024))
journal_files() { try_root find /var/log/journal -type f -name '*.journal*' -printf '%s\t%T@\t%f\t%p\n' 2>/dev/null; }
scan_journal() {
  have journalctl && [[ -d /var/log/journal ]] || return 1
  local total archived old cutoff extra
  cutoff=$((EPOCHSECONDS - JOURNAL_KEEP_DAYS * 86400))
  read -r total archived old < <(journal_files | awk -F'\t' -v c="$cutoff" '
    {t += $1; if ($3 ~ /@|~$/) {a += $1; if ($2 < c) o += $1}}
    END {printf "%d %d %d\n", t, a, o}')
  extra=$((total - old - JOURNAL_KEEP_BYTES)); ((extra < 0)) && extra=0
  SCAN_BYTES=$((old + extra)); ((SCAN_BYTES > archived)) && SCAN_BYTES=$archived
  SCAN_NOTE="$(human "$total") in total"
  ((SCAN_BYTES > 0)) || return 2
}
clean_journal() { run_root journalctl --vacuum-time="${JOURNAL_KEEP_DAYS}d" --vacuum-size="${JOURNAL_KEEP_MB}M"; }
details_journal() {
  journalctl --disk-usage 2>/dev/null | sed 's/^/  /'
  printf '\n  %sLargest archived journal files:%s\n' "$BOLD" "$NC"
  journal_files | awk -F'\t' '$3 ~ /@|~$/ {print $1 "\t" $4}' | detail_files 15
}

# Rotated logs only: compressed, numbered (syslog.1) or *.old, untouched for an hour.
# Samba's live per-client logs (log.<host>) also end in digits, so skip those.
LOG_MATCH=(\( -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]' -o -name '*.old' \) -not -name 'log.*' -mmin +60)
scan_old_logs() {
  local n
  read -r n SCAN_BYTES < <(try_root find /var/log -type f "${LOG_MATCH[@]}" -printf '%s\n' 2>/dev/null | count_sum)
  SCAN_NOTE="$(plural "$n" file) in /var/log"
  ((SCAN_BYTES > 0)) || return 2
}
clean_old_logs() { run_root find /var/log -type f "${LOG_MATCH[@]}" -delete || true; } # unreadable dirs are expected
details_old_logs() { try_root find /var/log -type f "${LOG_MATCH[@]}" -printf '%s\t%p\n' 2>/dev/null | detail_files 30; }

dir_files_scan() { # DIR NOUN — size and count of files under DIR
  [[ -d $1 ]] || return 1
  local n
  read -r n SCAN_BYTES < <(try_root find "$1" -mindepth 1 -type f -printf '%s\n' 2>/dev/null | count_sum)
  SCAN_NOTE=$(plural "$n" "$2")
  ((n > 0)) || return 2
}
dir_files_details() { try_root find "$1" -mindepth 1 -type f -printf '%s\t%p\n' 2>/dev/null | detail_files 30; }

scan_crash() { dir_files_scan /var/crash report; }
clean_crash() { empty_dir --root /var/crash; }
details_crash() { dir_files_details /var/crash; }

scan_coredump() { dir_files_scan /var/lib/systemd/coredump dump; }
clean_coredump() { empty_dir --root /var/lib/systemd/coredump; }
details_coredump() { dir_files_details /var/lib/systemd/coredump; }

# Live logs that grew past LOG_MAX_MB. They are truncated, not deleted: the
# service keeps its file open and continues writing to it. Login records,
# audit logs and the binary journal are never touched.
big_logs_find() {
  try_root find /var/log \( -path /var/log/journal -o -path /var/log/audit -o -name wtmp -o -name btmp \
    -o -name lastlog -o -name faillog \) -prune -o -type f -size +"${LOG_MAX_MB}"M \
    -not \( -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]' -o -name '*.old' -o -name '*.journal*' \) "$@" 2>/dev/null
}
scan_big_logs() {
  local rows r names=()
  mapfile -t rows < <(big_logs_find -printf '%s\t%f\n')
  ((${#rows[@]})) || return 2
  SCAN_BYTES=0
  for r in "${rows[@]}"; do SCAN_BYTES=$((SCAN_BYTES + ${r%%$'\t'*})) names+=("${r#*$'\t'}"); done
  SCAN_NOTE=$(printf '%s\n' "${names[@]}" | head -n 3 | paste -sd, - | sed 's/,/, /g')
  ((${#rows[@]} > 3)) && SCAN_NOTE+=", …"
  return 0
}
clean_big_logs() {
  local files f
  mapfile -t files < <(big_logs_find -print)
  for f in "${files[@]}"; do run_root truncate -s 0 -- "$f"; done
}
details_big_logs() { big_logs_find -printf '%s\t%p\n' | detail_files 30; }

app_log_dirs() { # per-app log folders
  local d
  for d in "${XDG_CONFIG_HOME:-$HOME/.config}"/*/{logs,log} "${XDG_DATA_HOME:-$HOME/.local/share}"/*/{logs,log} \
    "$HOME"/snap/*/*/.config/*/logs "$HOME"/.var/app/*/config/*/logs; do
    [[ -d $d && ! -L $d ]] && printf '%s\n' "$d"
  done
}
app_logs_find() { # log files not written for APPLOG_DAYS (current logs stay)
  local dirs
  mapfile -t dirs < <(app_log_dirs)
  ((${#dirs[@]})) || return 0
  find "${dirs[@]}" -type f -mtime +"$APPLOG_DAYS" "$@" 2>/dev/null
}
scan_app_logs() {
  local n dirs
  mapfile -t dirs < <(app_log_dirs)
  ((${#dirs[@]})) || return 1
  read -r n SCAN_BYTES < <(find "${dirs[@]}" -type f -mtime +"$APPLOG_DAYS" -printf '%s\n' 2>/dev/null | count_sum)
  SCAN_NOTE="$(plural "$n" file) in $(plural ${#dirs[@]} app)"
  ((n > 0)) || return 2
}
clean_app_logs() {
  local dirs
  if ((DRY_RUN)); then run find "(app log folders)" -type f -mtime +"$APPLOG_DAYS" -delete; return; fi
  log "app_logs_find -delete"
  app_logs_find -delete
  mapfile -t dirs < <(app_log_dirs) # drop the session folders that are now empty
  ((${#dirs[@]})) && find "${dirs[@]}" -mindepth 1 -type d -empty -delete 2>/dev/null
  return 0
}
details_app_logs() { # grouped per app
  local d
  app_log_dirs | while IFS= read -r d; do
    printf '%s\t%s\n' "$(find "$d" -type f -mtime +"$APPLOG_DAYS" -printf '%s\n' 2>/dev/null | sum_lines)" "$d"
  done | awk -F'\t' '$1 > 0' | detail_files 30
}

snap_disabled() { snap list --all 2>/dev/null | awk 'NR > 1 && /disabled/ {print $1, $3}'; }
scan_snap_old() {
  have snap || return 1
  local revs n r files=()
  mapfile -t revs < <(snap_disabled)
  ((${#revs[@]})) || return 2
  for n in "${revs[@]}"; do
    read -r n r <<<"$n"; files+=("/var/lib/snapd/snaps/${n}_${r}.snap")
  done
  SCAN_BYTES=$(du_sum "${files[@]}")
  SCAN_NOTE="$(plural ${#revs[@]} "disabled revision")"
}
clean_snap_old() {
  local revs line n r
  mapfile -t revs < <(snap_disabled)
  for line in "${revs[@]}"; do
    read -r n r <<<"$line"
    run_root snap remove "$n" --revision="$r"
  done
}
details_snap_old() {
  local n r
  snap_disabled | while read -r n r; do
    printf '%s\t%s (revision %s)\n' "$(du_sum "/var/lib/snapd/snaps/${n}_${r}.snap")" "$n" "$r"
  done | detail_files 50
}

# Kernels beyond the two newest and the running one. Like Ubuntu itself, we
# always keep a fallback: if the newest kernel fails to boot, the previous one is there.
kernel_extras() { # RUNNING_VERSION, installed versions on stdin → versions that are safe to remove
  local running=$1 v all=() n
  mapfile -t all < <(grep -v '^$' | sort -V -u)
  n=${#all[@]}
  ((n > 2)) || return 0
  for v in "${all[@]:0:n-2}"; do [[ $v != "$running" ]] && printf '%s\n' "$v"; done
  return 0
}
installed_kernels() { # versions of installed linux-image-<version> packages
  dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-[0-9]*' 2>/dev/null |
    awk -F'\t' '$1 ~ /^ii/ {sub(/^linux-image-(unsigned-)?/, "", $2); print $2}' | sort -u
}
kernel_packages() { # VERSION... → installed packages belonging to those kernels
  local v
  for v in "$@"; do
    dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' "*-$v" 2>/dev/null | awk -F'\t' '$1 ~ /^ii/ {print $2}'
  done | sort -u
}
scan_old_kernels() {
  have dpkg-query || return 1
  local extras pkgs kb
  mapfile -t extras < <(installed_kernels | kernel_extras "$(uname -r)")
  ((${#extras[@]})) || return 2
  mapfile -t pkgs < <(kernel_packages "${extras[@]}")
  kb=$(dpkg-query -W -f='${Installed-Size}\n' "${pkgs[@]}" 2>/dev/null | sum_lines)
  SCAN_BYTES=$((kb * 1024))
  SCAN_NOTE=$(printf '%s\n' "${extras[@]}" | paste -sd, - | sed 's/,/, /g')
}
clean_old_kernels() {
  local extras pkgs sim others
  mapfile -t extras < <(installed_kernels | kernel_extras "$(uname -r)")
  ((${#extras[@]})) || return 0
  mapfile -t pkgs < <(kernel_packages "${extras[@]}")
  # refuse unless apt would remove exactly these kernel packages and nothing else
  sim=$(LC_ALL=C apt-get -s purge "${pkgs[@]}" 2>&1) || { echo "apt refuses: $(grep -m1 '^E:' <<<"$sim")"; return 1; }
  others=$(grep '^Purg' <<<"$sim" | awk '{print $2}' | grep -vxF -f <(printf '%s\n' "${pkgs[@]}"))
  if [[ -n $others ]]; then
    echo "Not removing: apt would also remove $(paste -sd' ' <<<"$others")"
    return 1
  fi
  run_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}"
}
details_old_kernels() {
  local v running
  local extras
  running=$(uname -r)
  extras=" $(installed_kernels | kernel_extras "$running" | paste -sd' ' -) "
  installed_kernels | sort -V | while IFS= read -r v; do
    if [[ $v == "$running" ]]; then printf '  %s  ← running (kept)\n' "$v"
    elif [[ $extras != *" $v "* ]]; then printf '  %s  ← kept as a fallback\n' "$v"
    else printf '  %s  ← will be removed: %s\n' "$v" "$(kernel_packages "$v" | paste -sd' ' -)"; fi
  done
  return 0
}

# Untouched (neither modified nor read) for 10+ days and owned by you.
tmp_find() { find /tmp /var/tmp -xdev -mindepth 1 -user "$(id -u)" -type f -mtime +"$TMP_DAYS" -atime +"$TMP_DAYS" "$@" 2>/dev/null; }
scan_tmp() {
  local n
  read -r n SCAN_BYTES < <(tmp_find -printf '%s\n' | count_sum)
  SCAN_NOTE=$(plural "$n" file)
  ((n > 0)) || return 2
}
clean_tmp() {
  if ((DRY_RUN)); then run find /tmp /var/tmp -xdev -mindepth 1 -user "$(id -u)" -type f -mtime +"$TMP_DAYS" -atime +"$TMP_DAYS" -delete
  else log "tmp_find -delete"; tmp_find -delete || true; fi # other users' folders in /tmp are unreadable: expected
}
details_tmp() { tmp_find -printf '%s\t%p\n' | detail_files 30; }

# ── User ──

scan_thumbs() {
  SCAN_BYTES=$(du_sum "$HOME/.cache/thumbnails")
  SCAN_NOTE="~/.cache/thumbnails"
  ((SCAN_BYTES > 0)) || return 2
}
clean_thumbs() { empty_dir "$HOME/.cache/thumbnails"; }
details_thumbs() { detail_paths "$HOME/.cache/thumbnails"; }

TRASH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
scan_trash() {
  local n
  SCAN_BYTES=$(du_sum "$TRASH_DIR/files")
  n=$(find "$TRASH_DIR/files" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
  SCAN_NOTE=$(plural "$n" item)
  ((n > 0)) || return 2
}
clean_trash() { # the same Trash folder the scan measures (gio could act on another one, or on none)
  empty_dir "$TRASH_DIR/files" && empty_dir "$TRASH_DIR/info"
  [[ -d $TRASH_DIR/expunged ]] && empty_dir "$TRASH_DIR/expunged"
  return 0
}
details_trash() { detail_paths "$TRASH_DIR/files"; }

# ── Browsers & apps: one item per browser / app ──
#
# Cache items are data-driven: ITEM_PATHS holds the cache folders (one per
# line) and ITEM_PROCS the process names to check before cleaning. Their
# scan_/clean_/details_ functions are generated by reg_cache_item.

declare -A ITEM_PATHS=() ITEM_PROCS=()

cache_item_dirs() { # ID → existing cache folders, one per line
  local p
  while IFS= read -r p; do [[ -n $p && -d $p && ! -L $p ]] && printf '%s\n' "$p"; done <<<"${ITEM_PATHS[$1]}"
}

cache_item_scan() {
  local dirs n
  mapfile -t dirs < <(cache_item_dirs "$1")
  ((${#dirs[@]})) || return 1
  SCAN_BYTES=$(du_sum "${dirs[@]}")
  if ((${#dirs[@]} == 1)); then SCAN_NOTE=${dirs[0]/#$HOME/\~}
  else
    n=$(printf '%s\n' "${dirs[@]##*/}" | sort -u | head -n 3 | paste -sd, - | sed 's/,/, /g')
    SCAN_NOTE="$n$( ((${#dirs[@]} > 3)) && echo ", …")"
  fi
  ((SCAN_BYTES > 0)) && return 0
  [[ ${ITEM_CAT[$1]} == apps ]] && return 1 # don't list apps with empty caches
  return 2
}

cache_item_clean() { local d; while IFS= read -r d; do empty_dir "$d"; done < <(cache_item_dirs "$1"); }

cache_item_details() {
  local d
  cache_item_dirs "$1" | while IFS= read -r d; do printf '%s\t%s\n' "$(du_sum "$d")" "$d"; done | detail_files 40
  return 0
}

cache_item_precheck() { # ask (or skip when unattended) if the program is running
  pgrep -xi "${ITEM_PROCS[$1]}" >/dev/null 2>&1 || return 0
  if ((ASSUME_YES)); then warn "Skipping ${ITEM_LABEL[$1]}: it is running."; return 1; fi
  ui_confirm "${ITEM_LABEL[$1]} is running" "Close it first for best results. Clean its cache anyway?" n
}

reg_cache_item() { # ID CATEGORY LABEL DEFAULT DESCRIPTION PATHS [PROCESS_REGEX]
  local id=$1
  [[ $id =~ ^[a-z0-9_]+$ ]] || return 1 # ids become function names below
  reg "$id" "$2" "$3" "$4" "$5"
  ITEM_PATHS[$id]=$6
  ITEM_PROCS[$id]=${7:-}
  eval "scan_$id() { cache_item_scan $id; }
        clean_$id() { cache_item_clean $id; }
        details_$id() { cache_item_details $id; }"
  [[ -n ${7:-} ]] && eval "precheck_$id() { cache_item_precheck $id; }"
  return 0
}

#   id                label            processes              cache folders (deb, snap, flatpak)
BROWSERS=(
  "browser_firefox|Firefox|firefox|$HOME/.cache/mozilla
$HOME/snap/firefox/common/.cache
$HOME/.var/app/org.mozilla.firefox/cache"
  "browser_chrome|Google Chrome|chrome|$HOME/.cache/google-chrome
$HOME/.var/app/com.google.Chrome/cache"
  "browser_chromium|Chromium|chromium|$HOME/.cache/chromium
$HOME/snap/chromium/common/.cache
$HOME/.var/app/org.chromium.Chromium/cache"
  "browser_brave|Brave|brave|$HOME/.cache/BraveSoftware
$HOME/snap/brave/common/.cache
$HOME/.var/app/com.brave.Browser/cache"
  "browser_edge|Microsoft Edge|msedge|$HOME/.cache/microsoft-edge
$HOME/.var/app/com.microsoft.Edge/cache"
  "browser_vivaldi|Vivaldi|vivaldi-bin|$HOME/.cache/vivaldi"
  "browser_opera|Opera|opera|$HOME/.cache/opera
$HOME/snap/opera/common/.cache"
)
for _b in "${BROWSERS[@]}"; do
  IFS='|' read -r _id _label _procs _paths <<<"$_b"
  _paths=${_b#*|*|*|}
  reg_cache_item "$_id" browser "$_label" 0 \
    "Web cache of $_label (pages, images, scripts). Logins, history and bookmarks are kept." "$_paths" "$_procs"
done

ELECTRON_SUBDIRS=(Cache "Code Cache" GPUCache DawnCache DawnGraphiteCache DawnWebGPUCache
  CachedData CachedExtensionVSIXs "Service Worker/CacheStorage")
declare -A APP_NAMES=([Code]="VS Code" ["Code - Insiders"]="VS Code Insiders" [VSCodium]="VSCodium"
  [discord]="Discord" [Slack]="Slack" [Signal]="Signal" [obsidian]="Obsidian" [spotify]="Spotify"
  [teams-for-linux]="Teams" [Element]="Element" [bitwarden]="Bitwarden" [Postman]="Postman"
  [Cursor]="Cursor" [Notion]="Notion" [1Password]="1Password" [whatsapp-for-linux]="WhatsApp"
  [snap-store]="App Center")
BROWSER_DIRS='^(google-chrome.*|chromium|BraveSoftware|microsoft-edge.*|vivaldi.*|opera.*|mozilla)$'
BROWSER_FLATPAKS='^(org\.mozilla\.firefox|com\.google\.Chrome|org\.chromium\.Chromium|com\.brave\.Browser|com\.microsoft\.Edge)$'
BROWSER_SNAPS='^(firefox|chromium|brave|opera)$'

add_app_item() { # NAME KIND PATHS [PROCESS]
  local id=${1,,}
  id="app_${id//[^a-z0-9]/_}"
  while [[ -n ${ITEM_CAT[$id]:-} ]]; do id+=_; done
  reg_cache_item "$id" apps "$1" 0 \
    "Cache folders of $1 ($2). Rebuilt automatically — close the app before cleaning." "$3" "${4:-}"
}

pretty_name() { # snap-store → Snap Store, firmware_updater → Firmware Updater
  local IFS='-_ ' w out=() words
  read -ra words <<<"$1"
  for w in "${words[@]}"; do out+=("${w^}"); done
  IFS=' '
  printf '%s' "${out[*]}"
}

flatpak_label() { # org.telegram.desktop → telegram, com.spotify.Client → spotify, org.gimp.GIMP → GIMP
  local IFS=. parts
  read -ra parts <<<"$1"
  local last=${parts[-1]}
  [[ ${last,,} =~ ^(client|desktop|app|application)$ && ${#parts[@]} -gt 1 ]] && last=${parts[-2]}
  pretty_name "$last"
}

discover_app_caches() {
  local app name sub dirs
  for app in "${XDG_CONFIG_HOME:-$HOME/.config}"/*/; do # Electron apps
    name=${app%/}; name=${name##*/}
    [[ $name =~ $BROWSER_DIRS ]] && continue
    dirs=""
    for sub in "${ELECTRON_SUBDIRS[@]}"; do [[ -d $app$sub && ! -L $app$sub ]] && dirs+="$app$sub"$'\n'; done
    # process name guess: first word of the folder name (Code → code, "Antigravity IDE" → antigravity)
    [[ -n $dirs ]] && add_app_item "${APP_NAMES[$name]:-$( [[ $name == [a-z]* ]] && pretty_name "$name" || printf '%s' "$name")}" \
      "Electron app" "${dirs%$'\n'}" "${name%% *}"
  done
  for app in "$HOME"/.var/app/*/cache; do # Flatpak apps
    [[ -d $app ]] || continue
    name=${app%/cache}; name=${name##*/}
    [[ $name =~ $BROWSER_FLATPAKS ]] && continue
    add_app_item "$(flatpak_label "$name") (Flatpak)" "Flatpak $name" "$app"
  done
  for app in "$HOME"/snap/*/common/.cache; do # Snap apps
    [[ -d $app ]] || continue
    name=${app#"$HOME"/snap/}; name=${name%%/*}
    [[ $name =~ $BROWSER_SNAPS ]] && continue
    add_app_item "${APP_NAMES[$name]:-$(pretty_name "$name")} (Snap)" "Snap $name" "$app"
  done
  return 0
}
discover_app_caches
reg_cache_item app_steam_shaders apps "Steam — shader cache" 0 \
  "Shaders Steam compiled for your games. Steam rebuilds them; a game may stutter briefly the first time." \
  "$HOME/.local/share/Steam/steamapps/shadercache
$HOME/.steam/debian-installation/steamapps/shadercache
$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/shadercache
$HOME/snap/steam/common/.local/share/Steam/steamapps/shadercache" 'steam|steamwebhelper'
unset _b _id _label _procs _paths

# ── Privacy: histories and recent-items lists ──
#
# History files are emptied in place (truncate) so permissions and symlinks
# survive; the recent-files list gets a valid empty XBEL document. These
# items are not part of Smart Scan — they live on the Privacy screen.

declare -A PRIV_MODE=() PRIV_NOUN=()

priv_files() { # ID → existing files, one per line
  local p
  while IFS= read -r p; do [[ -n $p && -f $p ]] && printf '%s\n' "$p"; done <<<"${ITEM_PATHS[$1]}" | sort -u
}

priv_count() { # FILE MODE → number of entries
  case $2 in
    xbel) grep -c '<bookmark ' -- "$1" 2>/dev/null || true ;;
    fish) grep -c '^- cmd:' -- "$1" 2>/dev/null || true ;;
    lines) wc -l <"$1" 2>/dev/null || echo 0 ;;
    *) echo 0 ;;
  esac
}

priv_scan() {
  local files f n=0 mode=${PRIV_MODE[$1]}
  mapfile -t files < <(priv_files "$1")
  ((${#files[@]})) || return 1
  SCAN_BYTES=$(du_sum "${files[@]}")
  if [[ -n ${PRIV_NOUN[$1]} ]]; then
    for f in "${files[@]}"; do n=$((n + $(priv_count "$f" "$mode"))); done
    SCAN_NOTE=$(plural "$n" "${PRIV_NOUN[$1]}")
    ((n > 0)) || return 2
  else
    SCAN_NOTE=$(printf '%s\n' "${files[@]##*/}" | paste -sd, - | sed 's/,/, /g')
    ((SCAN_BYTES > 0)) || return 2
  fi
}

write_empty_xbel() {
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks" xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info">' \
    '</xbel>' >"$1"
}

priv_clean() {
  local f
  [[ $1 == priv_zeitgeist ]] && have zeitgeist-daemon && run zeitgeist-daemon --quit
  while IFS= read -r f; do
    case ${PRIV_MODE[$1]} in
      xbel) run write_empty_xbel "$f" ;;
      delete) run rm -f -- "$f" ;;
      *) run truncate -s 0 -- "$f" ;;
    esac
  done < <(priv_files "$1")
}

priv_details() { # sizes and entry counts only — never the contents
  local f
  while IFS= read -r f; do
    printf '%s\t%s%s\n' "$(du_sum "$f")" "$f" \
      "$([[ -n ${PRIV_NOUN[$1]} ]] && echo "  ($(plural "$(priv_count "$f" "${PRIV_MODE[$1]}")" "${PRIV_NOUN[$1]}"))")"
  done < <(priv_files "$1") | detail_files 20
  return 0
}

priv_shell_precheck() { # open terminals write their in-memory history back on exit
  local n
  n=$(pgrep -cxf "${ITEM_PROCS[$1]}" 2>/dev/null) || n=0
  ((n > 0)) || return 0
  ((ASSUME_YES)) && return 0
  ui_confirm "$(plural "$n" "open terminal") will rewrite this history" \
    "Run 'history -c' in them or close them first. Clear the file anyway?" y
}

reg_privacy_item() { # ID LABEL DEFAULT DESCRIPTION MODE NOUN PATHS [SHELL_CMDLINE_REGEX]
  local id=$1
  [[ $id =~ ^[a-z0-9_]+$ ]] || return 1
  reg "$id" privacy "$2" "$3" "$4"
  PRIV_MODE[$id]=$5 PRIV_NOUN[$id]=$6 ITEM_PATHS[$id]=$7 ITEM_PROCS[$id]=${8:-}
  eval "scan_$id() { priv_scan $id; }
        clean_$id() { priv_clean $id; }
        details_$id() { priv_details $id; }"
  [[ -n ${8:-} ]] && eval "precheck_$id() { priv_shell_precheck $id; }"
  return 0
}

_data=${XDG_DATA_HOME:-$HOME/.local/share}
_state=${XDG_STATE_HOME:-$HOME/.local/state}
reg_privacy_item priv_recent "Recent files list" 1 \
  "What Files and Open dialogs show under “Recent”. Only the list is cleared — your files are not touched." \
  xbel "recent file" "$_data/recently-used.xbel"
reg_privacy_item priv_zsh "Zsh history" 0 "Every command you typed in zsh." lines command \
  "$HOME/.zsh_history
$HOME/.zhistory
$HOME/.histfile
${ZDOTDIR:-$HOME}/.zsh_history" 'zsh|-zsh|/bin/zsh|/usr/bin/zsh'
reg_privacy_item priv_bash "Bash history" 0 "Every command you typed in bash (~/.bash_history)." lines command \
  "$HOME/.bash_history" 'bash|-bash|/bin/bash|/usr/bin/bash'
reg_privacy_item priv_fish "Fish history" 0 "Every command you typed in fish." fish command \
  "$_data/fish/fish_history" 'fish|-fish|/bin/fish|/usr/bin/fish'
reg_privacy_item priv_repl "Python, Node & database shells" 0 \
  "History of the python, node, irb, mysql, psql, sqlite3 and redis-cli prompts." lines entry \
  "$HOME/.python_history
$HOME/.node_repl_history
$HOME/.irb_history
$HOME/.mysql_history
$HOME/.psql_history
$HOME/.sqlite_history
$HOME/.rediscli_history"
reg_privacy_item priv_misc "less & wget history" 1 "Searches typed in less, and wget's list of visited HTTPS sites." \
  lines entry "$HOME/.lesshst
$HOME/.wget-hsts"
reg_privacy_item priv_editor "Vim & Neovim history" 0 \
  "Command and search history, marks and registers that Vim (~/.viminfo) and Neovim (ShaDa) remember." delete "" \
  "$HOME/.viminfo
$_state/nvim/shada/main.shada"
reg_privacy_item priv_zeitgeist "Activity log (Zeitgeist)" 0 "The record of files and apps you used, kept by Zeitgeist." delete "" \
  "$_data/zeitgeist/activity.sqlite
$_data/zeitgeist/activity.sqlite-wal
$_data/zeitgeist/activity.sqlite-shm"
unset _data _state

# GNOME remembers some things in settings rather than files.
GS_HISTORY_KEYS=("org.gnome.shell command-history" "org.gnome.shell looking-glass-history"
  "org.gtk.Settings.EmojiChooser recent-emoji" "org.gtk.gtk4.Settings.EmojiChooser recently-used-emoji"
  "org.gnome.Characters recent-characters")
reg priv_gsettings privacy "Run dialog & emoji history" 1 \
  "Commands typed in Alt+F2, recently used emoji and characters."
gs_nonempty_keys() {
  local k v schema key
  for k in "${GS_HISTORY_KEYS[@]}"; do
    read -r schema key <<<"$k"
    v=$(gsettings get "$schema" "$key" 2>/dev/null) || continue
    [[ $v =~ ^(@[^\ ]+\ )?\[\]$ ]] || printf '%s\n' "$k"
  done
}
scan_priv_gsettings() {
  have gsettings || return 1
  local keys
  mapfile -t keys < <(gs_nonempty_keys)
  ((${#keys[@]})) || return 2
  SCAN_NOTE="$(plural ${#keys[@]} list) with entries"
}
clean_priv_gsettings() {
  local schema key
  while read -r schema key; do run gsettings reset "$schema" "$key"; done < <(gs_nonempty_keys)
}
details_priv_gsettings() { gs_nonempty_keys | sed 's/^/  /'; return 0; }

# ── AI tools: caches/logs and old chat history ──
#
# Each item has a list function printing the paths to remove (files or whole
# folders). History items only list sessions older than AI_HISTORY_DAYS, so
# recent and running sessions stay. Credentials, settings, plugins, skills and
# Claude Code's memory/ folders are never listed (see ai_safe_path).

declare -A LIST_FN=() LIST_ROOTS=() LIST_NOUN=() LIST_RUN_DEFAULT=()

aged() { # DIR DAYS [find tests…] — entries directly inside DIR not modified for DAYS
  [[ -d $1 && ! -L $1 ]] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -mtime +"$2" "${@:3}" -print 2>/dev/null
}
contents() { # DIR — everything directly inside DIR
  [[ -d $1 && ! -L $1 ]] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -print 2>/dev/null
}
old_versions() { # DIR [NAME_GLOB] — every version folder except the newest
  [[ -d $1 && ! -L $1 ]] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -type d -name "${2:-*}" -printf '%T@\t%p\n' 2>/dev/null |
    sort -rn | tail -n +2 | cut -f2-
}

ai_safe_path() { # refuse anything that is not clearly disposable
  local p=$1 base=${1##*/}
  [[ $p == "$HOME"/?* && ! -L $p ]] || return 1
  is_protected "$p" && return 1
  [[ $p == */memory || $p == */memory/* ]] && return 1 # Claude Code memory
  case $base in
    .credentials.json | auth.json | oauth_creds.json | *credential* | *token* | settings.json | \
      config.json | config.toml | *.pem | *.key | memories*.sqlite) return 1 ;;
    plugins | skills | agents | commands) [[ $p == */.tmp/* ]] || return 1 ;; # only temporary copies
  esac
  return 0
}

list_paths() { # ID → existing, safe paths
  local p
  "${LIST_FN[$1]}" | sort -u | while IFS= read -r p; do
    [[ -n $p && -e $p ]] && ai_safe_path "$p" && printf '%s\n' "$p"
  done
}

list_scan() {
  local r present=0 paths
  while IFS= read -r r; do [[ -n $r && -e $r ]] && present=1; done <<<"${LIST_ROOTS[$1]}"
  ((present)) || return 1 # tool not installed
  mapfile -t paths < <(list_paths "$1")
  ((${#paths[@]})) || return 2
  SCAN_BYTES=$(du_sum "${paths[@]}")
  ((SCAN_BYTES > 0)) || return 2
  SCAN_NOTE=$(plural ${#paths[@]} "${LIST_NOUN[$1]}")
  [[ ${ITEM_DESC[$1]} == *"older than"* ]] && SCAN_NOTE+=" · older than ${AI_HISTORY_DAYS}d"
  return 0
}

list_clean() {
  local p
  while IFS= read -r p; do
    ai_safe_path "$p" || continue # checked again right before deleting
    run rm -rf -- "$p"
  done < <(list_paths "$1")
}

list_details() {
  local p
  list_paths "$1" | while IFS= read -r p; do printf '%s\t%s\n' "$(du_sum "$p")" "$p"; done | detail_files 60
  return 0
}

list_precheck() { # the tool is running: skip when unattended, otherwise ask
  pgrep -x "${ITEM_PROCS[$1]}" >/dev/null 2>&1 || return 0
  if ((ASSUME_YES)); then warn "Skipping ${ITEM_LABEL[$1]}: the app is running."; return 1; fi
  ui_confirm "${ITEM_LABEL[$1]%% —*} is running" \
    "Only old sessions and rebuildable caches are removed. Continue?" "${LIST_RUN_DEFAULT[$1]:-y}"
}

reg_list_item() { # ID LABEL DEFAULT NOUN DESCRIPTION LIST_FN ROOTS [PROCESS_REGEX] [RUNNING_DEFAULT]
  local id=$1
  [[ $id =~ ^[a-z0-9_]+$ ]] || return 1
  reg "$id" ai "$2" "$3" "$5"
  LIST_NOUN[$id]=$4 LIST_FN[$id]=$6 LIST_ROOTS[$id]=$7 ITEM_PROCS[$id]=${8:-} LIST_RUN_DEFAULT[$id]=${9:-y}
  eval "scan_$id() { list_scan $id; }
        clean_$id() { list_clean $id; }
        details_$id() { list_details $id; }"
  [[ -n ${8:-} ]] && eval "precheck_$id() { list_precheck $id; }"
  return 0
}

# Claude Code (CLI)
ai_claude_cache() {
  contents "$HOME/.claude/cache"; contents "$HOME/.cache/claude-cli-nodejs"
  contents "$HOME/.claude/debug"; contents "$HOME/.claude/statsig"
  aged "$HOME/.claude/shell-snapshots" 7; aged "$HOME/.claude/backups" 7
}
ai_claude_history() { # a transcript goes together with its tool-output folder
  local j
  for j in "$HOME"/.claude/projects/*/*.jsonl; do
    [[ -f $j && -n $(find "$j" -mtime +"$AI_HISTORY_DAYS" -print 2>/dev/null) ]] || continue
    printf '%s\n' "$j"
    [[ -d ${j%.jsonl} ]] && printf '%s\n' "${j%.jsonl}"
  done
  aged "$HOME/.claude/file-history" "$AI_HISTORY_DAYS"
  aged "$HOME/.claude/todos" "$AI_HISTORY_DAYS"
  aged "$HOME/.claude/session-env" "$AI_HISTORY_DAYS"
}
# Claude Desktop
ai_claude_desktop_cache() {
  old_versions "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude-code"
  contents "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/Crashpad/completed"
}
ai_claude_desktop_history() {
  aged "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/local-agent-mode-sessions" "$AI_HISTORY_DAYS"
  aged "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude-code-sessions" "$AI_HISTORY_DAYS"
}
# Codex
ai_codex_cache() {
  local f
  contents "$HOME/.codex/.tmp"; contents "$HOME/.codex/tmp"; aged "$HOME/.codex/log" 3
  for f in "$HOME"/.codex/logs_*.sqlite "$HOME"/.codex/logs_*.sqlite-wal "$HOME"/.codex/logs_*.sqlite-shm; do
    [[ -f $f ]] && printf '%s\n' "$f"
  done
}
ai_codex_history() {
  local d
  for d in "$HOME/.codex/sessions" "$HOME/.codex/archived_sessions"; do
    [[ -d $d ]] && find "$d" -type f -name '*.jsonl' -mtime +"$AI_HISTORY_DAYS" -print 2>/dev/null
  done
}
# Gemini CLI & Antigravity
ai_gemini_cache() {
  local a
  aged "$HOME/.gemini/logs" 3
  for a in "$HOME/.gemini/antigravity" "$HOME/.gemini/antigravity-ide"; do
    contents "$a/crashes"; aged "$a/log" 3
  done
}
ai_gemini_history() {
  local a
  for a in "$HOME/.gemini/antigravity" "$HOME/.gemini/antigravity-ide"; do
    aged "$a/conversations" "$AI_HISTORY_DAYS"; aged "$a/brain" "$AI_HISTORY_DAYS"
    aged "$a/html_artifacts" "$AI_HISTORY_DAYS"
  done
  aged "$HOME/.gemini/tmp" "$AI_HISTORY_DAYS"
}
# opencode
ai_opencode_cache() { contents "$HOME/.cache/opencode"; }
ai_opencode_history() { aged "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/snapshot" "$AI_HISTORY_DAYS"; }
# Zed
ai_zed_cache() {
  local a
  contents "${XDG_DATA_HOME:-$HOME/.local/share}/zed/hang_traces"
  for a in "${XDG_DATA_HOME:-$HOME/.local/share}"/zed/external_agents/registry/*/; do old_versions "${a%/}" 'v_*'; done
}
ai_zed_downloads() {
  local z=${XDG_DATA_HOME:-$HOME/.local/share}/zed
  find "$z/external_agents/registry" -mindepth 1 -maxdepth 1 -type d -not -name icons -print 2>/dev/null
  contents "$z/languages"
}
# GitHub Copilot CLI & Continue
ai_misc_cache() { aged "$HOME/.copilot/logs" 3; contents "$HOME/.continue/index"; }
ai_misc_history() { aged "$HOME/.copilot/session-state" "$AI_HISTORY_DAYS"; aged "$HOME/.continue/sessions" "$AI_HISTORY_DAYS"; }

_c=${XDG_CONFIG_HOME:-$HOME/.config} _d=${XDG_DATA_HOME:-$HOME/.local/share}
reg_list_item ai_claude_cache "Claude Code — cache & logs" 1 item \
  "Claude Code caches, MCP logs, week-old shell snapshots and backups. Memory, settings and logins are kept." \
  ai_claude_cache "$HOME/.claude" claude
reg_list_item ai_claude_history "Claude Code — old sessions" 0 item \
  "Session transcripts, checkpoints and todos older than 30 days. Memory, settings and logins are kept." \
  ai_claude_history "$HOME/.claude" claude
reg_list_item ai_claude_desktop_cache "Claude Desktop — old versions" 1 item \
  "Previous bundled Claude Code versions and crash dumps of the Claude desktop app." \
  ai_claude_desktop_cache "$_c/Claude" claude-desktop
reg_list_item ai_claude_desktop_history "Claude Desktop — old sessions" 0 session \
  "Agent-mode sessions of the Claude desktop app older than 30 days." \
  ai_claude_desktop_history "$_c/Claude" claude-desktop
reg_list_item ai_codex_cache "Codex — cache & logs" 1 item \
  "Codex's temporary plugin cache and log database; both are recreated." \
  ai_codex_cache "$HOME/.codex" codex n
reg_list_item ai_codex_history "Codex — old sessions" 0 session \
  "Codex session transcripts older than 30 days. Memories and settings are kept." \
  ai_codex_history "$HOME/.codex" codex
reg_list_item ai_gemini_cache "Gemini/Antigravity — logs" 1 item \
  "Logs and crash dumps of Gemini CLI and Antigravity." \
  ai_gemini_cache "$HOME/.gemini" 'antigravity|gemini'
reg_list_item ai_gemini_history "Gemini/Antigravity — old chats" 0 item \
  "Antigravity conversations and agent workspaces (brain), and Gemini CLI checkpoints, older than 30 days." \
  ai_gemini_history "$HOME/.gemini" 'antigravity|gemini'
reg_list_item ai_opencode_cache "opencode — cache" 1 item "opencode's download cache." \
  ai_opencode_cache "$_d/opencode
$HOME/.cache/opencode" opencode
reg_list_item ai_opencode_history "opencode — old undo snapshots" 0 snapshot \
  "Undo snapshots of opencode sessions older than 30 days. Sessions in opencode.db are kept." \
  ai_opencode_history "$_d/opencode" opencode
reg_list_item ai_zed_cache "Zed — hang traces & old agents" 1 item \
  "Older versions of AI agents Zed downloaded (the newest is kept), and hang traces." \
  ai_zed_cache "$_d/zed" 'zed|zed-editor'
reg_list_item ai_zed_downloads "Zed — agents & language servers" 0 item \
  "All AI agents and language servers Zed downloaded. Zed downloads them again when needed." \
  ai_zed_downloads "$_d/zed" 'zed|zed-editor' n
reg_list_item ai_misc_cache "Copilot & Continue — cache" 1 item "Copilot CLI logs and Continue's code index." \
  ai_misc_cache "$HOME/.copilot
$HOME/.continue"
reg_list_item ai_misc_history "Copilot & Continue — sessions" 0 session \
  "Copilot CLI and Continue sessions older than 30 days." \
  ai_misc_history "$HOME/.copilot
$HOME/.continue"
unset _c _d

# Files under ~/.cache untouched for 30+ days, excluding caches handled elsewhere.
app_cache_find() {
  # Exclude with -path tests, not -prune: -delete implies -depth, which disables -prune.
  local ex=(thumbnails pip go-build yarn pnpm mozilla google-chrome chromium BraveSoftware
    microsoft-edge vivaldi opera huggingface lm-studio) skip=() e # AI models are items of their own
  for e in "${ex[@]}"; do skip+=(-path "$HOME/.cache/$e/*" -o); done
  unset 'skip[-1]'
  find "$HOME/.cache" -type f -not \( "${skip[@]}" \) -mtime +"$CACHE_DAYS" -atime +"$CACHE_DAYS" "$@" 2>/dev/null
}
scan_app_cache() {
  [[ -d $HOME/.cache ]] || return 1
  local n
  read -r n SCAN_BYTES < <(app_cache_find -printf '%s\n' | count_sum)
  SCAN_NOTE="$(plural "$n" file) in ~/.cache"
  ((SCAN_BYTES > 0)) || return 2
}
clean_app_cache() {
  if ((DRY_RUN)); then run find "$HOME/.cache" -type f -mtime +"$CACHE_DAYS" -atime +"$CACHE_DAYS" -delete "(excluding browser/dev caches)"
  else log "app_cache_find -delete"; app_cache_find -delete || true; fi
}
details_app_cache() { # grouped per application folder
  app_cache_find -printf '%s\t%P\n' |
    awk -F'\t' -v h="$HOME" '{split($2, a, "/"); s[a[1]] += $1} END {for (k in s) print s[k] "\t" h "/.cache/" k}' |
    detail_files 30
}

# ── Developer ──

NM_DAYS=90
NM_LIST="$LOG_DIR/stale-node-modules.tsv"
# A project counts only with package.json AND a lockfile (installed apps ship
# node_modules without lockfiles), and when nothing at its top level changed
# for NM_DAYS.
nm_is_stale() { # NODE_MODULES_DIR
  local p=${1%/node_modules} lock has_lock=0
  [[ ${1##*/} == node_modules && -d $1 && ! -L $1 && -f $p/package.json ]] || return 1
  for lock in package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock npm-shrinkwrap.json; do
    [[ -f $p/$lock ]] && has_lock=1
  done
  ((has_lock)) || return 1
  [[ -z $(find "$p" -mindepth 1 -maxdepth 1 -not -name node_modules -mtime -"$NM_DAYS" -print -quit 2>/dev/null) ]]
}
find_stale_node_modules() { # bytes<TAB>path of stale node_modules
  local d
  find "$HOME" -xdev \( -path "$HOME/.*" -o -path "$HOME/snap" -o -path "$HOME/Applications" \
    -o -path '*/resources/app' -o -name .git \) -prune -o -type d -name node_modules -prune -print 2>/dev/null |
    while IFS= read -r d; do
      nm_is_stale "$d" && printf '%s\t%s\n' "$(du -sb -- "$d" 2>/dev/null | cut -f1)" "$d"
    done
  return 0 # unreadable folders make find fail; the list is still valid
}
scan_node_modules() {
  have node || have npm || return 1
  mkdir -p "$LOG_DIR" || return 1
  { find_stale_node_modules; true; } | sort -t$'\t' -k1,1rn >"$NM_LIST.tmp"; mv -f "$NM_LIST.tmp" "$NM_LIST"
  local n
  n=$(wc -l <"$NM_LIST")
  SCAN_BYTES=$(cut -f1 "$NM_LIST" | sum_lines)
  SCAN_NOTE="$(plural "$n" project) idle for ${NM_DAYS}+ days"
  ((n > 0)) || return 2
}
clean_node_modules() {
  local b d
  while IFS=$'\t' read -r b d; do
    nm_is_stale "$d" || continue # re-check: the project may have been used since the scan
    is_protected "$d" && continue
    run rm -rf -- "$d"
  done <"$NM_LIST"
}
details_node_modules() { [[ -f $NM_LIST ]] && detail_files 100 <"$NM_LIST"; }

dev_scan() { # NOTE PATH...
  local note=$1; shift
  local p any=0
  for p in "$@"; do [[ -e $p ]] && any=1; done
  ((any)) || return 1
  SCAN_BYTES=$(du_sum "$@")
  SCAN_NOTE=$note
  ((SCAN_BYTES > 0)) || return 2
}

NPM_PATHS=("$HOME/.npm/_cacache")
scan_npm() { dev_scan "~/.npm/_cacache" "${NPM_PATHS[@]}"; }
clean_npm() { if have npm; then run npm cache clean --force; else empty_dir "${NPM_PATHS[0]}"; fi; }
details_npm() { detail_paths "${NPM_PATHS[@]}"; }

YARN_PATHS=("$HOME/.cache/yarn" "$HOME/.yarn/berry/cache")
scan_yarn() { dev_scan "~/.cache/yarn" "${YARN_PATHS[@]}"; }
clean_yarn() { local p; for p in "${YARN_PATHS[@]}"; do empty_dir "$p"; done; }
details_yarn() { detail_paths "${YARN_PATHS[@]}"; }

PNPM_PATHS=("${XDG_DATA_HOME:-$HOME/.local/share}/pnpm/store")
scan_pnpm() { have pnpm || return 1; dev_scan "store size; prune keeps used packages" "${PNPM_PATHS[@]}"; }
clean_pnpm() { run pnpm store prune; }
details_pnpm() { detail_paths "${PNPM_PATHS[@]}"; }

BUN_PATHS=("$HOME/.bun/install/cache")
scan_bun() { dev_scan "~/.bun/install/cache" "${BUN_PATHS[@]}"; }
clean_bun() { if have bun; then run bun pm cache rm; else empty_dir "${BUN_PATHS[0]}"; fi; }
details_bun() { detail_paths "${BUN_PATHS[@]}"; }

PIP_PATHS=("$HOME/.cache/pip")
scan_pip() { dev_scan "~/.cache/pip" "${PIP_PATHS[@]}"; }
clean_pip() { empty_dir "${PIP_PATHS[0]}"; }
details_pip() { detail_paths "${PIP_PATHS[@]}"; }

GO_PATHS=("$HOME/.cache/go-build")
scan_gobuild() { dev_scan "~/.cache/go-build" "${GO_PATHS[@]}"; }
clean_gobuild() { if have go; then run go clean -cache; else empty_dir "${GO_PATHS[0]}"; fi; }
details_gobuild() { detail_paths "${GO_PATHS[@]}"; }

CARGO_PATHS=("$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/src")
scan_cargo() { dev_scan "~/.cargo/registry" "${CARGO_PATHS[@]}"; }
clean_cargo() { local p; for p in "${CARGO_PATHS[@]}"; do empty_dir "$p"; done; }
details_cargo() { detail_paths "${CARGO_PATHS[@]}"; }

GRADLE_PATHS=("$HOME/.gradle/caches")
scan_gradle() { dev_scan "~/.gradle/caches" "${GRADLE_PATHS[@]}"; }
clean_gradle() { empty_dir "${GRADLE_PATHS[0]}"; }
details_gradle() { detail_paths "${GRADLE_PATHS[@]}"; }

MAVEN_PATHS=("$HOME/.m2/repository")
scan_maven() { dev_scan "~/.m2/repository" "${MAVEN_PATHS[@]}"; }
clean_maven() { empty_dir "${MAVEN_PATHS[0]}"; }
details_maven() { detail_paths "${MAVEN_PATHS[@]}"; }

si_to_bytes() { local v=${1%B}; v=${v/k/K}; numfmt --from=si "$v" 2>/dev/null || echo 0; }
# Docker: one item per kind of leftover, sized from `docker system df`.
docker_ok() { have docker && timeout 5 docker info >/dev/null 2>&1; }
docker_reclaimable() { # TYPE (Images, Containers, Local Volumes, Build Cache) → bytes
  local t r
  while IFS=$'\t' read -r t r; do
    [[ $t == "$1" ]] && si_to_bytes "${r%% *}" && return
  done < <(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null)
  echo 0
}
docker_scan() { # BYTES NOTE
  SCAN_BYTES=${1:-0} SCAN_NOTE=$2
  ((SCAN_BYTES > 0)) || return 2
}

scan_docker_dangling() {
  docker_ok || return 1
  local sizes n b=0 v
  mapfile -t sizes < <(docker images -f dangling=true --format '{{.Size}}' 2>/dev/null)
  for v in "${sizes[@]}"; do b=$((b + $(si_to_bytes "$v"))); done
  n=${#sizes[@]}
  docker_scan "$b" "$(plural "$n" image)"
}
clean_docker_dangling() { run docker image prune -f; }
details_docker_dangling() { docker images -f dangling=true --format '  {{.Size}}\t{{.ID}}  created {{.CreatedSince}}' 2>/dev/null; return 0; }

scan_docker_build() { docker_ok || return 1; docker_scan "$(docker_reclaimable "Build Cache")" "BuildKit cache"; }
clean_docker_build() { run docker builder prune -f; }
details_docker_build() { docker system df 2>/dev/null | sed 's/^/  /'; return 0; }

scan_docker_containers() {
  docker_ok || return 1
  local n
  n=$(docker ps -aq -f status=exited -f status=created -f status=dead 2>/dev/null | wc -l)
  docker_scan "$(docker_reclaimable Containers)" "$(plural "$n" container)"
  ((n > 0)) && return 0 || return 2
}
clean_docker_containers() { run docker container prune -f; }
details_docker_containers() {
  docker ps -a -f status=exited -f status=created -f status=dead \
    --format '  {{.Names}}  ({{.Image}}) — {{.Status}}' 2>/dev/null
  return 0
}

scan_docker_images() { docker_ok || return 1; docker_scan "$(docker_reclaimable Images)" "not used by any container"; }
clean_docker_images() { run docker image prune -a -f; }
details_docker_images() { docker images --format '  {{.Size}}\t{{.Repository}}:{{.Tag}}' 2>/dev/null; return 0; }

scan_docker_volumes() {
  docker_ok || return 1
  local n
  n=$(docker volume ls -qf dangling=true 2>/dev/null | wc -l)
  docker_scan "$(docker_reclaimable "Local Volumes")" "$(plural "$n" volume) — may contain data"
  ((n > 0)) && return 0 || return 2
}
clean_docker_volumes() { run docker volume prune -f; }
details_docker_volumes() { docker volume ls -f dangling=true --format '  {{.Name}}  ({{.Driver}})' 2>/dev/null; return 0; }

# Conda: downloaded archives in pkgs/ plus the index cache — what `conda clean --tarballs
# --index-cache` frees. Extracted packages stay: removing them can break softlinked envs.
CONDA_ROOTS=("$HOME/miniconda3" "$HOME/anaconda3" "$HOME/miniforge3" "$HOME/mambaforge")
conda_bin() {
  local c
  for c in "${CONDA_ROOTS[@]/%//bin/conda}" "$(command -v conda 2>/dev/null)"; do # your own install first
    [[ -n $c && -x $c ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
conda_pkgs_dirs() {
  local d
  for d in "${CONDA_ROOTS[@]/%//pkgs}" "$HOME/.conda/pkgs"; do [[ -d $d && ! -L $d ]] && printf '%s\n' "$d"; done
  return 0
}
conda_archives() { # bytes<TAB>path of downloaded package archives
  local dirs
  mapfile -t dirs < <(conda_pkgs_dirs)
  ((${#dirs[@]})) || return 0
  find "${dirs[@]}" -maxdepth 1 -type f \( -name '*.conda' -o -name '*.tar.bz2' \) -printf '%s\t%p\n' 2>/dev/null
}
scan_conda() {
  conda_bin >/dev/null || return 1
  local n b dirs
  mapfile -t dirs < <(conda_pkgs_dirs)
  read -r n b < <(conda_archives | cut -f1 | count_sum)
  SCAN_BYTES=$((b + $(du_sum "${dirs[@]/%//cache}")))
  SCAN_NOTE="$(plural "$n" "package archive")"
  ((SCAN_BYTES > 0)) || return 2
}
clean_conda() { run "$(conda_bin)" clean --tarballs --index-cache --logfiles -y; } # not --packages: it can break softlinked envs
details_conda() { conda_archives | detail_files 30; }

# Podman: like `docker system prune`, without volumes or tagged images. Only asked when
# you've used it: `podman info` creates its storage folders, and a scan must change nothing.
podman_ok() { have podman && [[ -d ${XDG_DATA_HOME:-$HOME/.local/share}/containers ]] && timeout 5 podman info >/dev/null 2>&1; }
scan_podman() {
  podman_ok || return 1
  local sizes v b=0 c
  mapfile -t sizes < <(podman images -f dangling=true --format '{{.Size}}' 2>/dev/null)
  for v in "${sizes[@]}"; do b=$((b + $(si_to_bytes "${v// /}"))); done
  c=$(podman ps -aq -f status=exited -f status=created 2>/dev/null | wc -l)
  SCAN_BYTES=$b SCAN_NOTE="$(plural ${#sizes[@]} "dangling image"), $(plural "$c" "stopped container")"
  ((${#sizes[@]} + c > 0)) || return 2
}
clean_podman() { run podman system prune -f; }
details_podman() {
  podman images -f dangling=true --format '  {{.Size}}  {{.ID}}  created {{.CreatedSince}}' 2>/dev/null
  podman ps -a -f status=exited -f status=created --format '  {{.Names}}  ({{.Image}}) — {{.Status}}' 2>/dev/null
  return 0
}

# ── AI models: one item per downloaded model ──
#
# Models take gigabytes each and are slow to download again, so every model is
# an item of its own: never pre-selected, never cleaned by automatic cleaning
# (it only cleans user & developer junk), and a tick is not remembered for the
# next scan (ITEM_ONCE). Ollama models are removed with `ollama rm` because
# models share layers; Hugging Face and LM Studio models are folders.

declare -A ITEM_ONCE=() MODEL_KIND=() MODEL_REF=()
HF_HUB=${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}
LMS_DIRS=("$HOME/.lmstudio/models" "$HOME/.cache/lm-studio/models")

ollama_models() { # name<TAB>bytes, as the Ollama server reports them
  have ollama || return 0
  local n s1 s2
  timeout 2 ollama list 2>/dev/null | awk 'NR > 1 && NF >= 4 {print $1, $3, $4}' |
    while read -r n s1 s2; do printf '%s\t%s\n' "$n" "$(si_to_bytes "$s1$s2")"; done
}

model_safe_path() { # only a real model folder exactly where a model store keeps them — no symlinks on the way
  local p=$1 rp store d
  [[ -d $p && ! -L $p && ! -L ${p%/*} ]] && ! is_protected "$p" || return 1
  rp=$(realpath -e -- "$p" 2>/dev/null) || return 1
  [[ $rp == "$p" ]] || return 1 # a symlink anywhere in the path (e.g. models/mine → ~) points elsewhere
  if [[ ${p##*/} == models--* ]]; then
    store=$(realpath -e -- "$HF_HUB" 2>/dev/null) && [[ ${rp%/*} == "$store" ]] && return 0
  fi
  for d in "${LMS_DIRS[@]}"; do
    store=$(realpath -e -- "$d" 2>/dev/null) || continue
    [[ ${rp%/*/*} == "$store" && ${p%/*/*} == "$d" ]] && return 0 # <store>/<publisher>/<model>
  done
  return 1
}

model_scan() {
  local ref=${MODEL_REF[$1]} b
  case ${MODEL_KIND[$1]} in
    ollama)
      b=$(ollama_models | awk -F'\t' -v n="$ref" '$1 == n {print $2; exit}')
      [[ -n $b ]] || return 1
      SCAN_BYTES=$b SCAN_NOTE="get it back with: ollama pull $ref" ;;
    *)
      model_safe_path "$ref" || return 1
      SCAN_BYTES=$(du_sum "$ref") SCAN_NOTE=${ref/#$HOME/\~} ;;
  esac
  ((SCAN_BYTES > 0)) || return 2
}
model_clean() {
  local ref=${MODEL_REF[$1]}
  case ${MODEL_KIND[$1]} in
    ollama) run ollama rm "$ref" ;;
    *)
      model_safe_path "$ref" || { err "Not a model folder, skipped: $ref"; return 1; }
      run rm -rf -- "$ref" ;;
  esac
}
model_details() {
  local ref=${MODEL_REF[$1]}
  case ${MODEL_KIND[$1]} in
    ollama) timeout 5 ollama show "$ref" 2>/dev/null | sed 's/^/  /' | head -n 25 ;;
    *) detail_paths "$ref" ;;
  esac
  return 0
}
model_precheck() { # LM Studio may have the model loaded
  [[ ${MODEL_KIND[$1]} == lms ]] && pgrep -xi 'lm-studio|lm studio|lms' >/dev/null 2>&1 || return 0
  if ((ASSUME_YES)); then warn "Skipping ${ITEM_LABEL[$1]}: LM Studio is running."; return 1; fi
  ui_confirm "LM Studio is running" "Eject the model in LM Studio first. Delete it anyway?" n
}

reg_model_item() { # KIND REF LABEL DESCRIPTION
  local id="model_${1}_${3#* — }" sum
  id=${id,,}; id=${id//[^a-z0-9_]/_}
  sum=$(printf '%s' "$2" | cksum | cut -d' ' -f1)
  id="${id:0:48}_$sum" # the checksum of the exact path/name keeps ids from swapping between scan and clean
  while [[ -n ${ITEM_CAT[$id]:-} ]]; do id+=_; done
  reg "$id" models "$3" 0 "$4"
  MODEL_KIND[$id]=$1 MODEL_REF[$id]=$2 ITEM_ONCE[$id]=1
  eval "scan_$id() { model_scan $id; }
        clean_$id() { model_clean $id; }
        details_$id() { model_details $id; }
        precheck_$id() { model_precheck $id; }"
}

discover_models() {
  local n _b d m name
  while IFS=$'\t' read -r n _b; do
    [[ -n $n ]] && reg_model_item ollama "$n" "Ollama — $n" \
      "A model Ollama downloaded. Removed with 'ollama rm'; layers other models use are kept."
  done < <(ollama_models)
  for d in "$HF_HUB"/models--*/; do
    d=${d%/}
    model_safe_path "$d" || continue
    name=${d##*/models--}
    reg_model_item hf "$d" "Hugging Face — ${name//--//}" \
      "A model in the Hugging Face cache. Python code downloads it again the next time it is used."
  done
  for d in "${LMS_DIRS[@]}"; do
    for m in "$d"/*/*/; do
      m=${m%/}
      model_safe_path "$m" || continue
      name=${m#"$d"/}
      reg_model_item lms "$m" "LM Studio — $name" \
        "A model downloaded in LM Studio. Download it again from LM Studio's Discover tab."
    done
  done
  return 0
}
discover_models

# ───────────────────────────── preferences & stats ──────────────────────────

PREF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/clean-my-ubuntu/selection"
STATS_FILE="$LOG_DIR/stats"
declare -A PREF=() STATS=()

load_kv() { # FILE ASSOC_NAME VALUE_REGEX
  local -n _map=$2
  local k v
  [[ -f $1 ]] || return 0
  while IFS='=' read -r k v; do
    [[ $k =~ ^[a-z_]+$ && $v =~ $3 ]] && _map[$k]=$v
  done <"$1"
}

save_prefs() {
  local k
  mkdir -p "${PREF_FILE%/*}" || return
  for k in "${!PREF[@]}"; do printf '%s=%s\n' "$k" "${PREF[$k]}"; done | sort >"$PREF_FILE"
}

record_cleanup() { # BYTES_FREED
  ((DRY_RUN)) && return
  STATS[lifetime]=$((${STATS[lifetime]:-0} + $1))
  STATS[runs]=$((${STATS[runs]:-0} + 1))
  STATS[last_time]=$EPOCHSECONDS
  STATS[last_freed]=$1
  mkdir -p "$LOG_DIR" || return
  local k
  for k in lifetime runs last_time last_freed; do printf '%s=%s\n' "$k" "${STATS[$k]}"; done >"$STATS_FILE"
  if [[ -f $LOG_FILE ]] && (($(wc -l <"$LOG_FILE") > 2000)); then # keep our own log small
    tail -n 1000 "$LOG_FILE" >"$LOG_FILE.tmp" && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

agov() { # VAR EPOCH → "just now" / "5 min ago" / "3 h ago" / "2 days ago"
  local s=$((EPOCHSECONDS - $2))
  if ((s < 60)); then printf -v "$1" 'just now'
  elif ((s < 3600)); then printf -v "$1" '%d min ago' $((s / 60))
  elif ((s < 86400)); then printf -v "$1" '%d h ago' $((s / 3600))
  else printf -v "$1" '%d days ago' $((s / 86400)); fi
}
ago() { local __a; agov __a "$1"; printf '%s' "$__a"; }

# ───────────────────────────── sudo ─────────────────────────────────────────

sudo_auth() { # REASON — ask for the sudo password
  if ((UI_ACTIVE)); then
    frame_begin; draw_header "Administrator access"; fl ""
    fl "  ${BOLD}🔒 Administrator password required${NC}"
    fl "  ${DIM}$1${NC}"
    fl ""
    frame_flush
    printf '\n'
    term_raw_on
    sudo -v -p "  Password for %p: "
    local rc=$?
    term_raw_off
    return "$rc"
  fi
  info "$1"
  sudo -v
}

ensure_sudo() { # [REASON]
  ((EUID == 0 || DRY_RUN)) && return 0
  sudo -n true 2>/dev/null && return 0
  [[ -t 0 ]] || return 1 # unattended: no password prompt
  sudo_auth "${1:-This task changes system files.}"
}

offer_sudo_for_scan() {
  ((EUID == 0 || SUDO_ASKED)) && return 0
  SUDO_ASKED=1
  sudo -n true 2>/dev/null && return 0
  ui_confirm "Scan system folders with sudo?" "Gives exact sizes for root-owned logs and caches." y &&
    { sudo_auth "Used to measure root-owned folders. Nothing is changed during a scan." || toast "${YELLOW}!${NC} Continuing without sudo — system sizes may be low."; }
  return 0
}

# ───────────────────────────── last-scan cache ──────────────────────────────
#
# Results of the latest scan per item, so the main menu can show what was
# found (and when) without scanning again.

SCAN_CACHE_FILE="$LOG_DIR/last-scan.tsv"
declare -A LAST_RC=() LAST_BYTES=() LAST_AT=()

load_scan_cache() {
  local id rc b t
  [[ -f $SCAN_CACHE_FILE ]] || return 0
  while IFS=$'\t' read -r id rc b t; do
    [[ $id =~ ^[a-z0-9_]+$ && $rc =~ ^[0-9]$ && $b =~ ^[0-9]+$ && $t =~ ^[0-9]+$ && -n ${ITEM_CAT[$id]:-} ]] || continue
    LAST_RC[$id]=$rc LAST_BYTES[$id]=$b LAST_AT[$id]=$t
  done <"$SCAN_CACHE_FILE"
}

save_scan_cache() { # record RES_* for SCANNED; forget items of those categories that vanished
  local id c
  for id in "${!LAST_RC[@]}"; do
    for c in "${SCAN_CATS[@]}"; do
      [[ ${ITEM_CAT[$id]:-} == "$c" ]] && unset "LAST_RC[$id]" "LAST_BYTES[$id]" "LAST_AT[$id]"
    done
  done
  for id in "${SCANNED[@]}"; do
    LAST_RC[$id]=${RES_RC[$id]} LAST_BYTES[$id]=${RES_BYTES[$id]} LAST_AT[$id]=$EPOCHSECONDS
  done
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  for id in "${!LAST_RC[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "$id" "${LAST_RC[$id]}" "${LAST_BYTES[$id]}" "${LAST_AT[$id]}"
  done >"$SCAN_CACHE_FILE" 2>/dev/null
  return 0
}

ago_short() { # VAR EPOCH → now / 5m / 3h / 2d
  local s=$((EPOCHSECONDS - $2))
  if ((s < 60)); then printf -v "$1" 'now'
  elif ((s < 3600)); then printf -v "$1" '%dm ago' $((s / 60))
  elif ((s < 86400)); then printf -v "$1" '%dh ago' $((s / 3600))
  else printf -v "$1" '%dd ago' $((s / 86400)); fi
}

cat_badge() { # CATEGORY... → BADGE: what the last scan found there (empty if unknown or > 7 days old)
  local id c tot=0 n=0 oldest=0 hit=0 sz age clr
  BADGE=""
  for id in "${!LAST_RC[@]}"; do
    for c in "$@"; do
      [[ ${ITEM_CAT[$id]:-} == "$c" ]] || continue
      hit=1
      ((oldest == 0 || LAST_AT[$id] < oldest)) && oldest=${LAST_AT[$id]}
      ((LAST_RC[$id] == 0)) && { tot=$((tot + LAST_BYTES[$id])); ((++n)); }
    done
  done
  ((hit && EPOCHSECONDS - oldest < 7 * 86400)) || return 0
  ago_short age "$oldest"
  if [[ $* == privacy ]]; then
    if ((n)); then BADGE="${YELLOW}$n to clear${NC} ${DIM}· $age${NC}"; else BADGE="${GREEN}✓ clear${NC} ${DIM}· $age${NC}"; fi
  elif ((tot > 0)); then
    humanv sz "$tot"; size_colorv clr "$tot"
    BADGE="$clr$sz${NC} ${DIM}· $age${NC}"
  else BADGE="${GREEN}✓ clean${NC} ${DIM}· $age${NC}"; fi
  return 0
}

# ───────────────────────────── free-space history ───────────────────────────

DISK_HISTORY="$LOG_DIR/disk-history.tsv" # day<TAB>free bytes on /<TAB>size of /

record_disk_usage() { # one row per day (the latest reading of the day wins), last 400 days
  local size avail today
  read -r size avail < <(df -B1 --output=size,avail / 2>/dev/null | tail -n 1)
  [[ $avail =~ ^[0-9]+$ ]] || return 0
  printf -v today '%(%Y-%m-%d)T' -1
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  {
    [[ -f $DISK_HISTORY ]] && grep -v "^$today"$'\t' "$DISK_HISTORY" | tail -n 399
    printf '%s\t%s\t%s\n' "$today" "$avail" "$size"
  } >"$DISK_HISTORY.tmp" 2>/dev/null && mv -f "$DISK_HISTORY.tmp" "$DISK_HISTORY"
  return 0
}

sparkline() { # VAR VALUE... → ▁▂▃▅▇ (lowest to highest)
  local -n __sp=$1
  shift
  local blocks=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █) v min=$1 max=$1
  for v in "$@"; do ((v < min)) && min=$v; ((v > max)) && max=$v; done
  __sp=""
  for v in "$@"; do
    if ((max == min)); then __sp+=${blocks[3]}; else __sp+=${blocks[(v - min) * 7 / (max - min)]}; fi
  done
}

disk_history_lines() { # for System Overview
  local rows=() r d a first_d first_a last_d last_a days vals=() spark per_week weeks h1 h2 h3
  [[ -f $DISK_HISTORY ]] && mapfile -t rows < <(tail -n 30 "$DISK_HISTORY")
  printf '\n  %sFree space history%s\n' "$BOLD" "$NC"
  if ((${#rows[@]} < 2)); then
    printf '  %sRecorded once a day while you use the app — check back in a few days.%s\n' "$DIM" "$NC"
    return 0
  fi
  for r in "${rows[@]}"; do IFS=$'\t' read -r d a _ <<<"$r"; vals+=("$a"); done
  IFS=$'\t' read -r first_d first_a _ <<<"${rows[0]}"
  IFS=$'\t' read -r last_d last_a _ <<<"${rows[-1]}"
  sparkline spark "${vals[@]}"
  humanv h1 "$first_a"; humanv h2 "$last_a"
  printf '  %s%s%s  %s free on %s → %s on %s\n' "$ACCENT" "$spark" "$NC" "$h1" "$first_d" "$h2" "$last_d"
  days=$((($(date -d "$last_d" +%s) - $(date -d "$first_d" +%s)) / 86400))
  ((days > 0)) || return 0
  per_week=$(((last_a - first_a) * 7 / days))
  if ((per_week < -104857600)); then # losing more than 100 MB a week
    humanv h3 $((-per_week))
    weeks=$((last_a / -per_week))
    printf '  %sLosing about %s a week%s %s— at this rate / is full in ~%d weeks.%s\n' "$YELLOW" "$h3" "$NC" "$DIM" "$weeks" "$NC"
  elif ((per_week > 104857600)); then
    humanv h3 "$per_week"
    printf '  %sGaining about %s a week.%s\n' "$GREEN" "$h3" "$NC"
  else
    printf '  %sStable over the last %d days.%s\n' "$GREEN" "$days" "$NC"
  fi
}

# ───────────────────────────── scan engine ──────────────────────────────────

declare -A RES_BYTES RES_NOTE RES_RC RES_HUMAN SEL SCAN_GOT
SCAN_TIMEOUT=120

kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }

now_ms() { local t=${EPOCHREALTIME/[.,]/}; echo $((t / 1000)); }

fs_avail() { # free bytes on the filesystems holding / and $HOME
  df -B1 --output=avail,target / "$HOME" 2>/dev/null | tail -n +2 | sort -u -k2,2 | sum_lines
}

progress_bar() { # VAR DONE TOTAL WIDTH
  local f=0 pa pb
  (($3 > 0)) && f=$(($2 * $4 / $3))
  repeatv pa █ "$f"; repeatv pb ░ $(($4 - f))
  printf -v "$1" '%s%s%s%s%s' "$ACCENT" "$pa" "$DIM" "$pb" "$NC"
}

draw_scan_frame() { # DONE TOTAL CURRENT
  local cat id n_done n_all bytes icon name pbar
  frame_begin; draw_header "$SCAN_TITLE"; fl ""
  fl "  ${BOLD}Scanning your system…${NC}"
  fl ""
  progress_bar pbar "$1" "$2" 36
  fl "  $pbar  ${BOLD}$1${NC}${DIM}/$2${NC}"
  fl ""
  for cat in "${SCAN_CATS[@]}"; do
    n_done=0 n_all=0 bytes=0
    for id in "${SCAN_IDS[@]}"; do
      [[ ${ITEM_CAT[$id]} == "$cat" ]] || continue
      ((++n_all))
      [[ -n ${SCAN_GOT[$id]} ]] || continue
      ((++n_done))
      ((RES_RC[$id] == 0)) && bytes=$((bytes + RES_BYTES[$id]))
    done
    if ((n_done == n_all)); then icon="${GREEN}✔${NC}"; else icon="${ACCENT}${SPINNER[SPIN_I % 10]}${NC}"; fi
    fitv name "${CAT_TITLE[$cat]}" 22
    fl "   $icon  $name ${DIM}$n_done/$n_all${NC}    $(human "$bytes")"
  done
  ((SPIN_I++))
  fl ""
  fl "  ${DIM}Checking ${3}…${NC}"
  hints q cancel
  draw_footer "$HINTS"; frame_flush
}

# Scan all items of the given categories in parallel; fills SCANNED (ordered
# by category, junk first, biggest first), SCAN_MS and SCAN_COUNT.
scan_items() { # CATEGORY...
  SCANNED=() SCAN_CATS=("$@") SCAN_IDS=() SCAN_GOT=()
  local found=() id cat tmp rc bytes note t0 done_n pending k json_last=-1
  declare -A pid_of=()
  for cat in "$@"; do
    for id in "${ITEM_IDS[@]}"; do [[ ${ITEM_CAT[$id]} == "$cat" ]] && SCAN_IDS+=("$id"); done
  done
  tmp=$(mktemp -d -p "$SESSION_TMP") || return 1
  t0=$(now_ms)

  for id in "${SCAN_IDS[@]}"; do
    (
      SCAN_BYTES=0 SCAN_NOTE=""
      "scan_$id" </dev/null >/dev/null 2>&1; rc=$?
      printf '%s\t%s\t%s\n' "$rc" "${SCAN_BYTES:-0}" "$SCAN_NOTE" >"$tmp/$id.part" && mv "$tmp/$id.part" "$tmp/$id"
    ) &
    pid_of[$id]=$!
  done

  while :; do
    done_n=0 pending=""
    for id in "${SCAN_IDS[@]}"; do
      if [[ -n ${SCAN_GOT[$id]} ]]; then ((++done_n))
      elif [[ -e $tmp/$id ]]; then
        IFS=$'\t' read -r rc bytes note <"$tmp/$id"
        RES_RC[$id]=$rc RES_BYTES[$id]=${bytes:-0} RES_NOTE[$id]=$note SCAN_GOT[$id]=1
        ((++done_n))
      else pending=${pending:-${ITEM_LABEL[$id]}}; fi
    done
    ((done_n == ${#SCAN_IDS[@]})) && break
    if (($(now_ms) - t0 > SCAN_TIMEOUT * 1000)); then
      for id in "${SCAN_IDS[@]}"; do [[ -n ${SCAN_GOT[$id]} ]] || kill_tree "${pid_of[$id]}"; done
      break
    fi
    if ((UI_ACTIVE)); then
      draw_scan_frame "$done_n" "${#SCAN_IDS[@]}" "$pending"
      if read_key 0.1 && [[ $KEY == q || $KEY == esc ]]; then
        for id in "${SCAN_IDS[@]}"; do [[ -n ${SCAN_GOT[$id]} ]] || kill_tree "${pid_of[$id]}"; done
        rm -rf "$tmp"
        SCANNED=()
        toast "${YELLOW}!${NC} Scan cancelled."
        return 130
      fi
    else
      if ((JSON)); then
        if ((done_n != ${json_last:--1})); then
          json_str k "$pending"
          printf '{"event":"progress","done":%d,"total":%d,"current":%s}\n' "$done_n" "${#SCAN_IDS[@]}" "$k"
          json_last=$done_n
        fi
      elif [[ -t 1 ]]; then printf '\r\e[K  Scanning %d/%d  %s…' "$done_n" "${#SCAN_IDS[@]}" "$pending"; fi
      sleep 0.1
    fi
  done
  ((UI_ACTIVE)) || { [[ -t 1 ]] && printf '\r\e[K'; }
  SCAN_MS=$(($(now_ms) - t0))
  SCAN_COUNT=${#SCAN_IDS[@]}

  for id in "${SCAN_IDS[@]}"; do
    [[ -n ${SCAN_GOT[$id]} ]] || RES_RC[$id]=3 RES_BYTES[$id]=0 RES_NOTE[$id]="scan timed out"
    ((RES_RC[$id] == 1)) && continue
    RES_HUMAN[$id]=$(human "${RES_BYTES[$id]}")
    SEL[$id]=0
    if ((RES_RC[$id] == 0)); then
      if [[ -n ${ITEM_ONCE[$id]:-} ]]; then SEL[$id]=${ITEM_DEFAULT[$id]}
      else SEL[$id]=${PREF[$id]:-${ITEM_DEFAULT[$id]}}; fi
    fi
    found+=("$id")
  done
  rm -rf "$tmp"

  for cat in "$@"; do
    while IFS=$'\t' read -r _ _ id; do SCANNED+=("$id"); done < <(
      for id in "${found[@]}"; do
        [[ ${ITEM_CAT[$id]} == "$cat" ]] &&
          printf '%d\t%d\t%s\n' "$((RES_RC[$id] == 0 ? 0 : 1))" "${RES_BYTES[$id]}" "$id"
      done | sort -t$'\t' -k1,1n -k2,2rn
    )
  done
  save_scan_cache
  record_disk_usage
  return 0
}

found_total() { # → FOUND_TOTAL, FOUND_N, SELECTED_TOTAL, SELECTED_N
  local id
  FOUND_TOTAL=0 FOUND_N=0 SELECTED_TOTAL=0 SELECTED_N=0
  for id in "${SCANNED[@]}"; do
    ((RES_RC[$id] == 0)) || continue
    FOUND_TOTAL=$((FOUND_TOTAL + RES_BYTES[$id])); ((++FOUND_N))
    ((SEL[$id])) && { SELECTED_TOTAL=$((SELECTED_TOTAL + RES_BYTES[$id])); ((++SELECTED_N)); }
  done
}

# ── plain output (--scan / --clean) ──

plain_results() {
  local i=0 id cat last="" box size
  declare -A cat_total=()
  found_total
  if [[ ${SCAN_CATS[*]} == privacy ]]; then
    printf '  Found %s%d history lists%s with entries\n' "$BOLD" "$FOUND_N" "$NC"
  else
  printf '  Found %s%s%s of junk in %d items %s· scanned %d locations in %d.%ds%s\n' \
    "$BOLD$(size_color "$FOUND_TOTAL")" "$(human "$FOUND_TOTAL")" "$NC" "$FOUND_N" "$DIM" "$SCAN_COUNT" \
    $((SCAN_MS / 1000)) $((SCAN_MS % 1000 / 100)) "$NC"
  fi
  for id in "${SCANNED[@]}"; do
    ((RES_RC[$id] == 0)) && cat_total[${ITEM_CAT[$id]}]=$((${cat_total[${ITEM_CAT[$id]}]:-0} + RES_BYTES[$id]))
  done
  for id in "${SCANNED[@]}"; do
    cat=${ITEM_CAT[$id]}
    if [[ $cat != "$last" ]]; then
      printf '\n  %s%-42s %10s%s\n' "$BOLD$BLUE" "${CAT_TITLE[$cat]}" "$(human "${cat_total[$cat]:-0}")" "$NC"
      last=$cat
    fi
    ((++i))
    if ((RES_RC[$id] != 0)); then
      printf '  %s%2d)  ✓  %-34s %10s  %s%s\n' "$DIM" "$i" "${ITEM_LABEL[$id]}" "" \
        "$( ((RES_RC[$id] == 3)) && echo "${RES_NOTE[$id]}" || echo clean)" "$NC"
      continue
    fi
    if ((SEL[$id])); then box="${GREEN}[x]${NC}"; else box="${DIM}[ ]${NC}"; fi
    if ((RES_BYTES[$id] > 0)); then size=${RES_HUMAN[$id]}; else size="—"; fi
    printf '  %2d) %s %-34s %s%10s%s  %s%s%s\n' "$i" "$box" "${ITEM_LABEL[$id]}" \
      "$(size_color "${RES_BYTES[$id]}")" "$size" "$NC" "$DIM" "${RES_NOTE[$id]}" "$NC"
  done
}

# ───────────────────────────── review screen ────────────────────────────────

SHOW_CLEAN=0 # review: list clean items one by one (h toggles) instead of one summary row

build_review_rows() { # rows: h = group header, i = item, c = "N more are clean", s = spacer
  R_KIND=() R_REF=() REVIEW_MAX=0
  local id last="" hidden=0
  for id in "${SCANNED[@]}"; do
    if [[ ${ITEM_CAT[$id]} != "$last" ]]; then
      ((hidden)) && { R_KIND+=(c); R_REF+=("$hidden"); hidden=0; }
      ((${#R_KIND[@]})) && { R_KIND+=(s); R_REF+=(""); }
      R_KIND+=(h); R_REF+=("${ITEM_CAT[$id]}")
      last=${ITEM_CAT[$id]}
    fi
    if ((RES_RC[$id] != 0 && !SHOW_CLEAN)); then ((++hidden)); continue; fi
    R_KIND+=(i); R_REF+=("$id")
    ((RES_RC[$id] == 0 && RES_BYTES[$id] > REVIEW_MAX)) && REVIEW_MAX=${RES_BYTES[$id]}
  done
  ((hidden)) && { R_KIND+=(c); R_REF+=("$hidden"); }
  return 0
}

review_index_of() { # KIND REF → index of that row in R_* (or 0)
  local i
  for i in "${!R_KIND[@]}"; do [[ ${R_KIND[i]} == "$1" && ${R_REF[i]} == "$2" ]] && { echo "$i"; return; }; done
  echo 0
}

review_text() {
  case ${R_KIND[$1]} in h) TEXT=${CAT_TITLE[${R_REF[$1]}]} ;; i) TEXT="${ITEM_LABEL[${R_REF[$1]}]} ${RES_NOTE[${R_REF[$1]}]}" ;; esac
}

review_focusable() {
  case ${R_KIND[$1]} in
    h) return 0 ;;
    i) ((RES_RC[${R_REF[$1]}] == 0)) ;;
    *) return 1 ;;
  esac
}

review_layout() { # column widths for the current terminal
  RV_LW=30 RV_BW=0
  ((UI_W >= 96)) && RV_BW=12
  ((UI_W < 70)) && RV_LW=22
  RV_NW=$((UI_W - 3 - 2 - RV_LW - 1 - (RV_BW ? RV_BW + 1 : 0) - 9 - 2 - 1))
}

review_row() {
  local kind=${R_KIND[$1]} ref=${R_REF[$1]} mark="  " lbl sz nt barv clr id n=0 s=0 tot=0 cnt hw
  case $kind in
    s) fl ""; return ;;
    c)
      local more them=them; pluralv more "$ref" "more item"; ((ref == 1)) && them=it
      fl "   ${DIM}✓ $more clean — press h to show $them${NC}"
      return ;;
    h)
      (($2)) && mark="${ACCENT}▸${NC} "
      for id in "${SCANNED[@]}"; do
        [[ ${ITEM_CAT[$id]} == "$ref" ]] && ((RES_RC[$id] == 0)) || continue
        ((++n)); tot=$((tot + RES_BYTES[$id]))
        ((SEL[$id])) && ((++s))
      done
      cnt="$s/$n selected"
      hw=$((2 + RV_LW + 1 + (RV_BW ? RV_BW + 1 : 0) - ${#cnt} - 2))
      fitv lbl "${CAT_TITLE[$ref]^^}" "$hw"
      humanv sz "$tot"; printf -v sz '%9s' "$sz"
      fl " $mark${BOLD}${BLUE}$lbl${NC}  ${DIM}$cnt${NC}${BOLD}$sz${NC}"
      ;;
    i)
      local id=$ref
      fitv lbl "${ITEM_LABEL[$id]}" "$RV_LW"
      fitv nt "${RES_NOTE[$id]}" "$RV_NW"
      if ((RES_RC[$id] != 0)); then
        printf -v sz '%9s' ""
        local st="clean"; ((RES_RC[$id] == 3)) && st="timed out"
        fitv nt "$st" "$RV_NW"
        repeatv barv ' ' $((RV_BW ? RV_BW + 1 : 0))
        fl "   ${DIM}✓ $lbl $barv$sz  $nt${NC}"
        return
      fi
      (($2)) && mark="${ACCENT}▸${NC} " lbl="${BOLD}$lbl${NC}"
      if ((SEL[$id])); then box="${GREEN}●${NC}"; else box="${DIM}○${NC}"; fi
      if ((RES_BYTES[$id] > 0)); then printf -v sz '%9s' "${RES_HUMAN[$id]}"; else printf -v sz '%9s' "—"; fi
      size_colorv clr "${RES_BYTES[$id]}"
      barv=""
      ((RV_BW)) && { size_bar barv "${RES_BYTES[$id]}" "$REVIEW_MAX" "$RV_BW"; barv+=" "; }
      fl " $mark$box $lbl $barv$clr$sz$NC  ${DIM}$nt${NC}"
      ;;
  esac
}

review_top() {
  found_total
  fl ""
  if [[ ${SCAN_CATS[*]} == privacy ]]; then
    if ((FOUND_N)); then
      local hl; pluralv hl "$FOUND_N" "history list"
      fl_card "${BOLD}$hl with entries${NC}" \
        "${DIM}Select what to clear — nothing is cleared until you confirm.${NC}"
    else
      fl_card "${GREEN}${BOLD}✔ Nothing to clear${NC}" "${DIM}Your histories and recent lists are empty.${NC}"
    fi
  elif ((FOUND_TOTAL > 0 || FOUND_N > 0)); then
    local clr ft fn; size_colorv clr "$FOUND_TOTAL"; humanv ft "$FOUND_TOTAL"; pluralv fn "$FOUND_N" item
    fl_card "${clr}${BOLD}$ft${NC} ${BOLD}of junk found${NC} in $fn" \
      "${DIM}$SCAN_COUNT locations scanned in $((SCAN_MS / 1000)).$((SCAN_MS % 1000 / 100))s${NC}"
  else
    fl_card "${GREEN}${BOLD}✔ Your system is clean${NC}" "${DIM}Nothing worth removing was found.${NC}"
  fi
  review_layout
}

review_bottom() {
  local clr desc ref=${R_REF[$L_CUR]}
  size_colorv clr "$SELECTED_TOTAL"
  fl ""
  local st sn fa fb
  humanv st "$SELECTED_TOTAL"; pluralv sn "$SELECTED_N" item
  if ((UI_W >= 80)); then
    humanv fa "$REVIEW_AVAIL"; humanv fb $((REVIEW_AVAIL + SELECTED_TOTAL))
    fl "  ${BOLD}Selected${NC} ${clr}${BOLD}$st${NC} ${DIM}in $sn · free space $fa → ~$fb${NC}"
  else
    fl "  ${BOLD}Selected${NC} ${clr}${BOLD}$st${NC} ${DIM}in $sn${NC}"
  fi
  case ${R_KIND[$L_CUR]} in
    h) desc="Press space to select or deselect every item in this group." ;;
    i) desc=${ITEM_DESC[$ref]} ;;
  esac
  fitv desc "$desc" $((UI_W - 6))
  fl "  ${ACCENT}ℹ${NC} ${DIM}$desc${NC}"
}

set_sel() { # ID 0|1 — select and remember (except one-off items like AI models)
  ((RES_RC[$1] == 0)) || return 0
  SEL[$1]=$2
  [[ -n ${ITEM_ONCE[$1]:-} ]] || PREF[$1]=$2
}

group_toggle() { # CATEGORY
  local id any_off=0
  for id in "${SCANNED[@]}"; do
    [[ ${ITEM_CAT[$id]} == "$1" ]] && ((RES_RC[$id] == 0 && !SEL[$id])) && any_off=1
  done
  for id in "${SCANNED[@]}"; do [[ ${ITEM_CAT[$id]} == "$1" ]] && set_sel "$id" "$any_off"; done
}

scan_and_review() { # TITLE CATEGORY...
  local title=$1 cur scroll kind ref id
  shift
  SCAN_TITLE=$title
  [[ " $* " == *" system "* ]] && offer_sudo_for_scan
  scan_items "$@" || return
  build_review_rows
  REVIEW_AVAIL=$(fs_avail)
  cur=0 scroll=0
  while :; do
    L_TITLE=$title L_TOP=review_top L_BOTTOM=review_bottom L_ROW=review_row
    L_FOCUSABLE=review_focusable L_TEXT=review_text L_VIEW=0 L_COUNT=${#R_KIND[@]} L_CUR=$cur L_SCROLL=$scroll
    hints space select "!c" Clean "→" details q back a all n none h "$( ((SHOW_CLEAN)) && echo "hide clean" || echo "show clean")" r rescan
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL kind=${R_KIND[$L_CUR]} ref=${R_REF[$L_CUR]}
    case $KEY in
      h)
        SHOW_CLEAN=$((1 - SHOW_CLEAN))
        build_review_rows
        cur=$(review_index_of "$kind" "$ref") ;;
      space)
        if [[ $kind == h ]]; then group_toggle "$ref"
        elif [[ $kind == i ]]; then set_sel "$ref" $((1 - SEL[$ref])); fi
        save_prefs ;;
      enter | right | d)
        if [[ $kind == i ]]; then show_details "$ref"
        elif [[ $kind == h ]]; then group_toggle "$ref"; save_prefs; fi ;;
      a) for id in "${SCANNED[@]}"; do ((RES_RC[$id] == 0)) && SEL[$id]=1; done ;;
      n) for id in "${SCANNED[@]}"; do SEL[$id]=0; done ;;
      c)
        if start_cleanup; then
          build_review_rows; REVIEW_AVAIL=$(fs_avail)
          cur=$(review_index_of "$kind" "$ref")
        fi ;;
      r) scan_items "$@" || return; build_review_rows; REVIEW_AVAIL=$(fs_avail); cur=0 scroll=0 ;;
      q | esc | left | backspace) return ;;
    esac
  done
}

# ── details ──

details_top() {
  local clr st
  size_colorv clr "${RES_BYTES[$DETAIL_ID]}"
  if ((SEL[$DETAIL_ID])); then st="${GREEN}● selected${NC}"; else st="${DIM}○ not selected${NC}"; fi
  fl ""
  fl "  ${clr}${BOLD}${RES_HUMAN[$DETAIL_ID]}${NC}   $st   ${DIM}${RES_NOTE[$DETAIL_ID]}${NC}"
  fl "  ${DIM}${ITEM_DESC[$DETAIL_ID]}${NC}"
  fl ""
}

show_details() { # ID
  local id=$1 tmp
  DETAIL_ID=$id
  tmp=$(mktemp -p "$SESSION_TMP")
  if declare -F "details_$id" >/dev/null; then ("details_$id") >"$tmp" 2>/dev/null &
  else : >"$tmp" & fi
  UI_BUSY_TITLE=${ITEM_LABEL[$id]}
  ui_busy "Collecting details…" $! || { rm -f "$tmp"; return; }
  mapfile -t V_LINES <"$tmp"
  rm -f "$tmp"
  ((${#V_LINES[@]})) || V_LINES=("  ${DIM}Nothing more to show.${NC}")
  L_SCROLL=0
  while :; do
    L_TITLE="${ITEM_LABEL[$id]}" L_TOP=details_top L_BOTTOM="" L_ROW=view_row L_FOCUSABLE=""
    L_VIEW=1 L_COUNT=${#V_LINES[@]}
    hints "↑↓" scroll space "$( ((SEL[$id])) && echo deselect || echo select)" q back
    L_HINTS=$HINTS
    ui_list
    case $KEY in
      space) set_sel "$id" $((1 - SEL[$id])); save_prefs ;;
      q | esc | left | enter | backspace) L_VIEW=0; return ;;
    esac
  done
}

# ───────────────────────────── task runner ──────────────────────────────────
#
# Tasks are T_LABEL / T_FN / T_ARG. For each task, <fn>_pre ARG runs first in
# the foreground (may ask; non-zero skips), <fn> ARG runs in the background
# with its output captured, then <fn>_post ARG RC IDX OUTFILE may set T_INFO.

declare -a T_LABEL=() T_FN=() T_ARG=() T_STATE=() T_INFO=()
RUN_KIND=other RUN_FREED=0 T_CUR=-1

new_tasks() { T_LABEL=() T_FN=() T_ARG=() RUN_FREED=0 RUN_KIND=${1:-other}; }
add_task() { T_LABEL+=("$1") T_FN+=("$2") T_ARG+=("${3:-}"); }

draw_runner() { # TITLE OUTFILE
  local i n=${#T_LABEL[@]} d=0 pbar icon lbl info last start avail extra=""
  for ((i = 0; i < n; i++)); do [[ ${T_STATE[i]} == @(ok|skip|fail) ]] && ((d++)); done
  frame_begin; draw_header "$1"; fl ""
  progress_bar pbar "$d" "$n" 36
  [[ $RUN_KIND == clean ]] && extra=" · $(human "$RUN_FREED") $( ((DRY_RUN)) && echo "would be freed" || echo freed)"
  fl "  $pbar  ${BOLD}$d${NC}${DIM}/$n · $(((($(now_ms) - RUN_T0)) / 1000))s$extra${NC}"
  fl ""
  avail=$((TERM_ROWS - FRAME_N - 7))
  start=0
  ((n > avail && T_CUR > avail / 2)) && start=$((T_CUR - avail / 2))
  ((start > n - avail && n > avail)) && start=$((n - avail))
  for ((i = start; i < n && i < start + avail; i++)); do
    fitv lbl "${T_LABEL[i]}" 38
    info=${T_INFO[i]}
    case ${T_STATE[i]} in
      pending) icon="${DIM}○${NC}" lbl="${DIM}$lbl${NC}" ;;
      run) icon="${ACCENT}${SPINNER[SPIN_I % 10]}${NC}" lbl="${BOLD}$lbl${NC}" info="working…" ;;
      ok) icon="${GREEN}✔${NC}" ;;
      skip) icon="${YELLOW}–${NC}" ;;
      fail) icon="${RED}✘${NC}" ;;
    esac
    fl "   $icon  $lbl  ${DIM}$info${NC}"
  done
  ((SPIN_I++))
  if [[ -n $2 && -s $2 ]]; then
    last=$(grep -v '^@@scan' "$2" | grep -v '^\s*$' | tail -n 1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
    fitv last "$last" $((UI_W - 8))
    fl ""
    fl "   ${DIM}│ $last${NC}"
  fi
  hints "ctrl+c" abort
  draw_footer "$HINTS"; frame_flush
}

run_tasks() { # TITLE
  local title=$1 i n=${#T_LABEL[@]} out pid rc
  mkdir -p "$LOG_DIR" && : >"$RUN_LOG"
  T_STATE=() T_INFO=()
  for ((i = 0; i < n; i++)); do T_STATE[i]=pending T_INFO[i]=""; done
  RUN_T0=$(now_ms)
  local keepalive=""
  if ((EUID != 0)) && sudo -n true 2>/dev/null; then # keep credentials fresh during long tasks
    (while sleep 45; do sudo -n -v 2>/dev/null || exit; done) &
    keepalive=$!
  fi
  for ((i = 0; i < n; i++)); do
    T_CUR=$i
    if declare -F "${T_FN[i]}_pre" >/dev/null && ! "${T_FN[i]}_pre" "${T_ARG[i]}"; then
      T_STATE[i]=skip T_INFO[i]="skipped"
      ((UI_ACTIVE)) || warn "${T_LABEL[i]}: skipped"
      continue
    fi
    T_STATE[i]=run
    out=$(mktemp -p "$SESSION_TMP")
    if ((UI_ACTIVE)); then
      ("${T_FN[i]}" "${T_ARG[i]}") >"$out" 2>&1 </dev/null &
      pid=$!
      while kill -0 "$pid" 2>/dev/null; do draw_runner "$title" "$out"; read_key 0.1; done
      wait "$pid"; rc=$?
    else
      printf '  %s→%s %s\n' "$CYAN" "$NC" "${T_LABEL[i]}"
      "${T_FN[i]}" "${T_ARG[i]}" >"$out" 2>&1 </dev/null; rc=$?
      grep -F '[dry-run]' "$out"
    fi
    if ((rc == 0)); then T_STATE[i]=ok; else T_STATE[i]=fail T_INFO[i]="failed (exit $rc) — see log"; fi
    declare -F "${T_FN[i]}_post" >/dev/null && "${T_FN[i]}_post" "${T_ARG[i]}" "$rc" "$i" "$out"
    [[ ${T_STATE[i]} == ok && -z ${T_INFO[i]} ]] && T_INFO[i]="done"
    if ((!UI_ACTIVE)); then
      if ((rc == 0)); then ok "${T_INFO[i]}"; else err "${T_INFO[i]}"; tail -n 5 "$out" | sed 's/^/    /'; fi
    fi
    { printf '━━ %s — exit %d\n' "${T_LABEL[i]}" "$rc"; grep -v '^@@scan' "$out"; printf '\n'; } >>"$RUN_LOG"
    rm -f "$out"
  done
  [[ -n $keepalive ]] && kill_tree "$keepalive"
  T_CUR=-1
  RUN_MS=$(($(now_ms) - RUN_T0))
  return 0
}

run_counts() { # → RC_OK RC_SKIP RC_FAIL
  local s
  RC_OK=0 RC_SKIP=0 RC_FAIL=0
  for s in "${T_STATE[@]}"; do
    case $s in ok) ((++RC_OK)) ;; skip) ((++RC_SKIP)) ;; fail) ((++RC_FAIL)) ;; esac
  done
}

results_top() {
  local head
  run_counts
  if [[ $RUN_KIND == clean && ${SCAN_CATS[*]} == privacy ]]; then
    if ((DRY_RUN)); then head="${MAGENTA}${BOLD}$(plural "$RC_OK" list) would be cleared${NC} ${DIM}(dry run)${NC}"
    else head="${GREEN}${BOLD}🔒 $(plural "$RC_OK" "history list") cleared${NC}"; fi
  elif [[ $RUN_KIND == clean ]]; then
    if ((DRY_RUN)); then head="${MAGENTA}${BOLD}$(human "$RUN_FREED") would be freed${NC} ${DIM}(dry run)${NC}"
    else head="${GREEN}${BOLD}🎉 $(human "$RUN_FREED") freed${NC}"; fi
  elif ((RC_FAIL)); then head="${YELLOW}${BOLD}! Finished with $(plural "$RC_FAIL" error)${NC}"
  else head="${GREEN}${BOLD}✔ All done${NC}"; fi
  fl ""
  if [[ $RUN_KIND == clean && ${SCAN_CATS[*]} != privacy ]] && ((!DRY_RUN)); then
    fl_card "$head" "${DIM}$RC_OK done · $RC_SKIP skipped · $RC_FAIL failed · took $((RUN_MS / 1000)).$((RUN_MS % 1000 / 100))s${NC}" \
      "${DIM}Free space $(human "$RUN_AVAIL0") → ${NC}${BOLD}$(human "$RUN_AVAIL1")${NC}"
  else
    fl_card "$head" "${DIM}$RC_OK done · $RC_SKIP skipped · $RC_FAIL failed · took $((RUN_MS / 1000)).$((RUN_MS % 1000 / 100))s${NC}"
  fi
  fl ""
}

result_row() {
  local i=$1 icon lbl
  fitv lbl "${T_LABEL[i]}" 38
  case ${T_STATE[i]} in
    ok) icon="${GREEN}✔${NC}" ;; skip) icon="${YELLOW}–${NC}" ;; fail) icon="${RED}✘${NC}" ;; *) icon="${DIM}○${NC}" ;;
  esac
  fl "   $icon  $lbl  ${DIM}${T_INFO[i]}${NC}"
}

show_run_results() { # TITLE
  if ((!UI_ACTIVE)); then
    run_counts
    if [[ $RUN_KIND == clean ]]; then
      printf '\n  %s%s🎉 Total %s: %s%s\n' "$BOLD" "$GREEN" "$( ((DRY_RUN)) && echo "that would be freed" || echo freed)" "$(human "$RUN_FREED")" "$NC"
      ((DRY_RUN)) || printf '  %sFree space: %s → %s%s\n' "$DIM" "$(human "$RUN_AVAIL0")" "$(human "$RUN_AVAIL1")" "$NC"
    fi
    printf '  %s%d done · %d skipped · %d failed — output in %s%s\n' "$DIM" "$RC_OK" "$RC_SKIP" "$RC_FAIL" "$RUN_LOG" "$NC"
    return
  fi
  L_SCROLL=0
  while :; do
    L_TITLE=$1 L_TOP=results_top L_BOTTOM="" L_ROW=result_row L_FOCUSABLE="" L_VIEW=1 L_COUNT=${#T_LABEL[@]}
    hints l "output log" "!enter" "done"
    L_HINTS=$HINTS
    ui_list
    case $KEY in
      l) mapfile -t V_LINES <"$RUN_LOG"; ((${#V_LINES[@]})) || V_LINES=("  (no output)"); ui_view "Output log" ;;
      enter | q | esc | left | backspace) L_VIEW=0; return ;;
    esac
  done
}

# ── cleanup tasks ──

task_clean_pre() { declare -F "precheck_$1" >/dev/null || return 0; "precheck_$1"; }

task_clean() { # clean, then re-measure so the parent can compute what was freed
  local rc src
  "clean_$1"; rc=$?
  if ((rc == 0 && !DRY_RUN)); then
    SCAN_BYTES=0 SCAN_NOTE=""
    "scan_$1" >/dev/null 2>&1; src=$?
    printf '\n@@scan\t%s\t%s\t%s\n' "$src" "${SCAN_BYTES:-0}" "$SCAN_NOTE"
  fi
  return "$rc"
}

task_clean_post() { # ID RC IDX OUTFILE
  local id=$1 i=$3 before=${RES_BYTES[$1]} freed src bytes note
  (($2 == 0)) || return 0
  if [[ ${ITEM_CAT[$id]} == privacy ]]; then
    T_INFO[i]=$( ((DRY_RUN)) && echo "would be cleared" || echo "cleared")
    ((DRY_RUN)) || RES_RC[$id]=2 SEL[$id]=0 RES_NOTE[$id]=""
    return 0
  fi
  if ((DRY_RUN)); then
    freed=$before
    T_INFO[i]="$(human "$freed") would be freed"
    ((freed == 0)) && T_INFO[i]="would be cleaned"
  else
    IFS=$'\t' read -r _ src bytes note < <(grep '^@@scan' "$4" | tail -n 1)
    bytes=${bytes:-0}
    freed=$((before - bytes)); ((freed < 0)) && freed=0
    [[ ${src:-1} == 0 ]] || src=2
    RES_BYTES[$id]=$bytes RES_NOTE[$id]=$note RES_RC[$id]=$src RES_HUMAN[$id]=$(human "$bytes") SEL[$id]=0
    T_INFO[i]="$(human "$freed") freed"
    ((freed == 0 && before == 0)) && T_INFO[i]="cleaned"
  fi
  RUN_FREED=$((RUN_FREED + freed))
}

start_cleanup() { # cleans the selected SCANNED items; returns 1 if nothing ran
  local id ids=() keep=() needs_root=0 needs_root_hint=0
  found_total
  for id in "${SCANNED[@]}"; do ((SEL[$id])) && ids+=("$id"); done
  for id in "${ids[@]}"; do [[ -n ${ITEM_ROOT[$id]} ]] && needs_root_hint=1; done
  if ((${#ids[@]} == 0)); then
    if ((UI_ACTIVE)); then toast "${YELLOW}!${NC} Nothing selected — press space to select items."
    else warn "Nothing selected."; fi
    return 1
  fi
  local lbl line
  CONFIRM_LINES=()
  for id in "${ids[@]}"; do # what exactly will happen, shown in the dialog
    fitv lbl "${ITEM_LABEL[$id]}" 34
    if [[ ${ITEM_CAT[$id]} == privacy ]]; then line="• $lbl"
    else printf -v line '• %s %10s' "$lbl" "${RES_HUMAN[$id]}"; fi
    [[ -n ${ITEM_ROOT[$id]} ]] && line+=" ⚿"
    CONFIRM_LINES+=("$line")
  done
  if [[ ${SCAN_CATS[*]} == privacy ]]; then
    ui_confirm "Clear $(plural ${#ids[@]} "history list")?" "This can't be undone." y || return 1
  else
    ui_confirm "Clean $(plural ${#ids[@]} item)?" "About $(human "$SELECTED_TOTAL") will be removed.$( ((needs_root_hint)) && echo " ⚿ = needs sudo")" y || return 1
  fi
  for id in "${ids[@]}"; do [[ -n ${ITEM_ROOT[$id]} ]] && needs_root=1; done
  if ((needs_root)) && ! ensure_sudo "System items need administrator rights to clean."; then
    for id in "${ids[@]}"; do [[ -n ${ITEM_ROOT[$id]} ]] || keep+=("$id"); done
    ids=("${keep[@]}")
    toast "${YELLOW}!${NC} No sudo — system items were skipped."
    ((${#ids[@]})) || return 1
  fi

  new_tasks clean
  for id in "${ids[@]}"; do add_task "${ITEM_LABEL[$id]}" task_clean "$id"; done
  RUN_AVAIL0=$(fs_avail)
  run_tasks "Cleaning"
  RUN_AVAIL1=$(fs_avail)
  save_scan_cache
  record_disk_usage
  ((DRY_RUN)) || record_cleanup "$RUN_FREED"
  log "Cleanup finished — $(human "$RUN_FREED") freed (dry-run=$DRY_RUN)"
  refresh_sysinfo
  show_run_results "Cleanup complete"
  return 0
}

scan_report() { # --scan
  printf '%sClean My Ubuntu — scan report%s\n\n' "$BOLD" "$NC"
  scan_items "${CATEGORIES[@]}"
  plain_results
  found_total
  printf '\n  %s●%s = cleaned by --clean (%s)\n' "$GREEN" "$NC" "$(human "$SELECTED_TOTAL")"
}

smart_clean() { # --clean
  printf '%sClean My Ubuntu — smart clean%s\n\n' "$BOLD" "$NC"
  scan_items "${CATEGORIES[@]}"
  plain_results
  printf '\n'
  if [[ ! -t 0 ]] && ((!ASSUME_YES)); then
    err "Not a terminal: add --yes to clean without confirmation."; exit 1
  fi
  start_cleanup
}

# ───────────────────────────── large & old files ────────────────────────────

declare -A F_SEL=()

file_row() {
  local b d p mark="  " box lbl clr pw
  IFS=$'\t' read -r b d p <<<"${FOUND[$1]}"
  p=${p/#$HOME/\~}
  pw=$((UI_W - 30))
  ((${#p} > pw)) && p="…${p: -$((pw - 1))}"
  (($2)) && mark="${ACCENT}▸${NC} " p="${BOLD}$p${NC}"
  if [[ -n ${F_SEL[$1]} ]]; then box="${GREEN}●${NC}"; else box="${DIM}○${NC}"; fi
  size_colorv clr "$b"
  humanv lbl "$b"; printf -v lbl '%9s' "$lbl"
  fl " $mark$box $clr$lbl$NC  ${DIM}$d${NC}  $p"
}

files_bottom() {
  local i n=0 tot=0 b d p
  for i in "${!F_SEL[@]}"; do IFS=$'\t' read -r b _ <<<"${FOUND[i]}"; tot=$((tot + b)); ((++n)); done
  IFS=$'\t' read -r b d p <<<"${FOUND[$L_CUR]}"
  fl ""
  local fn ft; pluralv fn "$n" file; humanv ft "$tot"
  fl "  ${BOLD}Selected${NC} $fn · ${BOLD}$ft${NC}"
  fl "  ${ACCENT}ℹ${NC} ${DIM}${p/#$HOME/\~}${NC}"
}

file_text() { TEXT=${FOUND[$1]##*$'\t'}; }
files_top() { fl ""; fl "  ${BOLD}$(plural ${#FOUND[@]} file)${NC} ${DIM}— biggest first${NC}"; fl ""; }

pick_files() { # TITLE — FOUND holds "bytes<TAB>date<TAB>path"
  local title=$1 i b d p keep=() n tot cur=0 scroll=0
  F_SEL=()
  if ((${#FOUND[@]} == 0)); then toast "${GREEN}✔${NC} No matching files found."; return; fi
  while :; do
    ((${#FOUND[@]} || ${#UNDO_BATCH[@]})) || return # stay while there's something to undo
    L_TITLE=$title L_TOP=files_top L_BOTTOM=files_bottom L_ROW=file_row L_FOCUSABLE="" L_TEXT=file_text
    L_VIEW=0 L_COUNT=${#FOUND[@]} L_CUR=$cur L_SCROLL=$scroll
    if ((${#UNDO_BATCH[@]})); then hints space select "!t" "move to Trash" z undo o "open folder" q back a all n none
    else hints space select "!t" "move to Trash" o "open folder" q back a all n none; fi
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL
    case $KEY in
      space) if [[ -n ${F_SEL[$cur]} ]]; then unset "F_SEL[$cur]"; else F_SEL[$cur]=1; fi; list_move 1; cur=$L_CUR ;;
      a) for i in "${!FOUND[@]}"; do F_SEL[$i]=1; done ;;
      n) F_SEL=() ;;
      o)
        IFS=$'\t' read -r b d p <<<"${FOUND[cur]}"
        xdg-open "$(dirname "$p")" >/dev/null 2>&1 &
        disown 2>/dev/null
        toast "${ACCENT}↗${NC} Opened $(dirname "${p/#$HOME/\~}")" ;;
      t | delete)
        ((${#F_SEL[@]})) || F_SEL[$cur]=1
        n=0 tot=0
        for i in "${!F_SEL[@]}"; do IFS=$'\t' read -r b _ <<<"${FOUND[i]}"; tot=$((tot + b)); ((++n)); done
        ui_confirm "Move $(plural "$n" file) to Trash?" "$(human "$tot") — press z to undo." y || continue
        keep=() FOUND_TRASHED=() UNDO_BATCH=()
        for i in "${!FOUND[@]}"; do
          IFS=$'\t' read -r b d p <<<"${FOUND[i]}"
          if [[ -n ${F_SEL[$i]} ]]; then
            if move_to_trash "$p" >/dev/null 2>&1; then FOUND_TRASHED+=("${FOUND[i]}"); else keep+=("${FOUND[i]}"); fi
          else keep+=("${FOUND[i]}"); fi
        done
        if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would move $(plural "$n" file) ($(human "$tot")) to Trash"
        else FOUND=("${keep[@]}"); toast "${GREEN}✔${NC} Moved $(plural "$n" file) ($(human "$tot")) to Trash — press z to undo"; refresh_sysinfo; fi
        F_SEL=() ;;
      z)
        ((${#UNDO_BATCH[@]})) || continue
        undo_trash
        mapfile -t FOUND < <(printf '%s\n' "${FOUND[@]}" "${FOUND_TRASHED[@]}" | grep -v '^$' | sort -t$'\t' -k1,1rn)
        FOUND_TRASHED=() F_SEL=()
        refresh_sysinfo; undo_toast ;;
      q | esc | left | backspace) return ;;
    esac
  done
}

find_files_bg() { # MESSAGE FIND-ARGS... — run find in the background with a spinner
  local msg=$1 tmp
  shift
  tmp=$(mktemp -p "$SESSION_TMP")
  FOUND=()
  (find "$@" -printf '%s\t%TY-%Tm-%Td\t%p\n' 2>/dev/null >"$tmp") &
  UI_BUSY_TITLE="Large & Old Files"
  ui_busy "$msg" $! "$tmp" file || { rm -f "$tmp"; return 1; }
  mapfile -t FOUND < <(sort -t$'\t' -k1,1rn "$tmp" | head -n 200)
  rm -f "$tmp"
}

find_large() { # DIR MB
  find_files_bg "Looking for files over $2 MB in ${1/#$HOME/\~}…" "$1" -xdev -type f -size +"$2"M \
    -not -path '*/.cache/*' -not -path '*/Trash/*' -not -path '*/.git/*' || return
  pick_files "Files over $2 MB"
}

VM_DISK_NAMES=(-iname '*.vdi' -o -iname '*.vmdk' -o -iname '*.qcow2' -o -iname '*.vhd' -o -iname '*.vhdx')
find_vm_disks() { # your VM disks, plus the system libvirt/Multipass stores when they're readable
  local roots=("$HOME") d
  for d in /var/lib/libvirt/images /var/snap/multipass/common/data/multipassd/vault/instances; do
    [[ -r $d && -x $d ]] && roots+=("$d")
  done
  find_files_bg "Looking for virtual machine disks…" "${roots[@]}" -xdev -type f \( "${VM_DISK_NAMES[@]}" \) \
    -size +1M -not -path '*/Trash/*'
}

large_files_menu() {
  local dir min dl
  dl=$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME/Downloads")
  while :; do
    M_KEY=(1 2 3 4 5)
    M_LABEL=("Large files" "Huge files" "Old downloads" "Virtual machine disks" "Custom search…")
    M_DESC=("Files over 100 MB in your home folder" "Files over 1 GB in your home folder"
      "Files in ${dl/#$HOME/\~} untouched for 90+ days" "VirtualBox, VMware, GNOME Boxes, virt-manager and Multipass disks"
      "Choose a folder and a minimum size")
    ui_menu "Large & Old Files" || return
    case $MENU_IDX in
      0) find_large "$HOME" 100 ;;
      1) find_large "$HOME" 1024 ;;
      2)
        [[ -d $dl ]] || { toast "${RED}✘${NC} Downloads folder not found."; continue; }
        find_files_bg "Looking for old downloads…" "$dl" -type f -mtime +90 || continue
        pick_files "Downloads older than 90 days" ;;
      3)
        find_vm_disks || continue
        pick_files "Virtual machine disks — delete the VM in its app when you can" ;;
      4)
        ui_input "Folder to search:" "$HOME" || continue
        dir=${REPLY_TEXT/#\~/$HOME}
        [[ -d $dir ]] || { toast "${RED}✘${NC} Not a folder: $dir"; continue; }
        ui_input "Minimum size in MB:" 100 || continue
        min=$REPLY_TEXT
        [[ $min =~ ^[0-9]+$ ]] || { toast "${RED}✘${NC} Invalid size: $min"; continue; }
        find_large "$dir" "$min" ;;
    esac
  done
}

# ───────────────────────────── uninstaller ──────────────────────────────────

declare -a U_SRC=() U_ID=() U_SIZE=()
declare -A U_SEL=()

app_search() { # QUERY → U_SRC U_ID U_SIZE
  local q=${1,,} id size name
  U_SRC=() U_ID=() U_SIZE=() U_SEL=()
  if have snap; then
    while read -r id; do
      U_SRC+=("snap") U_ID+=("$id") U_SIZE+=("$(du_sum /var/lib/snapd/snaps/"${id}"_*.snap)")
    done < <(snap list 2>/dev/null | awk -v q="$q" 'NR > 1 && index(tolower($1), q) {print $1}')
  fi
  if have flatpak; then
    while IFS=$'\t' read -r id name size; do
      U_SRC+=("flatpak") U_ID+=("$id") U_SIZE+=("$(si_to_bytes "${size// /}")")
    done < <(flatpak list --app --columns=application,name,size 2>/dev/null |
      awk -F'\t' -v q="$q" 'index(tolower($1), q) || index(tolower($2), q)')
  fi
  if have dpkg-query; then
    declare -A manual=()
    while read -r id; do manual[$id]=1; done < <(apt-mark showmanual 2>/dev/null)
    while IFS=$'\t' read -r id size; do
      U_SRC+=("apt$([[ -n ${manual[$id]} ]] || echo "*")") U_ID+=("$id") U_SIZE+=("$((size * 1024))")
    done < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Installed-Size}\n' 2>/dev/null |
      awk -F'\t' -v q="$q" '$1 ~ /^ii/ && index(tolower($2), q) {print $2 "\t" ($3 + 0)}' |
      while IFS=$'\t' read -r id size; do printf '%d\t%s\t%s\n' "$([[ -n ${manual[$id]} ]] && echo 0 || echo 1)" "$id" "$size"; done |
      sort -t$'\t' -k1,1n -k2,2 | cut -f2- | head -n 60) # apps you installed first, then dependencies
  fi
}

app_row() {
  local i=$1 mark="  " box src lbl sz c
  (($2)) && mark="${ACCENT}▸${NC} "
  if [[ -n ${U_SEL[$i]} ]]; then box="${GREEN}●${NC}"; else box="${DIM}○${NC}"; fi
  case ${U_SRC[i]} in snap) c=$MAGENTA ;; flatpak) c=$BLUE ;; *) c=$CYAN ;; esac
  fitv src "${U_SRC[i]}" 8
  fitv lbl "${U_ID[i]}" $((UI_W - 30))
  (($2)) && lbl="${BOLD}$lbl${NC}"
  if ((U_SIZE[i] > 0)); then humanv sz "${U_SIZE[i]}"; printf -v sz '%9s' "$sz"; else printf -v sz '%9s' "—"; fi
  fl " $mark$box $c$src$NC $lbl $sz"
}

app_text() { TEXT=${U_ID[$1]}; }
apps_top() { fl ""; fl "  ${BOLD}$(plural ${#U_ID[@]} app)${NC} ${DIM}matching “$APP_QUERY”${NC}"; fl ""; }

apps_bottom() {
  fl ""
  fl "  ${BOLD}Selected${NC} $(plural ${#U_SEL[@]} app)   ${DIM}apt* = installed automatically as a dependency${NC}"
}

# Folders that hold personal data even though they share a package's name.
LEFTOVER_DENY='^(ssh|openssh.*|gnupg.*|gpg.*|git|pki|mozilla|thunderbird|evolution|keyrings|systemd|dconf|autostart|applications|fonts|icons|themes|bash|zsh|fish|vim|nvim|neovim|emacs|steam|flatpak|containers|trash|pulse|pipewire|gtk-.*|gnome-shell|nautilus|recently-used.*|user-dirs.*|mime.*|menus)$'

find_leftovers() { # NAME... → LEFTOVERS
  local n p
  LEFTOVERS=()
  for n in "$@"; do
    [[ ${n,,} =~ $LEFTOVER_DENY ]] && continue
    for p in "$HOME/.config/$n" "$HOME/.local/share/$n" "$HOME/.cache/$n" "$HOME/.var/app/$n"; do
      [[ -e $p && ! -L $p ]] && ! is_protected "$p" && LEFTOVERS+=("$p")
    done
  done
}

task_uninstall() { # SRC:ID[:INDEX]
  local src=${1%%:*} id=${1#*:}
  id=${id%%:*}
  case $src in
    apt*) run_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$id" ;;
    snap) run_root snap remove --purge "$id" ;;
    flatpak) run flatpak uninstall -y --noninteractive --delete-data "$id" ;;
  esac
}

uninstall_selected() {
  local i apt_pkgs=() names=() needs_root=0 extra=0 body p tot=0
  for i in "${!U_SEL[@]}"; do
    names+=("${U_ID[i]}")
    [[ ${U_SRC[i]} == apt* ]] && apt_pkgs+=("${U_ID[i]}")
    [[ ${U_SRC[i]} != flatpak ]] && needs_root=1
  done
  local title sim others
  body=$(printf '%s, ' "${names[@]}"); body=${body%, }
  title="Uninstall $(plural ${#names[@]} app)?"
  if ((${#apt_pkgs[@]})); then # simulate first: apt may refuse, or take other packages with it
    apt_check_removal "${apt_pkgs[@]}" || return
    if ((APT_EXTRA_N)); then
      title="⚠ Also removes $(plural "$APT_EXTRA_N" "other package")! Continue?"
      body=$APT_EXTRA_TEXT
    fi
  fi
  ui_confirm "$title" "$body" n || return
  ((needs_root)) && { ensure_sudo "Removing system packages needs administrator rights." || return; }
  new_tasks
  for i in "${!U_SEL[@]}"; do add_task "Uninstall ${U_ID[i]} (${U_SRC[i]%\*})" task_uninstall "${U_SRC[i]}:${U_ID[i]}"; done
  run_tasks "Uninstalling"
  refresh_sysinfo
  show_run_results "Uninstall complete"

  local removed=()
  for i in "${!T_STATE[@]}"; do # leftovers only for apps that were really removed
    [[ ${T_STATE[i]} == ok ]] && removed+=("${T_ARG[i]#*:}")
  done
  ((${#removed[@]})) && find_leftovers "${removed[@]}" || LEFTOVERS=()
  if ((${#LEFTOVERS[@]})); then
    for p in "${LEFTOVERS[@]}"; do tot=$((tot + $(du_sum "$p"))); done
    body=$(printf '%s, ' "${LEFTOVERS[@]/#$HOME/\~}"); body=${body%, }
    if ui_confirm "Trash $(plural ${#LEFTOVERS[@]} "leftover folder") ($(human "$tot"))?" "$body" n; then
      UNDO_BATCH=()
      for p in "${LEFTOVERS[@]}"; do move_to_trash "$p" >/dev/null 2>&1; done
      if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would move $(plural ${#LEFTOVERS[@]} "leftover folder") to Trash"
      else toast "${GREEN}✔${NC} Moved $(plural ${#LEFTOVERS[@]} "leftover folder") to Trash"; fi
    fi
  fi
  U_SEL=()
  app_search "$APP_QUERY"
}

uninstaller_menu() { apps_menu; }

pkg_search_menu() { # every installed package, libraries and command-line tools included
  local cur scroll
  while :; do
    frame_begin; draw_header "Uninstaller — all packages"; fl ""
    fl "  ${BOLD}Search every installed package${NC} ${DIM}— apt, snap and flatpak, libraries included${NC}"
    fl ""
    fl "  ${DIM}Type part of a name, e.g. “gimp”, “vlc” or “zoom”. Leave empty to go back.${NC}"
    draw_footer "$(hints enter search; echo "$HINTS")"; frame_flush
    ui_input "Search:" || return
    APP_QUERY=$REPLY_TEXT
    app_search "$APP_QUERY"
    if ((${#U_ID[@]} == 0)); then toast "${YELLOW}!${NC} No installed app matches “$APP_QUERY”."; continue; fi
    cur=0 scroll=0
    while :; do
      ((${#U_ID[@]})) || break
      L_TITLE="Uninstaller — all packages" L_TOP=apps_top L_BOTTOM=apps_bottom L_ROW=app_row L_FOCUSABLE="" L_TEXT=app_text
      L_VIEW=0 L_COUNT=${#U_ID[@]} L_CUR=$cur L_SCROLL=$scroll
      hints space select "!u" uninstall / "new search" q back "↑↓" move
      L_HINTS=$HINTS
      ui_list
      cur=$L_CUR scroll=$L_SCROLL
      case $KEY in
        space) if [[ -n ${U_SEL[$cur]} ]]; then unset "U_SEL[$cur]"; else U_SEL[$cur]=1; fi; list_move 1; cur=$L_CUR ;;
        u | enter)
          ((${#U_SEL[@]})) || U_SEL[$cur]=1
          uninstall_selected ;;
        / | q | esc | left | backspace) break ;;
      esac
    done
  done
}

# ── App list: real apps (from their launchers), not packages ──
#
# Built from .desktop files, so libraries, drivers and services never show up.
# Each app gets its owner (apt package, snap or flatpak), its package size, the
# folders it keeps in your home and when you last used it. Parts of Ubuntu
# itself (essential/required packages and what the desktop meta-package
# depends on) are left out.

APPS_DIR_USER=${XDG_DATA_HOME:-$HOME/.local/share}
APP_DESKTOP_DIRS=("$APPS_DIR_USER/applications" "$APPS_DIR_USER/flatpak/exports/share/applications"
  /var/lib/flatpak/exports/share/applications /var/lib/snapd/desktop/applications
  /usr/local/share/applications /usr/share/applications) # earlier folders override later ones
# never offered: removing these breaks the desktop, logins or package management
APP_CORE_RE='^(gnome-shell|gnome-shell-common|gdm3|gnome-session.*|ubuntu-session|systemd|systemd-sysv|sudo|apt|dpkg|network-manager|xserver-xorg-core|xwayland|snapd|polkitd|pkexec|policykit-1|plymouth|grub.*|shim.*|linux-image-.*|linux-generic.*)$'
APP_META_RE='^(ubuntu-desktop.*|ubuntu-minimal|ubuntu-standard|ubuntu-server|[a-z]+ubuntu-desktop|ubuntu-[a-z]+-desktop)$'
APP_EXEC_SKIP='^(env|sh|bash|dash|flatpak|snap|run|gtk-launch|gapplication|python3?|perl|java|exo-open|xdg-open|pkexec|sudo|wine|steam)$'
GNOME_APP_STATE=$APPS_DIR_USER/gnome-shell/application_state
APP_UNUSED_DAYS=90 APP_LARGE_MB=500

desktop_entries() { # → file name exec hidden snap flatpak (separated by \x1f: fields may be empty), per launcher
  local d files=()
  for d in "${APP_DESKTOP_DIRS[@]}"; do
    [[ -d $d ]] || continue
    for f in "$d"/*.desktop; do [[ -f $f ]] && files+=("$f"); done
  done
  ((${#files[@]})) || return 0
  awk -v OFS=$'\x1f' '
    function out() { if (typ == "Application") print f, name, ex, hid, snap, fp }
    FNR == 1 { if (f != "") out(); f = FILENAME; sec = ""; name = ""; ex = ""; hid = 0; typ = ""; snap = ""; fp = "" }
    { sub(/\r$/, "") }
    /^\[/ { sec = $0; next }
    sec == "[Desktop Entry]" {
      if ($0 ~ /^Name=/ && name == "") name = substr($0, 6)
      else if ($0 ~ /^Exec=/ && ex == "") ex = substr($0, 6)
      else if ($0 ~ /^(NoDisplay|Hidden)=true/) hid = 1
      else if ($0 ~ /^Type=/) typ = substr($0, 6)
      else if ($0 ~ /^X-SnapInstanceName=/) snap = substr($0, 20)
      else if ($0 ~ /^X-Flatpak=/) fp = substr($0, 11)
    }
    END { if (f != "") out() }' "${files[@]}" 2>/dev/null
}

exec_name() { # Exec= line → the program's name (skipping env, flatpak run, …)
  local w
  for w in $1; do
    w=${w//\"/}; w=${w//\'/}
    [[ $w == *=* || $w == -* || $w == %* ]] && continue
    w=${w##*/}
    [[ ${w,,} =~ $APP_EXEC_SKIP ]] && continue
    printf '%s' "$w"; return
  done
}

gnome_last_seen() { # desktop-id<TAB>epoch, from GNOME Shell's own record of app use
  [[ -f $GNOME_APP_STATE ]] || return 0
  grep -o '<application [^>]*>' "$GNOME_APP_STATE" 2>/dev/null |
    sed -n 's/.*id="\([^"]*\)".*last-seen="\([0-9]*\)".*/\1\t\2/p'
}

app_inventory() { # → "#hidden<TAB>N", then src<TAB>id<TAB>name<TAB>pkg_bytes<TAB>data_bytes<TAB>last_used<TAB>paths(\x1f)
  local file name ex hid snap fp base key src id line
  local -A seen=() a_src=() a_id=() a_name=() a_desk=() a_exec=() owner=() psize=() pskip=() fpsize=() last_seen=() claims=()
  local -a keys=() debfiles=() others=()
  while IFS=$'\x1f' read -r file name ex hid snap fp; do
    base=${file##*/}
    [[ -n ${seen[$base]:-} ]] && continue # a launcher in your own folder overrides the system one
    seen[$base]=1
    if ((hid)) || [[ $file == "$APPS_DIR_USER/applications/"* && -z $fp && -z $snap ]]; then
      others+=("${base%.desktop}" "$(exec_name "$ex")") # not listed, but its folders aren't "unshared"
      continue
    fi
    if [[ -n $fp || $file == */flatpak/exports/* ]]; then src=flatpak id=${fp:-${base%.desktop}}
    elif [[ -n $snap || $file == /var/lib/snapd/desktop/* ]]; then src=snap id=${snap:-${base%%_*}}
    else src=apt id=""; debfiles+=("$file"); fi # if dpkg owns it
    key=$src:${id:-$file}
    if [[ -z ${a_src[$key]:-} ]]; then keys+=("$key"); a_src[$key]=$src a_id[$key]=$id a_name[$key]=$name; fi
    a_desk[$key]+="${base%.desktop}"$'\n'
    [[ $src == apt ]] && a_exec[$key]+="$(exec_name "$ex")"$'\n' # snaps/flatpaks keep their data in ~/snap, ~/.var/app
  done < <(desktop_entries)

  # apt: which package owns each launcher; then sizes and what must stay
  if ((${#debfiles[@]})) && have dpkg; then
    while IFS= read -r line; do
      [[ $line == *": /"* ]] || continue
      id=${line%%: /*}; id=${id%%,*}; id=${id%%:*}
      owner[/${line#*: /}]=$id
    done < <(dpkg -S "${debfiles[@]}" 2>/dev/null)
    local -a pkgs=() newkeys=()
    local -A merged=()
    for key in "${keys[@]}"; do
      if [[ ${a_src[$key]} == apt ]]; then
        id=${owner[${key#apt:}]:-}
        if [[ -z $id ]]; then # not a package (a personal launcher): its folders still count as claimed
          mapfile -t -O "${#others[@]}" others <<<"${a_desk[$key]}${a_exec[$key]}"; continue
        fi
        if [[ -n ${merged[$id]:-} ]]; then # several launchers, one package (LibreOffice, …)
          a_desk[${merged[$id]}]+=${a_desk[$key]} a_exec[${merged[$id]}]+=${a_exec[$key]}; continue
        fi
        merged[$id]=$key a_id[$key]=$id; pkgs+=("$id")
      fi
      newkeys+=("$key")
    done
    keys=("${newkeys[@]}")
    if ((${#pkgs[@]})); then
      while IFS=$'\t' read -r id b pri ess; do
        psize[$id]=$((b * 1024))
        [[ $pri == required || $pri == important || $ess == yes ]] && pskip[$id]=1
      done < <(dpkg-query -W -f='${Package}\t${Installed-Size}\t${Priority}\t${Essential}\n' "${pkgs[@]}" 2>/dev/null)
      local metas=()
      mapfile -t metas < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null |
        awk -v re="$APP_META_RE" '$1 ~ /^ii/ && $2 ~ re {print $2}')
      ((${#metas[@]})) && while read -r id; do pskip[$id]=1; done < <(apt-cache depends --installed --no-recommends \
        --no-suggests "${metas[@]}" 2>/dev/null | awk '$1 == "Depends:" {gsub(/[<>]/, "", $2); print $2}')
    fi
  fi
  if have flatpak; then
    while IFS=$'\t' read -r id b; do fpsize[$id]=$(si_to_bytes "${b// /}"); done < <(flatpak list --app --columns=application,size 2>/dev/null)
  fi
  while IFS=$'\t' read -r id b; do last_seen[${id%.desktop}]=$b; done < <(gnome_last_seen)

  # folders each app keeps in your home: by package, launcher and program name (case-insensitive)
  local -A idx=() app_paths=()
  local d e n
  for d in "${XDG_CONFIG_HOME:-$HOME/.config}" "$APPS_DIR_USER" "$HOME/.cache"; do
    for e in "$d"/*/; do e=${e%/}; [[ -d $e && ! -L $e ]] && n=${e##*/} && idx[${n,,}]+="$e"$'\n'; done
  done
  local hidden=0 nm p pkgb datab last t
  local -A ubuntu_part=()
  for nm in "${others[@]}"; do # launchers that aren't listed still share folders
    [[ ${#nm} -ge 3 && ! ${nm,,} =~ $LEFTOVER_DENY ]] || continue
    while IFS= read -r p; do [[ -n $p ]] && claims[$p]=$((${claims[$p]:-0} + 1)); done <<<"${idx[${nm,,}]:-}"
  done
  for key in "${keys[@]}"; do
    src=${a_src[$key]} id=${a_id[$key]}
    if [[ $src == apt ]] && [[ -n ${pskip[$id]:-} || $id =~ $APP_CORE_RE || $id =~ $APP_META_RE ]]; then
      ubuntu_part[$key]=1 hidden=$((hidden + 1)) # hidden, but its folders still count as claimed below
    fi
    local -A mine=()
    while IFS= read -r nm; do
      [[ ${#nm} -ge 3 && ! ${nm,,} =~ $LEFTOVER_DENY ]] || continue
      while IFS= read -r p; do [[ -n $p ]] && mine[$p]=1; done <<<"${idx[${nm,,}]:-}"
    done < <(printf '%s\n' "$id" ${a_desk[$key]} ${a_exec[$key]} | sort -u)
    [[ $src == flatpak && -d $HOME/.var/app/$id ]] && mine[$HOME/.var/app/$id]=1
    [[ $src == snap && -d $HOME/snap/$id ]] && mine[$HOME/snap/$id]=1
    for p in "${!mine[@]}"; do is_protected "$p" && unset "mine[$p]"; done
    app_paths[$key]=$(printf '%s\n' "${!mine[@]}")
    for p in "${!mine[@]}"; do claims[$p]=$((${claims[$p]:-0} + 1)); done
    unset mine
  done
  printf '#hidden\t%d\n' "$hidden"
  for key in "${keys[@]}"; do
    [[ -z ${ubuntu_part[$key]:-} ]] || continue # part of Ubuntu: not listed
    src=${a_src[$key]} id=${a_id[$key]}
    local list=()
    while IFS= read -r p; do [[ -n $p && ${claims[$p]} == 1 ]] && list+=("$p"); done <<<"${app_paths[$key]}" # shared folders stay
    case $src in
      apt) pkgb=${psize[$id]:-0} ;;
      snap) pkgb=$(du_sum /var/lib/snapd/snaps/"${id}"_*.snap) ;;
      flatpak) pkgb=${fpsize[$id]:-0} ;;
    esac
    datab=0 last=0
    ((${#list[@]})) && datab=$(du_sum "${list[@]}") &&
      last=$(find "${list[@]}" -maxdepth 1 -printf '%T@\n' 2>/dev/null | sort -n | tail -n1) && last=${last%.*}
    while IFS= read -r nm; do [[ -n $nm ]] && t=${last_seen[$nm]:-0} && ((t > last)) && last=$t; done <<<"${a_desk[$key]}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$src" "$id" "${a_name[$key]:-$id}" "${pkgb:-0}" "${datab:-0}" "${last:-0}" \
      "$(IFS=$'\x1f'; printf '%s' "${list[*]}")"
  done
}

used_ago() { # EPOCH → "today" / "12 days ago" / "5 months ago" / "2 years ago" / "—"
  local d
  (($1 > 0)) || { printf '—'; return; }
  d=$(((EPOCHSECONDS - $1) / 86400))
  if ((d < 1)); then printf 'today'
  elif ((d < 60)); then printf '%d days ago' "$d"
  elif ((d < 730)); then printf '%d months ago' $((d / 30))
  else printf '%d years ago' $((d / 365)); fi
}

declare -a A_SRC=() A_ID=() A_NAME=() A_PKG=() A_DATA=() A_LAST=() A_PATHS=() A_VIEW=()
A_HIDDEN=0 A_SORT=size A_FILTER=all

load_apps() {
  local tmp line
  tmp=$(mktemp -p "$SESSION_TMP")
  (app_inventory >"$tmp") &
  UI_BUSY_TITLE="Uninstaller"
  ui_busy "Finding your apps and the space each one uses…" $! || { rm -f "$tmp"; return 1; }
  A_SRC=() A_ID=() A_NAME=() A_PKG=() A_DATA=() A_LAST=() A_PATHS=() U_SEL=()
  while IFS=$'\t' read -r -a line; do
    if [[ ${line[0]} == '#hidden' ]]; then A_HIDDEN=${line[1]}; continue; fi
    A_SRC+=("${line[0]}") A_ID+=("${line[1]}") A_NAME+=("${line[2]}") A_PKG+=("${line[3]}")
    A_DATA+=("${line[4]}") A_LAST+=("${line[5]}") A_PATHS+=("${line[6]:-}")
  done <"$tmp"
  rm -f "$tmp"
}

apps_view() { # A_SORT / A_FILTER → A_VIEW (indices into A_*)
  local i cut=$((EPOCHSECONDS - APP_UNUSED_DAYS * 86400)) big=$((APP_LARGE_MB * 1024 * 1024))
  A_VIEW=()
  mapfile -t A_VIEW < <(for i in "${!A_ID[@]}"; do
    case $A_FILTER in
      unused) ((A_LAST[i] > 0 && A_LAST[i] < cut)) || continue ;;
      large) ((A_PKG[i] + A_DATA[i] >= big)) || continue ;;
    esac
    case $A_SORT in
      size) printf '%020d\t%s\n' $((A_PKG[i] + A_DATA[i])) "$i" ;;
      used) printf '%020d\t%s\n' $((A_LAST[i] > 0 ? A_LAST[i] : 1)) "$i" ;;
      name) printf '%s\t%s\n' "${A_NAME[i],,}" "$i" ;;
    esac
  done | if [[ $A_SORT == size ]]; then sort -r; else sort; fi | cut -f2)
}

applist_row() {
  local i=${A_VIEW[$1]} mark="  " box src lbl sz used c
  (($2)) && mark="${ACCENT}▸${NC} "
  if [[ -n ${U_SEL[$i]:-} ]]; then box="${GREEN}●${NC}"; else box="${DIM}○${NC}"; fi
  case ${A_SRC[i]} in snap) c=$MAGENTA ;; flatpak) c=$BLUE ;; *) c=$CYAN ;; esac
  fitv src "${A_SRC[i]}" 7
  fitv lbl "${A_NAME[i]}" $((UI_W - 44))
  (($2)) && lbl="${BOLD}$lbl${NC}"
  humanv sz $((A_PKG[i] + A_DATA[i])); printf -v sz '%9s' "$sz"
  used=$(used_ago "${A_LAST[i]}"); printf -v used '%-14s' "$used"
  fl " $mark$box $c$src$NC $lbl $sz  ${DIM}$used${NC}"
}
applist_text() { TEXT=${A_NAME[${A_VIEW[$1]}]}; }
applist_top() {
  local f
  case $A_FILTER in unused) f="not used for ${APP_UNUSED_DAYS}+ days" ;; large) f="${APP_LARGE_MB} MB or more" ;; *) f="all apps" ;; esac
  fl ""
  fl "  ${BOLD}$(plural ${#A_VIEW[@]} app)${NC} ${DIM}· $f · by $A_SORT${NC}"
  ((A_HIDDEN)) && fl "  ${DIM}Not shown: $(plural "$A_HIDDEN" part) of Ubuntu itself, which can't be removed safely${NC}"
  fl ""
}
applist_bottom() {
  local i tot=0
  for i in "${!U_SEL[@]}"; do tot=$((tot + A_PKG[i] + A_DATA[i])); done
  fl ""
  fl "  ${BOLD}Selected${NC} $(plural ${#U_SEL[@]} app)$( ((tot)) && echo " · $(human "$tot")")   ${DIM}size = app + its folders in your home${NC}"
}

app_details() { # INDEX
  local i=$1 p
  V_LINES=("" "  ${BOLD}${A_NAME[i]}${NC}  ${DIM}${A_SRC[i]} · ${A_ID[i]}${NC}" ""
    "  $(printf '%-14s' "App") $(human "${A_PKG[i]}")"
    "  $(printf '%-14s' "Your data") $(human "${A_DATA[i]}")"
    "  $(printf '%-14s' "Last used") $(used_ago "${A_LAST[i]}")" "")
  if [[ -n ${A_PATHS[i]} ]]; then
    V_LINES+=("  ${BOLD}Folders in your home${NC} ${DIM}(offered for the Trash after uninstalling)${NC}")
    while IFS= read -r p; do
      [[ -n $p ]] && V_LINES+=("  $(printf '%9s' "$(human "$(du_sum "$p")")")  ${p/#$HOME/\~}")
    done < <(tr '\037' '\n' <<<"${A_PATHS[i]}")
  else V_LINES+=("  ${DIM}No folders of its own found in your home.${NC}"); fi
  V_LINES+=("" "  ${DIM}“Last used” comes from GNOME's record of opened apps, or the newest change in the app's folders.${NC}")
  ui_view "${A_NAME[i]}"
}

uninstall_apps() { # uninstall U_SEL (indices into A_*), then offer their folders for the Trash
  local i apt_pkgs=() names=() needs_root=0 body title sim others extra core
  for i in "${!U_SEL[@]}"; do
    names+=("${A_NAME[i]}")
    [[ ${A_SRC[i]} == apt ]] && apt_pkgs+=("${A_ID[i]}")
    [[ ${A_SRC[i]} != flatpak ]] && needs_root=1
  done
  body=$(printf '%s, ' "${names[@]}"); body=${body%, }
  title="Uninstall $(plural ${#names[@]} app)?"
  if ((${#apt_pkgs[@]})); then
    apt_check_removal "${apt_pkgs[@]}" || return
    if ((APT_EXTRA_N)); then
      title="⚠ Also removes $(plural "$APT_EXTRA_N" "other package")! Continue?"
      body=$APT_EXTRA_TEXT
    fi
  fi
  ui_confirm "$title" "$body" n || return
  ((needs_root)) && { ensure_sudo "Removing apps needs administrator rights." || return; }
  new_tasks
  for i in "${!U_SEL[@]}"; do add_task "Uninstall ${A_NAME[i]} (${A_SRC[i]})" task_uninstall "${A_SRC[i]}:${A_ID[i]}:$i"; done
  run_tasks "Uninstalling"
  refresh_sysinfo
  show_run_results "Uninstall complete"
  local left=() p tot=0
  for i in "${!T_STATE[@]}"; do
    [[ ${T_STATE[i]} == ok ]] || continue
    while IFS= read -r p; do [[ -n $p && -e $p ]] && left+=("$p"); done < <(tr '\037' '\n' <<<"${A_PATHS[${T_ARG[i]##*:}]}")
  done
  if ((${#left[@]})); then
    for p in "${left[@]}"; do tot=$((tot + $(du_sum "$p"))); done
    body=$(printf '%s, ' "${left[@]/#$HOME/\~}"); body=${body%, }
    if ui_confirm "Move their $(plural ${#left[@]} folder) ($(human "$tot")) to the Trash?" "$body" n; then
      UNDO_BATCH=()
      for p in "${left[@]}"; do move_to_trash "$p" >/dev/null 2>&1; done
      if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would move $(plural ${#left[@]} folder) to Trash"
      else toast "${GREEN}✔${NC} Moved $(plural ${#left[@]} folder) to Trash — z on the home screen puts them back"; fi
    fi
  fi
  load_apps
  apps_view
}

apps_menu() {
  local cur=0 scroll=0 i
  load_apps || return
  apps_view
  while :; do
    L_TITLE="Uninstaller" L_TOP=applist_top L_BOTTOM=applist_bottom L_ROW=applist_row L_FOCUSABLE="" L_TEXT=applist_text
    L_VIEW=0 L_COUNT=${#A_VIEW[@]} L_CUR=$cur L_SCROLL=$scroll
    ((L_COUNT)) || L_VIEW=1
    hints space select "!u" uninstall enter details s sort f filter / find p "all packages" q back
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL
    i=${A_VIEW[cur]:-}
    case $KEY in
      space) [[ -n $i ]] && { if [[ -n ${U_SEL[$i]:-} ]]; then unset "U_SEL[$i]"; else U_SEL[$i]=1; fi; list_move 1; cur=$L_CUR; } ;;
      u) [[ -n $i ]] || continue; ((${#U_SEL[@]})) || U_SEL[$i]=1; uninstall_apps; cur=0 scroll=0 ;;
      enter | right) [[ -n $i ]] && app_details "$i" ;;
      s) case $A_SORT in size) A_SORT=used ;; used) A_SORT=name ;; *) A_SORT=size ;; esac; apps_view; cur=0 scroll=0 ;;
      f) case $A_FILTER in all) A_FILTER=unused ;; unused) A_FILTER=large ;; *) A_FILTER=all ;; esac; apps_view; cur=0 scroll=0 ;;
      p) U_SEL=(); pkg_search_menu; load_apps; apps_view; cur=0 scroll=0 ;;
      q | esc | left | backspace) U_SEL=(); return ;;
    esac
  done
}

# apt must remove exactly what was asked for — and never a part of Ubuntu itself.
apt_check_removal() { # PKG... → APT_EXTRA_N, APT_EXTRA_TEXT; returns 1 (with a toast) when it must not go ahead
  local sim others core
  APT_EXTRA_N=0 APT_EXTRA_TEXT=""
  if ! sim=$(LC_ALL=C apt-get -s purge "$@" 2>&1); then
    toast "${RED}✘${NC} apt can't remove this cleanly: $(grep -m1 '^E:' <<<"$sim" | cut -c4-)"
    return 1
  fi
  core=$(grep '^Purg' <<<"$sim" | awk '{print $2}' | grep -E "$APP_CORE_RE|^linux-image-$(uname -r)\$" | head -n 3 | paste -sd, - | sed 's/,/, /g')
  if [[ -n $core ]]; then
    toast "${RED}✘${NC} Not removed: apt would also take $core, which Ubuntu needs to run."
    return 1
  fi
  local purg=()
  mapfile -t purg < <(grep '^Purg' <<<"$sim" | awk '{print $2}')
  core=$( ((${#purg[@]})) && dpkg-query -W -f='${Package} ${Priority} ${Essential}\n' "${purg[@]}" 2>/dev/null |
    awk '$2 == "required" || $2 == "important" || $3 == "yes" {print $1}' | head -n 3 | paste -sd, - | sed 's/,/, /g')
  if [[ -n $core ]]; then
    toast "${RED}✘${NC} Not removed: $core is marked as required by Ubuntu. Use apt yourself if you're sure."
    return 1
  fi
  others=$(printf '%s\n' "${purg[@]}" | grep -vxF -f <(printf '%s\n' "$@"))
  APT_EXTRA_N=$(grep -c . <<<"$others")
  APT_EXTRA_TEXT="$(head -n 6 <<<"$others" | paste -sd, - | sed 's/,/, /g')$( ((APT_EXTRA_N > 6)) && echo ", …")"
  grep -qE "$APP_META_RE" <<<"$others" && APT_EXTRA_TEXT+=" — includes Ubuntu's desktop package list, so future release upgrades may skip apps"
  return 0
}

# ───────────────────────────── startup items ────────────────────────────────

desktop_get() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }

desktop_set() { # FILE KEY VALUE
  if grep -q "^$2=" "$1"; then run sed -i "s|^$2=.*|$2=$3|" "$1"
  else run sed -i "/^\[Desktop Entry\]/a $2=$3" "$1"; fi
}

is_disabled() {
  [[ $(desktop_get "$1" Hidden) == true || $(desktop_get "$1" X-GNOME-Autostart-enabled) == false ]]
}

AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

load_startup() { # SHOW_ALL → S_FILE S_NAME S_ON S_HIDDEN
  declare -A eff=()
  local f b
  S_FILE=() S_NAME=() S_ON=() S_HIDDEN=0
  for f in /etc/xdg/autostart/*.desktop "$AUTOSTART_DIR"/*.desktop; do
    [[ -f $f ]] && eff[$(basename "$f")]=$f # a user entry overrides the system one
  done
  while read -r b; do
    [[ -n $b ]] || continue
    f=${eff[$b]}
    if (($1 == 0)) && [[ $(desktop_get "$f" NoDisplay) == true ]]; then ((++S_HIDDEN)); continue; fi
    S_FILE+=("$f")
    b=$(desktop_get "$f" Name); S_NAME+=("${b:-$(basename "$f" .desktop)}")
    if is_disabled "$f"; then S_ON+=(0); else S_ON+=(1); fi
  done < <(printf '%s\n' "${!eff[@]}" | sort)
}

startup_toggle() { # IDX — flip an entry, copying system entries to the user's autostart dir
  local f=${S_FILE[$1]} target
  target="$AUTOSTART_DIR/$(basename "$f")"
  if [[ $f != "$target" ]]; then run mkdir -p "$AUTOSTART_DIR"; run cp "$f" "$target"; fi
  ((DRY_RUN)) && target=$f
  if ((S_ON[$1])); then
    desktop_set "$target" Hidden true; desktop_set "$target" X-GNOME-Autostart-enabled false
  else
    desktop_set "$target" Hidden false; desktop_set "$target" X-GNOME-Autostart-enabled true
  fi
}

startup_row() {
  local i=$1 mark="  " st lbl src
  (($2)) && mark="${ACCENT}▸${NC} "
  if ((S_ON[i])); then st="${GREEN}● on ${NC}"; else st="${DIM}○ off${NC}"; fi
  fitv lbl "${S_NAME[i]}" 38
  (($2)) && lbl="${BOLD}$lbl${NC}"
  if [[ ${S_FILE[i]} == "$AUTOSTART_DIR"/* ]]; then src=user; else src=system; fi
  fl " $mark$st  $lbl ${DIM}$src${NC}"
}

startup_text() { TEXT=${S_NAME[$1]}; }
startup_top() {
  local i on=0
  for i in "${S_ON[@]}"; do ((i)) && ((++on)); done
  fl ""
  fl "  ${BOLD}$on of ${#S_ON[@]} apps start at login${NC} ${DIM}— fewer startup apps means a faster login${NC}"
  fl ""
}

startup_bottom() {
  local f=${S_FILE[$L_CUR]} c
  c=$(desktop_get "$f" Comment)
  fl ""
  fitv c "${c:-$(desktop_get "$f" Exec)}" $((UI_W - 6))
  fl "  ${ACCENT}ℹ${NC} ${DIM}$c${NC}"
  ((S_HIDDEN)) && fl "  ${DIM}$S_HIDDEN hidden system services not shown — press s to show them${NC}"
  return 0
}

startup_menu() {
  local show_all=0 cur=0 scroll=0
  load_startup "$show_all"
  while :; do
    L_TITLE="Startup Items" L_TOP=startup_top L_BOTTOM=startup_bottom L_ROW=startup_row L_FOCUSABLE="" L_TEXT=startup_text
    L_VIEW=0 L_COUNT=${#S_FILE[@]} L_CUR=$cur L_SCROLL=$scroll
    hints "!space" "on/off" s "$( ((show_all)) && echo "hide services" || echo "show services")" q back "↑↓" move
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL
    case $KEY in
      space | enter)
        ((${#S_FILE[@]})) || continue
        startup_toggle "$cur" >/dev/null 2>&1
        if ((DRY_RUN)); then
          toast "${MAGENTA}[dry-run]${NC} Would turn ${S_NAME[cur]} $( ((S_ON[cur])) && echo off || echo on)"
        else
          toast "${GREEN}✔${NC} ${S_NAME[cur]} will $( ((S_ON[cur])) && echo "no longer start" || echo "start") at login"
          load_startup "$show_all"
        fi ;;
      s) show_all=$((1 - show_all)); load_startup "$show_all"; cur=0 scroll=0 ;;
      q | esc | left | backspace) return ;;
    esac
  done
}

# ───────────────────────────── maintenance ──────────────────────────────────

m_apt_update()     { run_root apt-get update; }
m_apt_upgrade()    { run_root env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; }
m_snap_refresh()   { run_root snap refresh; }
m_flatpak_update() { run flatpak update -y --noninteractive; }
m_dpkg_configure() { run_root dpkg --configure -a; }
m_apt_fix()        { run_root env DEBIAN_FRONTEND=noninteractive apt-get -f install -y; }
m_flatpak_unused() { run flatpak uninstall --unused -y --noninteractive; }
m_fstrim()         { run_root fstrim -av; }
m_fc_cache()       { run fc-cache -f; }
m_updatedb()       { run_root updatedb; }
m_drop_caches_pre() { MEM_BEFORE=$(free -b | awk '/^Mem:/ {print $7}'); }
m_drop_caches()    { run_root sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'; }
m_drop_caches_post() {
  local after
  after=$(free -b | awk '/^Mem:/ {print $7}')
  T_INFO[$3]="available RAM $(human "$MEM_BEFORE") → $(human "$after")"
}
m_fstrim_post() {
  (($2 == 0)) || return 0
  T_INFO[$3]="$(grep -c 'trimmed' "$4") filesystems trimmed"
}

# What "Update everything" would change, without changing anything. apt's list
# is as of its last refresh (the update itself refreshes first, so it may find more).
pending_updates() { # → source<TAB>name<TAB>new version
  have apt && LC_ALL=C apt list --upgradable 2>/dev/null | awk -F'[/ ]' '/upgradable from/ {print "apt\t" $1 "\t" $3}'
  have snap && LC_ALL=C timeout 30 snap refresh --list 2>/dev/null | awk 'NR > 1 && NF >= 2 {print "snap\t" $1 "\t" $2}'
  have flatpak && timeout 30 flatpak remote-ls --updates --columns=application,version 2>/dev/null |
    awk -F'\t' 'NF && $1 != "Application ID" {print "flatpak\t" $1 "\t" ($2 == "" ? "new build" : $2)}'
  return 0
}

update_preview() { # → 0 to go ahead; lists what will be updated in the confirmation
  local tmp n_apt n_snap n_flat total line src name ver summary
  tmp=$(mktemp -p "$SESSION_TMP")
  (pending_updates >"$tmp") &
  UI_BUSY_TITLE="Maintenance"
  ui_busy "Checking what has an update…" $! || { rm -f "$tmp"; return 1; }
  n_apt=$(grep -c $'^apt\t' "$tmp") n_snap=$(grep -c $'^snap\t' "$tmp") n_flat=$(grep -c $'^flatpak\t' "$tmp")
  total=$((n_apt + n_snap + n_flat))
  CONFIRM_LINES=()
  while IFS=$'\t' read -r src name ver; do CONFIRM_LINES+=("$(printf '%-8s %s %s' "$src" "$name" "${DIM}→ $ver${NC}")"); done <"$tmp"
  rm -f "$tmp"
  if ((total == 0)); then
    CONFIRM_LINES=()
    ui_confirm "Everything looks up to date" "apt's list may be a few days old — refresh and update anyway?" n
    return
  fi
  summary="$( ((n_apt)) && printf '%s apt · ' "$n_apt")$( ((n_snap)) && printf '%s snap · ' "$n_snap")$( ((n_flat)) && printf '%s flatpak · ' "$n_flat")"
  ui_confirm "Update $(plural "$total" package)?" "${summary% · } — no further questions" y
}

# Lasting limits, so the same junk doesn't pile up again after a clean.
snap_retain() { snap get system refresh.retain 2>/dev/null; } # empty = snapd's default
m_snap_retain()   { run_root snap set system refresh.retain=2; }
m_snap_unretain() { run_root snap unset system refresh.retain; }
m_snap_retain_post() { (($2 == 0)) && T_INFO[$3]="older versions go at the next snap refresh — or clean them now in System Junk"; return 0; }

JOURNALD_DROPIN=/etc/systemd/journald.conf.d/60-clean-my-ubuntu.conf
journal_cap() { sed -n 's/^SystemMaxUse=\([0-9]*\)M$/\1/p' "$JOURNALD_DROPIN" 2>/dev/null; } # MB, empty = no limit of ours
m_journal_cap() { # writes a journald drop-in; journald applies it on restart
  run_root sh -c 'mkdir -p "${1%/*}" && printf "# Written by Clean My Ubuntu (Maintenance)\n[Journal]\nSystemMaxUse=%sM\n" "$2" >"$1" && systemctl restart systemd-journald' \
    sh "$JOURNALD_DROPIN" "$JOURNAL_KEEP_MB"
}
m_journal_uncap() { run_root sh -c 'rm -f -- "$1" && systemctl restart systemd-journald' sh "$JOURNALD_DROPIN"; }

maintenance_menu() {
  local root=1
  while :; do
    local retain cap
    retain=$(have snap && snap_retain) cap=$(journal_cap)
    M_KEY=(1 2 3 4 5 6 7 8 9)
    M_LABEL=("Update everything" "Repair packages" "Unused Flatpak runtimes" "TRIM SSDs" "Free up RAM"
      "Rebuild font cache" "Update locate database" "Keep fewer snap versions" "Limit journal size")
    M_DESC=("Upgrade apt, snap and flatpak packages" "Finish interrupted installs, fix broken dependencies"
      "Remove runtimes no installed app uses" "Tell SSDs which blocks are free (fstrim)"
      "Drop the page cache — Linux reclaims it anyway" "Fix missing or stale fonts (fc-cache)"
      "Refresh the index used by locate"
      "$([[ $retain == 2 ]] && echo "On: 2 versions per snap — choose to go back to the default" || echo "Keep 2 versions of each snap instead of 3${retain:+ (now: $retain)}")"
      "$([[ -n $cap ]] && echo "On: at most $cap MB — choose to change or remove" || echo "Never let system logs grow past ${JOURNAL_KEEP_MB} MB (Settings → Journal size limit)")")
    ui_menu "Maintenance" || return
    new_tasks
    root=1
    case $MENU_IDX in
      0)
        update_preview || continue
        add_task "Refresh package lists" m_apt_update
        add_task "Upgrade apt packages" m_apt_upgrade
        have snap && add_task "Refresh snaps" m_snap_refresh
        have flatpak && add_task "Update flatpaks" m_flatpak_update ;;
      1) add_task "Configure unpacked packages" m_dpkg_configure; add_task "Fix broken dependencies" m_apt_fix ;;
      2)
        have flatpak || { toast "${YELLOW}!${NC} Flatpak is not installed."; continue; }
        add_task "Remove unused Flatpak runtimes" m_flatpak_unused; root=0 ;;
      3) add_task "TRIM mounted filesystems" m_fstrim ;;
      4) add_task "Drop page cache" m_drop_caches ;;
      5) add_task "Rebuild font cache" m_fc_cache; root=0 ;;
      6)
        have updatedb || { toast "${YELLOW}!${NC} locate/plocate is not installed."; continue; }
        add_task "Update locate database" m_updatedb ;;
      7)
        have snap || { toast "${YELLOW}!${NC} Snap is not installed."; continue; }
        if [[ $retain == 2 ]]; then
          ui_confirm "Go back to snapd's default?" "Snap keeps its usual number of old versions again (3 on most systems)." n || continue
          add_task "Use the default number of snap versions" m_snap_unretain
        else
          ui_confirm "Keep only 2 versions of each snap?" \
            "The running version and one to roll back to. Snap removes the extra ones itself at each refresh." y || continue
          add_task "Keep 2 versions of each snap" m_snap_retain
        fi ;;
      8)
        have journalctl || { toast "${YELLOW}!${NC} This system doesn't use the systemd journal."; continue; }
        if [[ -n $cap && $cap == "$JOURNAL_KEEP_MB" ]]; then
          ui_confirm "Remove the journal size limit?" "systemd goes back to its default (up to 10% of the disk, at most 4 GB)." n || continue
          add_task "Remove journal size limit" m_journal_uncap
        else
          ui_confirm "Limit system logs to ${JOURNAL_KEEP_MB} MB?" \
            "journald deletes its oldest logs to stay under the limit. Change the number in Settings → Journal size limit." y || continue
          add_task "Limit journal to ${JOURNAL_KEEP_MB} MB" m_journal_cap
        fi ;;
    esac
    ((root)) && { ensure_sudo "${M_LABEL[MENU_IDX]} needs administrator rights." || continue; }
    run_tasks "${M_LABEL[MENU_IDX]}"
    refresh_sysinfo
    show_run_results "${M_LABEL[MENU_IDX]}"
  done
}

# ───────────────────────────── overview ─────────────────────────────────────

overview_lines() {
  local os cpu t s u a fs pct barv max=0 b p
  os=$(. /etc/os-release && echo "$PRETTY_NAME")
  cpu=$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2; exit}')
  printf '  %sSystem%s\n' "$BOLD" "$NC"
  printf '  %s%-10s%s %s\n' "$DIM" "OS" "$NC" "$os" "$DIM" "Kernel" "$NC" "$(uname -r)" \
    "$DIM" "Uptime" "$NC" "$(uptime -p | sed 's/^up //')" "$DIM" "CPU" "$NC" "${cpu:-unknown} ($(nproc) threads)" \
    "$DIM" "Packages" "$NC" "$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l) apt$(have snap && echo ", $(($(snap list 2>/dev/null | wc -l) - 1)) snap")$(have flatpak && echo ", $(flatpak list 2>/dev/null | wc -l) flatpak")"

  printf '\n  %sStorage%s\n' "$BOLD" "$NC"
  df -B1 --output=target,size,used,avail,fstype -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null |
    tail -n +2 | while read -r t s u a fs; do
      ((s > 0)) || continue
      pct=$((u * 100 / s))
      mini_bar barv "$pct" 24
      printf '  %-18s %s %3d%%  %s free of %s  %s%s%s\n' "$t" "$barv" "$pct" "$(human "$a")" "$(human "$s")" "$DIM" "$fs" "$NC"
    done

  disk_history_lines
  hidden_space_lines

  printf '\n  %sLargest folders in your home%s\n' "$BOLD" "$NC"
  while IFS=$'\t' read -r b p; do
    ((max == 0)) && max=$b
    size_bar barv "$b" "$max" 24
    printf '  %s %9s  %s\n' "$barv" "$(human "$b")" "${p/#$HOME/\~}"
  done < <(du -xb --max-depth=1 "$HOME" 2>/dev/null | sort -rn | sed -n '2,13p')
}

timeshift_snapshot_dirs() { # rsync-mode Timeshift keeps snapshots in /timeshift on the backup disk
  local d
  for d in /timeshift/snapshots /run/timeshift/*/backup/timeshift/snapshots /run/timeshift/backup/timeshift/snapshots; do
    [[ -d $d ]] && printf '%s\n' "$d"
  done
  return 0
}

# Space that is in use but doesn't show up in any of your folders. Report only:
# each of these is a choice for the user, not junk.
hidden_space_lines() {
  local rows=() s u a fs name type size d n b
  read -r s u a fs < <(df -B1 --output=size,used,avail,fstype / 2>/dev/null | tail -n1)
  # ext4 reserves 5% by default; a bigger gap means something else (a quota) limits "free"
  if [[ $fs == ext[234] ]] && ((s > 0 && s - u - a > 0 && (s - u - a) * 100 / s <= 10)); then
    rows+=("Reserved on / for the system"$'\t'"$((s - u - a))"$'\t'"ext4 keeps ~5% for root, so Ubuntu still runs when the disk is full")
  fi
  while read -r name type size; do
    [[ $type == file ]] && rows+=("Swap file $name"$'\t'"$size"$'\t'"extra memory on disk; shrinking it is possible but needs care")
  done < <(swapon --show=NAME,TYPE,SIZE --bytes --noheadings 2>/dev/null)
  while IFS= read -r d; do
    n=$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    ((n > 0)) || continue
    b=$(timeout 30 du -sb -- "$d" 2>/dev/null | cut -f1) # hard-linked files count once
    rows+=("Timeshift: $(plural "$n" snapshot)"$'\t'"${b:-0}"$'\t'"delete old ones in Timeshift — never by hand$([[ -z $b ]] && echo " (size needs sudo)")")
  done < <(timeshift_snapshot_dirs)
  ((${#rows[@]})) || return 0
  printf '\n  %sSpace outside your folders%s\n' "$BOLD" "$NC"
  printf '%s\n' "${rows[@]}" | while IFS=$'\t' read -r name b d; do
    printf '  %-30s %9s  %s%s%s\n' "$name" "$( ((b > 0)) && human "$b" || echo "?")" "$DIM" "$d" "$NC"
  done
}

overview() {
  local tmp
  tmp=$(mktemp -p "$SESSION_TMP")
  (overview_lines >"$tmp") &
  UI_BUSY_TITLE="System Overview"
  ui_busy "Measuring your system… (large home folders take a moment)" $! || { rm -f "$tmp"; return; }
  mapfile -t V_LINES <"$tmp"
  rm -f "$tmp"
  V_LINES=("" "${V_LINES[@]}")
  ui_view "System Overview"
}

# ───────────────────────────── space lens ───────────────────────────────────
#
# Interactive disk map: entries of a folder sorted by size, drill in with →,
# go up with ←, select and move to Trash. Sizes are cached per folder.

SL_TMP=""
SL_DIR=""
SL_TOTAL=0
declare -A SL_CACHE=() SL_SEL=()
declare -a SL_SIZE=() SL_PATH=() SL_HUMAN=()

human_lines() { # bytes per line on stdin → human sizes, one awk process for all
  awk '{b = $1; split("B KB MB GB TB PB", u, " "); i = 1
        while (b >= 1024 && i < 6) {b /= 1024; i++}
        if (i == 1) printf "%d B\n", b; else printf "%.1f %s\n", b, u[i]}'
}

sl_load() { # DIR — load DIR's entries into SL_*; returns 1 if cancelled
  local dir=$1 f b p
  [[ -n $SL_TMP ]] || SL_TMP=$(mktemp -d -p "$SESSION_TMP") || return 1
  f=${SL_CACHE[$dir]:-}
  if [[ -z $f || ! -s $f ]]; then
    f=$(mktemp -p "$SL_TMP") || return 1
    (try_root du -xab --max-depth=1 -- "$dir" 2>/dev/null | sort -t$'\t' -k1,1rn >"$f") &
    UI_BUSY_TITLE="Space Lens"
    ui_busy "Measuring ${dir/#$HOME/\~}…" $! || { rm -f "$f"; return 1; }
    SL_CACHE[$dir]=$f
  fi
  SL_SIZE=() SL_PATH=() SL_SEL=() SL_TOTAL=0
  while IFS=$'\t' read -r b p; do
    if [[ $p == "$dir" ]]; then SL_TOTAL=$b; continue; fi
    SL_SIZE+=("$b") SL_PATH+=("$p")
    ((${#SL_PATH[@]} >= 500)) && break
  done <"$f"
  mapfile -t SL_HUMAN < <(((${#SL_SIZE[@]})) && printf '%s\n' "${SL_SIZE[@]}" | human_lines)
  SL_DIR=$dir
}

sl_row() {
  local i=$1 mark="  " box name barv sz pct clr nw
  (($2)) && mark="${ACCENT}▸${NC} "
  if [[ -n ${SL_SEL[$i]} ]]; then box="${GREEN}●${NC}"; else box="${DIM}○${NC}"; fi
  size_bar barv "${SL_SIZE[i]}" "${SL_SIZE[0]}" 20
  size_colorv clr "${SL_SIZE[i]}"
  printf -v sz '%9s' "${SL_HUMAN[i]}"
  printf -v pct '%3d%%' $((SL_SIZE[i] * 100 / (SL_TOTAL > 0 ? SL_TOTAL : 1)))
  nw=$((UI_W - 46)); ((nw < 12)) && nw=12
  name=${SL_PATH[i]##*/}
  if [[ -d ${SL_PATH[i]} && ! -L ${SL_PATH[i]} ]]; then
    fitv name "$name/" "$nw"; name="${BLUE}${BOLD}$name${NC}"
  else
    fitv name "$name" "$nw"; (($2)) && name="${BOLD}$name${NC}"
  fi
  fl " $mark$box $barv $clr$sz$NC ${DIM}$pct${NC}  $name"
}

sl_text() { TEXT=${SL_PATH[$1]##*/}; }
sl_top() {
  local crumb=${SL_DIR/#$HOME/\~}
  fl ""
  fitv crumb "$crumb" $((UI_W - 30))
  local tt ni; humanv tt "$SL_TOTAL"; pluralv ni ${#SL_PATH[@]} item
  fl "  ${BOLD}📁 ${crumb%%+( )}${NC}   ${DIM}$tt · $ni${NC}"
  fl ""
  ((${#SL_PATH[@]})) || fl "  ${DIM}This folder is empty — press ← to go up.${NC}"
  return 0
}

sl_bottom() {
  local i n=0 tot=0 p=${SL_PATH[$L_CUR]:-} kind info
  for i in "${!SL_SEL[@]}"; do tot=$((tot + SL_SIZE[i])); ((++n)); done
  fl ""
  local sn st; pluralv sn "$n" item; humanv st "$tot"
  fl "  ${BOLD}Selected${NC} $sn · ${BOLD}$st${NC}"
  if [[ -n $p ]]; then
    if [[ -L $p ]]; then kind="link"; elif [[ -d $p ]]; then kind="folder — press → to open"; else kind="file"; fi
    fitv info "${p/#$HOME/\~}  ($kind)" $((UI_W - 6))
    fl "  ${ACCENT}ℹ${NC} ${DIM}$info${NC}"
  fi
}

sl_trash() { # CURSOR
  local i p n=0 tot=0 bad=0 fail=0 paths=()
  ((${#SL_SEL[@]})) || SL_SEL[$1]=1
  for i in "${!SL_SEL[@]}"; do
    p=${SL_PATH[i]}
    if [[ $p != "$HOME"/* ]] || is_protected "$p"; then ((++bad)); continue; fi
    paths+=("$p"); tot=$((tot + SL_SIZE[i])); ((++n))
  done
  if ((n == 0)); then
    SL_SEL=()
    toast "${YELLOW}!${NC} Only items inside your home folder can be moved to Trash here."
    return
  fi
  ui_confirm "Move $(plural "$n" item) to Trash?" "$(human "$tot")$( ((bad)) && echo " · $bad item(s) outside home skipped") — press z to undo." y || return
  UNDO_BATCH=()
  for p in "${paths[@]}"; do move_to_trash "$p" >/dev/null 2>&1 || ((++fail)); done
  if ((DRY_RUN)); then
    toast "${MAGENTA}[dry-run]${NC} Would move $(plural "$n" item) ($(human "$tot")) to Trash"
    SL_SEL=()
    return
  fi
  SL_CACHE=() # every ancestor's size changed
  sl_load "$SL_DIR"
  refresh_sysinfo
  if ((fail)); then toast "${YELLOW}!${NC} Moved $((n - fail)) of $n items to Trash ($fail failed) — z to undo."
  else toast "${GREEN}✔${NC} Moved $(plural "$n" item) ($(human "$tot")) to Trash — press z to undo"; fi
}

space_lens() { # START_DIR
  local cur=0 scroll=0 p prev i parent
  declare -A pos=()
  sl_load "$(realpath -- "$1")" || return
  while :; do
    L_TITLE="Space Lens" L_TOP=sl_top L_BOTTOM=sl_bottom L_ROW=sl_row L_FOCUSABLE="" L_TEXT=sl_text L_VIEW=0
    L_COUNT=${#SL_PATH[@]} L_CUR=$cur L_SCROLL=$scroll
    if ((${#UNDO_BATCH[@]})); then hints "→" open "←" up space select "!t" "move to Trash" z undo o "show in Files" q close
    else hints "→" open "←" up space select "!t" "move to Trash" o "show in Files" r refresh q close; fi
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL p=${SL_PATH[cur]:-}
    case $KEY in
      enter | right)
        [[ -n $p && -d $p && ! -L $p ]] || continue
        pos[$SL_DIR]="$cur $scroll"
        sl_load "$p" && cur=0 scroll=0 ;;
      left | backspace)
        [[ $SL_DIR == / ]] && continue
        prev=$SL_DIR parent=$(dirname "$SL_DIR")
        sl_load "$parent" || continue
        if [[ -n ${pos[$parent]:-} ]]; then read -r cur scroll <<<"${pos[$parent]}"
        else
          cur=0 scroll=0
          for i in "${!SL_PATH[@]}"; do [[ ${SL_PATH[i]} == "$prev" ]] && { cur=$i; break; }; done
        fi ;;
      space)
        [[ -n $p ]] || continue
        if [[ -n ${SL_SEL[$cur]} ]]; then unset "SL_SEL[$cur]"; else SL_SEL[$cur]=1; fi
        list_move 1; cur=$L_CUR ;;
      o)
        [[ -n $p ]] || continue
        if [[ -d $p ]]; then xdg-open "$p" >/dev/null 2>&1 & else xdg-open "$(dirname "$p")" >/dev/null 2>&1 & fi
        disown 2>/dev/null
        toast "${ACCENT}↗${NC} Opened in Files" ;;
      r) unset "SL_CACHE[$SL_DIR]"; sl_load "$SL_DIR" ;;
      t | delete) sl_trash "$cur" ;;
      z)
        ((${#UNDO_BATCH[@]})) || continue
        undo_trash; SL_CACHE=(); sl_load "$SL_DIR"; refresh_sysinfo; undo_toast ;;
      q | esc) return ;;
    esac
  done
}

space_lens_menu() {
  while :; do
    M_KEY=(1 2 3)
    M_LABEL=("Home folder" "Whole disk" "Choose a folder…")
    M_DESC=("Explore ${HOME}" "Explore / — use sudo for exact sizes of system folders" "Any folder you like")
    ui_menu "Space Lens" || return
    case $MENU_IDX in
      0) space_lens "$HOME" ;;
      1) space_lens / ;;
      2)
        ui_input "Folder:" "$HOME" || continue
        REPLY_TEXT=${REPLY_TEXT/#\~/$HOME}
        if [[ -d $REPLY_TEXT ]]; then space_lens "$REPLY_TEXT"; else toast "${RED}✘${NC} Not a folder: $REPLY_TEXT"; fi ;;
    esac
  done
}

# ───────────────────────────── duplicate finder ─────────────────────────────
#
# Same size → same hash of the first 64 KB → same full MD5. Hidden folders
# and node_modules are skipped. The oldest copy of each group is kept.

dedupe_on() { # FIELDS — keep only lines whose key (first N tab fields) occurs more than once
  awk -F'\t' -v k="$1" '{key = $1; for (j = 2; j <= k; j++) key = key FS $j
                          n[key]++; line[NR] = $0; kk[NR] = key}
                        END {for (i = 1; i <= NR; i++) if (n[kk[i]] > 1) print line[i]}'
}

dup_scan() { # MIN_KB OUT STATUS DIR... — background worker
  local min=$1 out=$2 st=$3 size mt p h i=0 n
  shift 3
  echo "Listing files…" >"$st"
  find "$@" -xdev -mindepth 1 \( -name '.*' -o -name node_modules \) -prune -o \
    -type f -size +"${min}"k -printf '%s\t%T@\t%p\n' 2>/dev/null | dedupe_on 1 >"$out.cand"
  n=$(wc -l <"$out.cand")
  while IFS=$'\t' read -r size mt p; do
    ((++i % 25 == 0)) && echo "Comparing $i of $n files with matching sizes…" >"$st"
    h=$(head -c 65536 -- "$p" 2>/dev/null | md5sum) || continue
    printf '%s\t%s\t%s\t%s\n' "$size" "${h%% *}" "$mt" "$p"
  done <"$out.cand" | dedupe_on 2 >"$out.part"
  n=$(wc -l <"$out.part") i=0
  while IFS=$'\t' read -r size h mt p; do
    ((++i % 5 == 0)) && echo "Verifying $i of $n likely duplicates…" >"$st"
    if ((size > 65536)); then
      h=$(md5sum -- "$p" 2>/dev/null) || continue
      h=${h%% *}; h=${h#\\}
    fi
    printf '%s\t%s\t%s\t%s\n' "$size" "$h" "$mt" "$p"
  done <"$out.part" | dedupe_on 2 | sort -t$'\t' -k1,1rn -k2,2 -k3,3n >"$out"
  rm -f "$out.cand" "$out.part"
}

declare -a D_SIZE=() D_HASH=() D_MT=() D_PATH=() DR_KIND=() DR_REF=()
declare -A D_SEL=()

dup_rows() { # rebuild display rows from D_* (group header, files, spacer)
  local i last=""
  DR_KIND=() DR_REF=()
  for i in "${!D_PATH[@]}"; do
    if [[ ${D_SIZE[i]}:${D_HASH[i]} != "$last" ]]; then
      ((${#DR_KIND[@]})) && { DR_KIND+=(s); DR_REF+=(""); }
      DR_KIND+=(g); DR_REF+=("$i")
      last=${D_SIZE[i]}:${D_HASH[i]}
    fi
    DR_KIND+=(f); DR_REF+=("$i")
  done
}


dup_autoselect() { # select every copy except the oldest of each group
  local i last=""
  D_SEL=()
  for i in "${!D_PATH[@]}"; do
    [[ ${D_SIZE[i]}:${D_HASH[i]} == "$last" ]] && D_SEL[$i]=1
    last=${D_SIZE[i]}:${D_HASH[i]}
  done
}

dup_text() { TEXT=${D_PATH[${DR_REF[$1]}]}; }
dup_focusable() { [[ ${DR_KIND[$1]} == f ]]; }

dup_row() {
  local kind=${DR_KIND[$1]} i=${DR_REF[$1]} mark="  " box d p n pw
  case $kind in
    s) fl "" ;;
    g)
      local j=$i each can
      n=0
      while ((j < ${#D_PATH[@]})) && [[ ${D_SIZE[j]}:${D_HASH[j]} == "${D_SIZE[i]}:${D_HASH[i]}" ]]; do ((++n, ++j)); done
      humanv each "${D_SIZE[i]}"; humanv can $(((n - 1) * D_SIZE[i]))
      fl "   ${BOLD}$n copies${NC} ${DIM}· $each each · $can can be freed${NC}" ;;
    f)
      (($2)) && mark="${ACCENT}▸${NC} "
      if [[ -n ${D_SEL[$i]} ]]; then box="${RED}●${NC}"; else box="${GREEN}○${NC}"; fi
      printf -v d '%(%Y-%m-%d)T' "${D_MT[i]%.*}"
      p=${D_PATH[i]/#$HOME/\~}
      pw=$((UI_W - 22))
      ((${#p} > pw)) && p="…${p: -$((pw - 1))}"
      (($2)) && p="${BOLD}$p${NC}"
      fl " $mark  $box ${DIM}$d${NC}  $p" ;;
  esac
}

dup_top() {
  local i tot=0 groups=0 last=""
  for i in "${!D_PATH[@]}"; do
    if [[ ${D_SIZE[i]}:${D_HASH[i]} == "$last" ]]; then tot=$((tot + D_SIZE[i])); else ((++groups)); fi
    last=${D_SIZE[i]}:${D_HASH[i]}
  done
  fl ""
  fl_card "${YELLOW}${BOLD}$(human "$tot")${NC} ${BOLD}can be freed by removing duplicates${NC}" \
    "${DIM}$(plural "$groups" group) · $(plural ${#D_PATH[@]} file) · ${GREEN}○${NC}${DIM} keep  ${RED}●${NC}${DIM} remove${NC}"
}

dup_bottom() {
  local i n=0 tot=0 r=${DR_REF[$L_CUR]}
  for i in "${!D_SEL[@]}"; do tot=$((tot + D_SIZE[i])); ((++n)); done
  fl ""
  local fn ft; pluralv fn "$n" file; humanv ft "$tot"
  fl "  ${BOLD}To remove${NC} $fn · ${BOLD}$ft${NC}"
  [[ -n $r ]] && fl "  ${ACCENT}ℹ${NC} ${DIM}${D_PATH[r]/#$HOME/\~}${NC}"
}

dup_trash() {
  local i j last="" kept=1 n=0 tot=0 bad=0 keep_s=() keep_h=() keep_m=() keep_p=()
  # every group must keep at least one copy
  for i in "${!D_PATH[@]}"; do
    if [[ ${D_SIZE[i]}:${D_HASH[i]} != "$last" ]]; then ((kept)) || bad=1; kept=0; fi
    [[ -n ${D_SEL[$i]} ]] || kept=1
    last=${D_SIZE[i]}:${D_HASH[i]}
  done
  ((kept)) || bad=1
  if ((bad)); then toast "${RED}✘${NC} Keep at least one copy in every group (○)."; return; fi
  for i in "${!D_SEL[@]}"; do tot=$((tot + D_SIZE[i])); ((++n)); done
  ((n)) || { toast "${YELLOW}!${NC} Nothing selected."; return; }
  ui_confirm "Move $(plural "$n" duplicate) to Trash?" "$(human "$tot") — one copy of each file is kept. z undoes it." y || return
  UNDO_BATCH=() DUP_TRASHED=()
  for i in "${!D_PATH[@]}"; do
    if [[ -n ${D_SEL[$i]} ]] && move_to_trash "${D_PATH[i]}" >/dev/null 2>&1 && ((!DRY_RUN)); then
      DUP_TRASHED+=("${D_SIZE[i]}"$'\t'"${D_HASH[i]}"$'\t'"${D_MT[i]}"$'\t'"${D_PATH[i]}")
      continue
    fi
    keep_s+=("${D_SIZE[i]}") keep_h+=("${D_HASH[i]}") keep_m+=("${D_MT[i]}") keep_p+=("${D_PATH[i]}")
  done
  if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would move $(plural "$n" file) ($(human "$tot")) to Trash"; return; fi
  # drop groups that are now down to one file
  D_SIZE=() D_HASH=() D_MT=() D_PATH=() D_SEL=()
  for i in "${!keep_p[@]}"; do
    j=0
    [[ $i -gt 0 && ${keep_s[i - 1]}:${keep_h[i - 1]} == "${keep_s[i]}:${keep_h[i]}" ]] && j=1
    [[ $((i + 1)) -lt ${#keep_p[@]} && ${keep_s[i + 1]}:${keep_h[i + 1]} == "${keep_s[i]}:${keep_h[i]}" ]] && j=1
    ((j)) && D_SIZE+=("${keep_s[i]}") D_HASH+=("${keep_h[i]}") D_MT+=("${keep_m[i]}") D_PATH+=("${keep_p[i]}")
  done
  dup_rows
  refresh_sysinfo
  toast "${GREEN}✔${NC} Moved $(plural "$n" duplicate) ($(human "$tot")) to Trash — press z to undo"
}

dup_undo() { # put the last batch back and show those files in their groups again
  local i rows=() a b c d
  undo_trash
  for i in "${!D_PATH[@]}"; do rows+=("${D_SIZE[i]}"$'\t'"${D_HASH[i]}"$'\t'"${D_MT[i]}"$'\t'"${D_PATH[i]}"); done
  D_SIZE=() D_HASH=() D_MT=() D_PATH=() D_SEL=()
  while IFS=$'\t' read -r a b c d; do
    [[ -e $d ]] && D_SIZE+=("$a") D_HASH+=("$b") D_MT+=("$c") D_PATH+=("$d")
  done < <(printf '%s\n' "${rows[@]}" "${DUP_TRASHED[@]}" | grep -v '^$' | sort -t$'\t' -k1,1rn -k2,2 -k3,3n)
  DUP_TRASHED=()
  dup_rows
  refresh_sysinfo
  undo_toast
}

find_duplicates() { # MIN_MB DIR...
  local tmp out st cur=0 scroll=0 r min=$1 where
  shift
  tmp=$(mktemp -d -p "$SESSION_TMP") || return
  out=$tmp/dups st=$tmp/status
  (dup_scan $((min * 1024)) "$out" "$st" "$@") &
  UI_BUSY_TITLE="Duplicates"
  UI_BUSY_STATUS=$st
  where=$(printf '%s, ' "${@/#$HOME/\~}"); where=${where%, }
  ui_busy "Looking for duplicates in $where…" $!
  r=$?
  UI_BUSY_STATUS=""
  ((r == 0)) || { rm -rf "$tmp"; return; }
  D_SIZE=() D_HASH=() D_MT=() D_PATH=()
  while IFS=$'\t' read -r a b c d; do D_SIZE+=("$a") D_HASH+=("$b") D_MT+=("$c") D_PATH+=("$d"); done <"$out"
  rm -rf "$tmp"
  if ((${#D_PATH[@]} == 0)); then toast "${GREEN}✔${NC} No duplicate files found."; return; fi
  dup_rows
  dup_autoselect
  while :; do
    if ((${#D_PATH[@]} == 0)); then
      ((${#UNDO_BATCH[@]})) || { toast "${GREEN}✔${NC} No duplicates left."; return; }
      : # everything was trashed — stay, so z can still put it back
    fi
    L_TITLE="Duplicates" L_TOP=dup_top L_BOTTOM=dup_bottom L_ROW=dup_row L_FOCUSABLE=dup_focusable L_TEXT=dup_text
    L_VIEW=0 L_COUNT=${#DR_KIND[@]} L_CUR=$cur L_SCROLL=$scroll
    if ((${#UNDO_BATCH[@]})); then hints space "keep/remove" "!t" "move to Trash" z undo a "auto-select" n none q back
    else hints space "keep/remove" "!t" "move to Trash" a "auto-select" n none o "show in Files" q back; fi
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL r=${DR_REF[cur]}
    case $KEY in
      space)
        if [[ -n ${D_SEL[$r]} ]]; then unset "D_SEL[$r]"; else D_SEL[$r]=1; fi
        list_move 1; cur=$L_CUR ;;
      a) dup_autoselect ;;
      n) D_SEL=() ;;
      o) xdg-open "$(dirname "${D_PATH[r]}")" >/dev/null 2>&1 & disown 2>/dev/null; toast "${ACCENT}↗${NC} Opened in Files" ;;
      t | delete) dup_trash; cur=0 scroll=0 ;;
      z) ((${#UNDO_BATCH[@]})) && { dup_undo; cur=0 scroll=0; } ;;
      q | esc | left | backspace) return ;;
    esac
  done
}

duplicates_menu() {
  local min
  while :; do
    M_KEY=(1 2 3)
    M_LABEL=("Home folder" "Pictures & Downloads" "Choose a folder…")
    M_DESC=("Files over 1 MB anywhere in your home" "Typical places for repeated photos and downloads" "Pick a folder and a minimum size")
    ui_menu "Duplicates" || return
    case $MENU_IDX in
      0) find_duplicates 1 "$HOME" ;;
      1)
        local d dirs=()
        for d in "$(xdg-user-dir PICTURES 2>/dev/null)" "$(xdg-user-dir DOWNLOAD 2>/dev/null)"; do
          [[ -d $d && $d != "$HOME" ]] && dirs+=("$d")
        done
        ((${#dirs[@]})) || { toast "${YELLOW}!${NC} No Pictures or Downloads folder found."; continue; }
        find_duplicates 0 "${dirs[@]}" ;;
      2)
        ui_input "Folder:" "$HOME" || continue
        REPLY_TEXT=${REPLY_TEXT/#\~/$HOME}
        [[ -d $REPLY_TEXT ]] || { toast "${RED}✘${NC} Not a folder: $REPLY_TEXT"; continue; }
        d=$REPLY_TEXT
        ui_input "Minimum file size in MB:" 1 || continue
        min=$REPLY_TEXT
        [[ $min =~ ^[0-9]+$ ]] || { toast "${RED}✘${NC} Invalid size: $min"; continue; }
        find_duplicates "$min" "$d" ;;
    esac
  done
}

# ───────────────────────────── settings & automation ────────────────────────

SETTINGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/clean-my-ubuntu/settings"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN_PATH="$HOME/.local/bin/clean-my-ubuntu"
ALIAS_PATH="$HOME/.local/bin/cmu" # shorthand
APP_ID="com.homielab.CleanMyUbuntu" # also the desktop app's GApplication id — GNOME matches them
APP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/$APP_ID.desktop"
LEGACY_APP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/clean-my-ubuntu.desktop" # before 1.0
ICON_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/$APP_ID.svg"
SELF=$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")
declare -A CFG=()

apply_settings() {
  JOURNAL_KEEP_DAYS=${CFG[journal_days]:-7}
  JOURNAL_KEEP_MB=${CFG[journal_mb]:-100}
  JOURNAL_KEEP_BYTES=$((JOURNAL_KEEP_MB * 1024 * 1024))
  TMP_DAYS=${CFG[tmp_days]:-10}
  CACHE_DAYS=${CFG[cache_days]:-30}
  NM_DAYS=${CFG[node_modules_days]:-90}
  LOW_DISK_PCT=${CFG[low_disk_pct]:-10}
  LOG_MAX_MB=${CFG[log_max_mb]:-50}
  APPLOG_DAYS=${CFG[app_log_days]:-3}
  AI_HISTORY_DAYS=${CFG[ai_history_days]:-30}
  local _i
  for _i in "${ITEM_IDS[@]}"; do # keep "older than N days" descriptions in sync
    [[ ${ITEM_CAT[$_i]} == ai ]] && ITEM_DESC[$_i]=${ITEM_DESC[$_i]//older than+([0-9]) days/older than $AI_HISTORY_DAYS days}
  done
  ITEM_DESC[big_logs]="Live logs in /var/log over ${LOG_MAX_MB} MB, emptied in place — services keep logging normally."
  ITEM_DESC[app_logs]="Log files of apps (VS Code, Slack, …) not written for ${APPLOG_DAYS}+ days."
  ITEM_LABEL[app_cache]="Stale app caches (>${CACHE_DAYS} days)"
  ITEM_DESC[app_cache]="Files under ~/.cache not modified or read for ${CACHE_DAYS}+ days."
  ITEM_DESC[journal]="Archived system logs. Keeps the last ${JOURNAL_KEEP_DAYS} days and at most ${JOURNAL_KEEP_MB} MB."
  ITEM_DESC[tmp]="Your files in /tmp and /var/tmp not touched for ${TMP_DAYS}+ days."
  ITEM_DESC[node_modules]="node_modules of projects untouched for ${NM_DAYS}+ days. Restore with npm/yarn/pnpm install."
}

save_settings() {
  local k
  ((DRY_RUN)) && return 0
  mkdir -p "${SETTINGS_FILE%/*}" || return
  for k in "${!CFG[@]}"; do printf '%s=%s\n' "$k" "${CFG[$k]}"; done | sort >"$SETTINGS_FILE"
}

notify() { # TITLE BODY [ICON] [URGENCY]
  have notify-send || return 0
  notify-send -a "Clean My Ubuntu" -i "${3:-user-trash-full}" -u "${4:-normal}" "$1" "$2" 2>/dev/null
  return 0
}

schedule_get() { # → off | daily | weekly | monthly
  local t=$SYSTEMD_USER_DIR/clean-my-ubuntu.timer
  if [[ -f $t ]] && systemctl --user is-enabled -q clean-my-ubuntu.timer 2>/dev/null; then
    sed -n 's/^OnCalendar=//p' "$t"
  else echo off; fi
}

schedule_set() { # off | daily | weekly | monthly
  local exe=$SELF
  have systemctl || { toast "${RED}✘${NC} systemd is not available."; return 1; }
  if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would set automatic cleaning to: $1"; return 0; fi
  if [[ $1 == off ]]; then
    systemctl --user disable --now clean-my-ubuntu.timer >/dev/null 2>&1
    rm -f "$SYSTEMD_USER_DIR/clean-my-ubuntu.timer" "$SYSTEMD_USER_DIR/clean-my-ubuntu.service"
    systemctl --user daemon-reload 2>/dev/null
    toast "${GREEN}✔${NC} Automatic cleaning turned off."
    return 0
  fi
  [[ -x $BIN_PATH ]] && exe=$BIN_PATH
  mkdir -p "$SYSTEMD_USER_DIR" || return 1
  cat >"$SYSTEMD_USER_DIR/clean-my-ubuntu.service" <<EOF
[Unit]
Description=Clean My Ubuntu — automatic Smart Clean

[Service]
Type=oneshot
ExecStart="$exe" --auto
Nice=19
IOSchedulingClass=idle
EOF
  cat >"$SYSTEMD_USER_DIR/clean-my-ubuntu.timer" <<EOF
[Unit]
Description=Run Clean My Ubuntu automatically

[Timer]
OnCalendar=$1
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload &&
    systemctl --user enable --now clean-my-ubuntu.timer >/dev/null 2>&1 ||
    { toast "${RED}✘${NC} Could not enable the systemd timer."; return 1; }
  if [[ $exe == "$BIN_PATH" ]]; then toast "${GREEN}✔${NC} Automatic cleaning: $1."
  else toast "${GREEN}✔${NC} Automatic cleaning: $1 — runs ${exe/#$HOME/\~}; install the launcher so moving it won't break this."; fi
}

# The desktop app (gui/) and the icon (data/) ship in the repository. A clone has
# them next to the script; a script downloaded on its own fetches them from GitHub.
BUNDLE_URL=${CMU_BUNDLE_URL:-https://github.com/$UPDATE_REPO/archive/refs/heads/$UPDATE_BRANCH.tar.gz}

bundle_fetch() { # → BUNDLE_ROOT: the app files from GitHub (fails quietly when offline)
  local dir top
  have tar || return 1
  dir=$(mktemp -d -p "$SESSION_TMP") || return 1
  fetch "$BUNDLE_URL" "$dir/app.tar.gz" || return 1
  tar -xzf "$dir/app.tar.gz" -C "$dir" --wildcards '*/gui/*' '*/data/*' 2>/dev/null || return 1
  for top in "$dir"/*/; do
    [[ -f $top/gui/cmu-gui && -d $top/gui/cmu_gui ]] && { BUNDLE_ROOT=${top%/}; return 0; }
  done
  return 1
}

app_files_root() { # → a folder with gui/ and data/: next to this script, or freshly downloaded
  local here
  here=$(dirname "$SELF")
  if [[ -f $here/gui/cmu-gui || -d $here/data/icons ]]; then printf '%s\n' "$here"; return 0; fi
  bundle_fetch && printf '%s\n' "$BUNDLE_ROOT"
}

install_app_files() { # ROOT — copy the desktop app and the icon into place
  local root=$1 svg="$1/data/icons/hicolor/scalable/apps/$APP_ID.svg"
  if [[ -f $root/gui/cmu-gui && $root/gui != "$GUI_HOME" ]]; then
    mkdir -p "$GUI_HOME" && cp -r -- "$root/gui/cmu-gui" "$root/gui/cmu_gui" "$GUI_HOME/" &&
      find "$GUI_HOME" -name __pycache__ -prune -exec rm -rf {} +
  fi
  if [[ -f $svg ]]; then
    mkdir -p "${ICON_FILE%/*}" && cp -- "$svg" "$ICON_FILE"
    touch "${ICON_FILE%/scalable/*}" 2>/dev/null # tell the shell the icon theme changed
  fi
  return 0
}

do_install() { # copy to ~/.local/bin, add the `cmu` shorthand and an app-grid entry → INSTALL_LOG
  INSTALL_LOG=() INSTALL_CMD=clean-my-ubuntu
  local bindir=${BIN_PATH%/*}
  bindir=${bindir/#$HOME/\~}
  if [[ ! -f $SELF || $SELF == /dev/* || $SELF == /proc/* ]]; then
    INSTALL_LOG+=("${RED}✘${NC} Download the script to a file first, then run it with --install.")
    return 1
  fi
  if ((DRY_RUN)); then
    INSTALL_LOG+=("${MAGENTA}[dry-run]${NC} Would install ${BIN_PATH/#$HOME/\~}, ${ALIAS_PATH/#$HOME/\~} and an app-grid entry")
    return 0
  fi
  mkdir -p "${BIN_PATH%/*}" "${APP_FILE%/*}" || return 1
  if [[ $SELF != "$BIN_PATH" ]]; then
    install -m 755 -- "$SELF" "$BIN_PATH" || { INSTALL_LOG+=("${RED}✘${NC} Could not copy to ${BIN_PATH/#$HOME/\~}"); return 1; }
  fi
  INSTALL_LOG+=("${GREEN}✔${NC} Installed ${BOLD}clean-my-ubuntu${NC} $VERSION to $bindir")
  # `cmu` — but never shadow a different program or replace a real file
  local other
  other=$(command -v cmu 2>/dev/null)
  if [[ -L $ALIAS_PATH || ! -e $ALIAS_PATH ]] && [[ -z $other || $other == "$ALIAS_PATH" ]]; then
    ln -sfn clean-my-ubuntu "$ALIAS_PATH" && INSTALL_LOG+=("${GREEN}✔${NC} Shorthand: ${BOLD}cmu${NC}") INSTALL_CMD=cmu
  else
    INSTALL_LOG+=("${YELLOW}!${NC} Skipped the ${BOLD}cmu${NC} shorthand: ${other:-$ALIAS_PATH} already exists")
  fi
  # the desktop app and the icon: from this copy's folder (a clone), or downloaded from GitHub
  local root gui=0 icon=user-trash-full
  if root=$(app_files_root); then
    install_app_files "$root"
    [[ $root == "$SESSION_TMP"/* ]] && INSTALL_LOG+=("${GREEN}✔${NC} Downloaded the desktop app and icon from GitHub")
    [[ -f $GUI_HOME/cmu-gui ]] && INSTALL_LOG+=("${GREEN}✔${NC} Installed the desktop app (${BOLD}cmu --gui${NC})")
  else
    INSTALL_LOG+=("${YELLOW}!${NC} Couldn't get the desktop app (offline?) — the terminal app is installed.")
  fi
  [[ -f $ICON_FILE ]] && icon=$APP_ID
  [[ -f $GUI_HOME/cmu-gui ]] && gui_supported && gui=1
  rm -f -- "$LEGACY_APP_FILE"
  if ((gui)); then # app grid opens the desktop app; right-click offers the terminal app
    printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=Clean My Ubuntu" \
      "Comment=Free up disk space and keep Ubuntu tidy" "Exec=$BIN_PATH --gui" "Icon=$icon" \
      "Terminal=false" "Categories=GTK;System;" "Keywords=clean;disk;space;junk;cache;duplicates;cmu;" \
      "StartupNotify=true" "StartupWMClass=$APP_ID" "Actions=terminal;" "" \
      "[Desktop Action terminal]" "Name=Open in Terminal" "Exec=x-terminal-emulator -e $BIN_PATH" >"$APP_FILE"
  else
    printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=Clean My Ubuntu" \
      "Comment=Free up disk space and keep Ubuntu tidy" "Exec=$BIN_PATH" "Icon=$icon" \
      "Terminal=true" "Categories=System;" "Keywords=clean;disk;space;junk;cache;duplicates;cmu;" >"$APP_FILE"
  fi
  have update-desktop-database && update-desktop-database "${APP_FILE%/*}" >/dev/null 2>&1
  INSTALL_LOG+=("${GREEN}✔${NC} Added “Clean My Ubuntu” to your app grid$( ((gui)) && echo " (desktop app)")")
  local sched; sched=$(schedule_get)
  [[ $sched != off ]] && schedule_set "$sched" # point the timer at the installed copy
  case ":$PATH:" in
    *":${BIN_PATH%/*}:"* | *":${BIN_PATH%/*}/:"*) ;; # with or without a trailing slash
    *) INSTALL_LOG+=("${YELLOW}!${NC} $bindir is not in your PATH yet — log out and back in, or run:"
         "    export PATH=\"\$HOME/.local/bin:\$PATH\"") ;;
  esac
  return 0
}

install_launcher() { # Settings → Install app launcher
  if packaged; then toast "${GREEN}✔${NC} Already installed by your package manager."; return; fi
  ui_confirm "Install Clean My Ubuntu?" "Adds the clean-my-ubuntu and cmu commands and an app-grid entry." y || return
  if do_install; then toast "${GREEN}✔${NC} Installed — type ${BOLD}$INSTALL_CMD${NC} in any terminal, or find it in your apps"
  else toast "${INSTALL_LOG[-1]}"; fi
}

cli_install() { # --install
  local l rc
  if packaged; then
    ok "Clean My Ubuntu is already installed as a package — find it in Show Apps, or run: cmu"
    return 0
  fi
  do_install; rc=$?
  for l in "${INSTALL_LOG[@]}"; do printf '  %s\n' "$l"; done
  ((rc == 0 && !DRY_RUN)) && printf '\n  Start it any time with: %s%s%s\n\n' "$BOLD" "$INSTALL_CMD" "$NC"
  return "$rc"
}

cli_uninstall() { # --uninstall: remove commands, launcher, timer; optionally settings and logs
  local f
  if packaged; then
    info "Clean My Ubuntu was installed as a package — remove it with:"
    if [[ -n ${SNAP:-} ]]; then printf '    sudo snap remove clean-my-ubuntu\n'; else printf '    sudo apt remove clean-my-ubuntu\n'; fi
    return 0
  fi
  printf '  This removes clean-my-ubuntu, cmu, the app-grid entry and automatic cleaning.\n'
  confirm "Uninstall Clean My Ubuntu?" || return 1
  if have systemctl && ((!DRY_RUN)); then
    systemctl --user disable --now clean-my-ubuntu.timer >/dev/null 2>&1
  fi
  for f in "$BIN_PATH" "$ALIAS_PATH" "$APP_FILE" "$LEGACY_APP_FILE" "$ICON_FILE" \
    "$SYSTEMD_USER_DIR/clean-my-ubuntu.timer" "$SYSTEMD_USER_DIR/clean-my-ubuntu.service"; do
    [[ -e $f || -L $f ]] || continue
    [[ $f == "$ALIAS_PATH" && $(readlink "$f") != clean-my-ubuntu ]] && continue # not ours
    run rm -f -- "$f" && ok "Removed ${f/#$HOME/\~}"
  done
  if [[ -d $GUI_HOME && $GUI_HOME == */clean-my-ubuntu/gui ]]; then
    run rm -rf -- "$GUI_HOME" && ok "Removed the desktop app"
  fi
  ((DRY_RUN)) || { have systemctl && systemctl --user daemon-reload 2>/dev/null; }
  if confirm "Also delete your settings, remembered selections and logs?"; then
    run rm -rf -- "${PREF_FILE%/*}" "$LOG_DIR" && ok "Removed settings and logs"
  fi
  printf '\n  Goodbye 👋  (this copy of the script itself was left in place)\n'
}

edit_number() { # KEY PROMPT MIN MAX
  ui_input "$2" "${CFG[$1]:-}" || return
  if [[ $REPLY_TEXT =~ ^[0-9]+$ ]] && ((REPLY_TEXT >= $3 && REPLY_TEXT <= $4)); then
    CFG[$1]=$REPLY_TEXT
    save_settings
    apply_settings
    toast "${GREEN}✔${NC} Saved."
  else
    toast "${RED}✘${NC} Enter a number from $3 to $4."
  fi
}

settings_menu() {
  local s
  while :; do
    s=$(schedule_get)
    M_KEY=() M_LABEL=() M_DESC=()
    mh "General"
    mi 1 "Automatic cleaning" "${s^} $( [[ $s == off ]] && echo "— runs a Smart Clean of user & developer junk" || echo "— user & developer junk, you get a notification")"
    mi 2 "Low disk alert" "$( ((LOW_DISK_PCT)) && echo "Notify below ${LOW_DISK_PCT}% free (checked with automatic cleaning)" || echo "Off")"
    mi 3 "Recent files history" "$(recent_policy)"
    mi 4 "Install app launcher" "$(if packaged; then echo "Installed by your package manager"
      elif [[ -x $BIN_PATH && -f $APP_FILE ]]; then echo "Installed — run clean-my-ubuntu or cmu"
      else echo "Add clean-my-ubuntu and cmu commands and an app-grid entry"; fi)"
    mh "Updates"
    mi 5 "Check for updates now" "You have version $VERSION${UPDATE_LATEST:+ — $UPDATE_LATEST is available}"
    mi 6 "Daily update check" "$( ((${CFG[update_check]:-1})) && echo "On — a quiet check once a day" || echo "Off")"
    mh "Keep for"
    mi 7 "Journal logs" "Keep ${JOURNAL_KEEP_DAYS} days"
    mi 8 "Journal size limit" "Keep at most ${JOURNAL_KEEP_MB} MB"
    mi 9 "Oversized logs" "Empty live logs larger than ${LOG_MAX_MB} MB"
    mi 0 "App logs" "Clean when not written for ${APPLOG_DAYS} days"
    mi a "Temporary files" "Clean when older than ${TMP_DAYS} days"
    mi b "App caches" "Clean when older than ${CACHE_DAYS} days"
    mi c "node_modules" "Clean when the project is idle for ${NM_DAYS} days"
    mi d "AI chat history" "Clean AI sessions older than ${AI_HISTORY_DAYS} days"
    mh "Your data"
    mi e "Reset selections" "$(plural ${#PREF[@]} "remembered choice") for Smart Scan"
    mi f "Activity log" "What was cleaned and when"
    mh "About"
    mi g "Source code" "${REPO_URL#https://} — opens in your browser"
    mi h "Report a problem" "Questions, bugs and ideas are welcome"
    ui_menu "Settings" || return
    case ${M_LABEL[MENU_IDX]} in # dispatch by label: keys are only shortcuts
      "Automatic cleaning")
        M_KEY=(1 2 3 4) M_LABEL=("Off" "Daily" "Weekly" "Monthly")
        M_DESC=("Only clean when you run the app" "Every day" "Every week (recommended)" "Once a month")
        if ui_menu "Automatic cleaning"; then
          case $MENU_IDX in 0) schedule_set off ;; 1) schedule_set daily ;; 2) schedule_set weekly ;; 3) schedule_set monthly ;; esac
        fi ;;
      "Low disk alert") edit_number low_disk_pct "Warn below this % of free space (0 = off):" 0 50 ;;
      "Recent files history") recent_menu ;;
      "Install app launcher") install_launcher ;;
      "Check for updates now") ui_update ;;
      "Daily update check")
        CFG[update_check]=$((1 - ${CFG[update_check]:-1}))
        save_settings
        toast "${GREEN}✔${NC} Daily update check $( ((CFG[update_check])) && echo on || echo off)." ;;
      "Journal logs") edit_number journal_days "Keep journal logs for how many days?" 1 365 ;;
      "Journal size limit") edit_number journal_mb "Maximum journal size in MB:" 16 10000 ;;
      "Oversized logs") edit_number log_max_mb "Empty live logs larger than how many MB?" 10 100000 ;;
      "App logs") edit_number app_log_days "Clean app logs not written for how many days?" 1 365 ;;
      "Temporary files") edit_number tmp_days "Clean temporary files older than how many days?" 1 365 ;;
      "App caches") edit_number cache_days "Clean app caches older than how many days?" 1 365 ;;
      "node_modules") edit_number node_modules_days "Clean node_modules idle for how many days?" 7 3650 ;;
      "AI chat history") edit_number ai_history_days "Clean AI chat sessions older than how many days?" 1 3650 ;;
      "Reset selections")
        ui_confirm "Forget remembered selections?" "Smart Scan goes back to its default choices." n || continue
        PREF=()
        ((DRY_RUN)) || rm -f "$PREF_FILE"
        toast "${GREEN}✔${NC} Selections reset to defaults." ;;
      "Activity log")
        if [[ -s $LOG_FILE ]]; then mapfile -t V_LINES < <(tac "$LOG_FILE" | head -n 1000 | sed 's/^/  /')
        else V_LINES=("  ${DIM}Nothing has been cleaned yet.${NC}"); fi
        ui_view "Activity log" ;;
      "Source code") open_url "$REPO_URL" ;;
      "Report a problem") open_url "$REPO_URL/issues" ;;
    esac
  done
}

open_url() { # URL — open in the browser; always show it too (SSH, no desktop)
  if have xdg-open && [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
    xdg-open "$1" >/dev/null 2>&1 &
    disown 2>/dev/null
    toast "${ACCENT}↗${NC} Opened $1"
  else
    toast "${ACCENT}↗${NC} $1"
  fi
}

recent_policy() { # describe GNOME's recent-files setting
  have gsettings || { echo "Not available"; return; }
  local on age
  on=$(gsettings get org.gnome.desktop.privacy remember-recent-files 2>/dev/null)
  age=$(gsettings get org.gnome.desktop.privacy recent-files-max-age 2>/dev/null)
  if [[ $on == false ]]; then echo "Not remembered"
  elif [[ $age == -1 || -z $age ]]; then echo "Remembered forever (GNOME default)"
  else echo "Remembered for $(plural "$age" day)"; fi
}

recent_menu() {
  have gsettings || { toast "${RED}✘${NC} gsettings is not available."; return; }
  M_KEY=(1 2 3 4 5) M_LABEL=("Forever" "30 days" "7 days" "1 day" "Don't remember")
  M_DESC=("GNOME default" "Older entries drop off automatically" "" "" "Files and Open dialogs show no Recent list")
  ui_menu "Recent files history" || return
  if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would set recent files to: ${M_LABEL[MENU_IDX]}"; return; fi
  local age=(-1 30 7 1 -1)
  gsettings set org.gnome.desktop.privacy remember-recent-files "$( ((MENU_IDX == 4)) && echo false || echo true)" &&
    gsettings set org.gnome.desktop.privacy recent-files-max-age "${age[MENU_IDX]}" &&
    toast "${GREEN}✔${NC} Recent files: ${M_LABEL[MENU_IDX]}"
}

# ───────────────────────────── updates ──────────────────────────────────────
#
# The latest version is the VERSION line of the script on the default branch.
# A download is only used if it is really this script and passes `bash -n`;
# it replaces the installed copy atomically (write next to it, then rename),
# so a copy that is currently running is never corrupted.

UPDATE_URL=${CMU_UPDATE_URL:-https://raw.githubusercontent.com/$UPDATE_REPO/$UPDATE_BRANCH/clean-my-ubuntu.sh}
UPDATE_STATE="$LOG_DIR/update-check" # "<epoch>\t<latest version>"
UPDATE_LATEST=""

update_configured() { [[ -n ${CMU_UPDATE_URL:-} || $UPDATE_REPO == */* ]]; } # CMU_UPDATE_URL: mirrors, forks, tests

fetch() { # URL OUT → 0 ok, 22 not found / server error, 127 no downloader, other = network
  local rc
  if have curl; then curl -fsSL --max-time 20 -o "$2" -- "$1" 2>/dev/null; rc=$?
  elif have wget; then wget -q -T 20 -O "$2" -- "$1" 2>/dev/null; rc=$?; ((rc == 8)) && rc=22
  else return 127; fi
  return "$rc"
}

script_version() { sed -n 's/^VERSION="\([0-9][0-9.]*\)"$/\1/p' "$1" 2>/dev/null | head -n 1; }

version_gt() { # A B → A is newer than B
  [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

load_update_state() { # → UPDATE_LATEST (from the last check)
  local t v
  UPDATE_LATEST=""
  [[ -n ${UPDATE_DONE:-} ]] && return 0 # already updated; this running copy is just old
  [[ -f $UPDATE_STATE ]] && IFS=$'\t' read -r t v <"$UPDATE_STATE" &&
    [[ $v =~ ^[0-9][0-9.]*$ ]] && version_gt "$v" "$VERSION" && UPDATE_LATEST=$v
  return 0
}

update_check_bg() { # at most once a day, in the background — never delays the app
  local t=0 v
  packaged && return 0 # apt / Software Updater handle updates
  ((${CFG[update_check]:-1})) && [[ -z ${CMU_NO_UPDATE_CHECK:-} ]] && update_configured || return 0
  [[ -f $UPDATE_STATE ]] && IFS=$'\t' read -r t v <"$UPDATE_STATE"
  ((EPOCHSECONDS - ${t:-0} < 86400)) && return 0
  (
    tmp=$(mktemp) || exit
    trap 'rm -f "$tmp"' EXIT
    fetch "$UPDATE_URL" "$tmp" && v=$(script_version "$tmp") && [[ -n $v ]] &&
      mkdir -p "$LOG_DIR" && printf '%s\t%s\n' "$EPOCHSECONDS" "$v" >"$UPDATE_STATE"
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
  return 0
}

update_download() { # → UPDATE_FILE, UPDATE_NEW; 0 newer available, 1 error (UPDATE_MSG), 2 up to date
  local rc
  UPDATE_FILE=$(mktemp -p "$SESSION_TMP") UPDATE_NEW="" UPDATE_MSG=""
  if ! update_configured; then
    UPDATE_MSG="Update source not set yet (UPDATE_REPO in the script)."
    return 1
  fi
  if ((UI_ACTIVE)); then
    (fetch "$UPDATE_URL" "$UPDATE_FILE"; echo $? >"$UPDATE_FILE.rc") &
    UI_BUSY_TITLE="Updates"
    ui_busy "Checking for updates…" $! || { UPDATE_MSG="Cancelled."; return 1; }
    rc=$(<"$UPDATE_FILE.rc")
  else
    fetch "$UPDATE_URL" "$UPDATE_FILE"; rc=$?
  fi
  if ((rc == 127)); then UPDATE_MSG="Install curl or wget to check for updates."; return 1; fi
  if ((rc == 22)); then UPDATE_MSG="No published version found at github.com/$UPDATE_REPO yet."; return 1; fi
  if ((rc != 0)) || [[ ! -s $UPDATE_FILE ]]; then UPDATE_MSG="Could not reach GitHub — are you online?"; return 1; fi
  UPDATE_NEW=$(script_version "$UPDATE_FILE")
  if [[ -z $UPDATE_NEW ]] || ! grep -q 'clean-my-ubuntu' "$UPDATE_FILE" || ! bash -n "$UPDATE_FILE" 2>/dev/null; then
    UPDATE_MSG="The download doesn't look like Clean My Ubuntu — not installing it."
    return 1
  fi
  mkdir -p "$LOG_DIR" && printf '%s\t%s\n' "$EPOCHSECONDS" "$UPDATE_NEW" >"$UPDATE_STATE"
  if version_gt "$UPDATE_NEW" "$VERSION"; then return 0; fi
  UPDATE_MSG="You're up to date (version $VERSION)."
  UPDATE_LATEST=""
  return 2
}

update_apply() { # install UPDATE_FILE over the installed copy (or this file) → UPDATE_MSG
  local target=$SELF
  [[ -x $BIN_PATH ]] && target=$BIN_PATH
  if [[ ! -f $target || ! -w ${target%/*} ]]; then UPDATE_MSG="Can't write ${target/#$HOME/\~}."; return 1; fi
  if ((DRY_RUN)); then UPDATE_MSG="[dry-run] Would update ${target/#$HOME/\~} to $UPDATE_NEW"; return 0; fi
  cp -- "$UPDATE_FILE" "$target.new.$$" && chmod 755 "$target.new.$$" && mv -f -- "$target.new.$$" "$target" || {
    rm -f -- "$target.new.$$"; UPDATE_MSG="Update failed while writing ${target/#$HOME/\~}."; return 1
  }
  log "Updated from $VERSION to $UPDATE_NEW ($target)"
  UPDATE_LATEST="" UPDATE_DONE=$UPDATE_NEW
  if [[ -d $GUI_HOME || -f $ICON_FILE ]] && bundle_fetch; then # keep the desktop app in step
    install_app_files "$BUNDLE_ROOT"
  fi
  UPDATE_MSG="Updated to $UPDATE_NEW — restart cmu to use it."
}

ui_update() { # check, confirm, install — from the menu or Settings
  update_download
  case $? in
    1) toast "${RED}✘${NC} $UPDATE_MSG"; return ;;
    2) toast "${GREEN}✔${NC} $UPDATE_MSG"; return ;;
  esac
  ui_confirm "Update to version $UPDATE_NEW?" "You have $VERSION. Release notes: github.com/$UPDATE_REPO/releases" y || return
  if update_apply; then toast "${GREEN}✔${NC} $UPDATE_MSG"; else toast "${RED}✘${NC} $UPDATE_MSG"; fi
}

cli_update() { # --update
  if packaged; then
    info "Clean My Ubuntu was installed as a package — update it with Software Updater or:"
    pkg_update_hint
    return 0
  fi
  printf '  Clean My Ubuntu %s — checking for updates…\n' "$VERSION"
  update_download
  case $? in
    1) err "$UPDATE_MSG"; return 1 ;;
    2) ok "$UPDATE_MSG"; return 0 ;;
  esac
  printf '  %s⬆ Version %s is available%s (you have %s)\n' "$BOLD" "$UPDATE_NEW" "$NC" "$VERSION"
  printf '  %sRelease notes: https://github.com/%s/releases%s\n' "$DIM" "$UPDATE_REPO" "$NC"
  confirm "Update now?" || return 0
  if update_apply; then ok "$UPDATE_MSG"; else err "$UPDATE_MSG"; return 1; fi
}

auto_mode() { # --auto: unattended Smart Clean of user & developer junk, run by the timer
  local avail size pct
  INTERACTIVE=0 ASSUME_YES=1
  local id b left=() body title
  printf 'Clean My Ubuntu — automatic Smart Clean (%s)\n\n' "$(date '+%F %T')"
  scan_items "${CATEGORIES[@]}" # everything is scanned (read-only) …
  for id in "${SCANNED[@]}"; do # … but only user & developer junk is cleaned
    [[ ${ITEM_CAT[$id]} == user || ${ITEM_CAT[$id]} == dev ]] || SEL[$id]=0
  done
  SEL[trash]=0 # never empty the Trash behind the user's back
  plain_results
  printf '\n'
  start_cleanup
  # the biggest things left for the user to decide about
  while IFS=$'\t' read -r b id; do
    left+=("${ITEM_LABEL[$id]} $(human "$b")")
  done < <(for id in "${SCANNED[@]}"; do
    ((RES_RC[$id] == 0 && !SEL[$id] && RES_BYTES[$id] >= 104857600)) && printf '%s\t%s\n' "${RES_BYTES[$id]}" "$id"
  done | sort -rn | head -n 3)
  if ((RUN_FREED > 0 || ${#left[@]})); then
    if ((RUN_FREED > 0)); then title="Freed $(human "$RUN_FREED")"; body="Caches and junk were cleaned automatically."
    else title="Clean My Ubuntu"; body=""; fi
    if ((${#left[@]})); then
      body+="${body:+ }Worth a look: $(printf '%s, ' "${left[@]}")"
      body="${body%, } — run cmu to review."
    fi
    printf '\n  %s: %s\n' "$title" "$body"
    notify "$title" "$body"
  fi
  read -r size avail < <(df -B1 --output=size,avail / | tail -n1)
  pct=$((avail * 100 / size))
  if ((LOW_DISK_PCT > 0 && pct < LOW_DISK_PCT)); then
    notify "Disk almost full" "Only $(human "$avail") ($pct%) free on /. Open Clean My Ubuntu to free up space." drive-harddisk critical
  fi
}

# ───────────────────────────── JSON protocol (for the GUI) ──────────────────
#
# `cmu --json items|scan|details|clean …` prints one JSON object per line on
# stdout and nothing else. See docs/ROADMAP.md for the event list.

JSON=0
JSON_ARGS=()

json_str() { # VAR TEXT → a JSON string literal (colours and control characters removed)
  local s=$2
  s=${s//$'\e'\[*([0-9;])m/}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//[$'\x01'-$'\x1f']/}
  printf -v "$1" '"%s"' "$s"
}

json_item() { # ID [with scan results] → one "item" event
  local id=$1 cat label desc note status=found
  json_str cat "${ITEM_CAT[$id]}"; json_str label "${ITEM_LABEL[$id]}"; json_str desc "${ITEM_DESC[$id]}"
  if [[ ${2:-} == scanned ]]; then
    json_str note "${RES_NOTE[$id]}"
    case ${RES_RC[$id]} in 0) status=found ;; 3) status=timeout ;; *) status=clean ;; esac
    printf '{"event":"item","id":"%s","category":%s,"label":%s,"description":%s,"default":%s,"root":%s,"status":"%s","bytes":%d,"note":%s,"selected":%s}\n' \
      "$id" "$cat" "$label" "$desc" "$( ((ITEM_DEFAULT[$id])) && echo true || echo false)" \
      "$([[ -n ${ITEM_ROOT[$id]:-} ]] && echo true || echo false)" "$status" "${RES_BYTES[$id]:-0}" "$note" \
      "$( ((${SEL[$id]:-0})) && echo true || echo false)"
  else
    printf '{"event":"item","id":"%s","category":%s,"label":%s,"description":%s,"default":%s,"root":%s}\n' \
      "$id" "$cat" "$label" "$desc" "$( ((ITEM_DEFAULT[$id])) && echo true || echo false)" \
      "$([[ -n ${ITEM_ROOT[$id]:-} ]] && echo true || echo false)"
  fi
}

json_error() { local m; json_str m "$1"; printf '{"event":"error","message":%s}\n' "$m"; }

json_task() { # ID STATE INFO FREED
  local info; json_str info "${3:-}"
  printf '{"event":"task","id":"%s","state":"%s","info":%s,"freed":%d}\n' "$1" "$2" "$info" "${4:-0}"
}

json_main() { # SUBCOMMAND ARGS…
  local cmd=${1:-} id
  shift || true
  case $cmd in
    items)
      for id in "${ITEM_IDS[@]}"; do json_item "$id"; done
      printf '{"event":"done"}\n' ;;
    scan)
      scan_items "${CATEGORIES[@]}"
      for id in "${SCANNED[@]}"; do json_item "$id" scanned; done
      found_total
      printf '{"event":"done","ms":%d,"total_bytes":%d,"locations":%d}\n' "$SCAN_MS" "$FOUND_TOTAL" "$SCAN_COUNT" ;;
    details)
      id=${1:-}
      [[ -n ${ITEM_CAT[$id]:-} ]] || { json_error "Unknown item: $id"; return 2; }
      local lines=() l out="" first=1
      if declare -F "details_$id" >/dev/null; then mapfile -t lines < <("details_$id" 2>/dev/null); fi
      for l in "${lines[@]}"; do
        json_str l "$l"
        ((first)) || out+=","
        out+=$l first=0
      done
      printf '{"event":"details","id":"%s","lines":[%s]}\n{"event":"done"}\n' "$id" "$out" ;;
    clean) json_clean "$@" ;;
    *) json_error "Usage: --json items|scan|details ID|clean ID…"; return 2 ;;
  esac
}

# As root (through pkexec) only system items may be cleaned — your home folder
# is never cleaned as root.
json_allowed() { # ID UID
  (($2 != 0)) || [[ -n ${ITEM_ROOT[$1]:-} ]]
}

json_clean() { # ID… — clean exactly these items, streaming "task" events
  local id ids=() out rc before freed total=0 avail0 avail1 src bytes note info
  for id in "$@"; do
    [[ -n ${ITEM_CAT[$id]:-} ]] || { json_error "Unknown item: $id"; return 2; }
    json_allowed "$id" "$EUID" || { json_error "Refusing to clean $id as root (only system items are allowed)"; return 2; }
    ids+=("$id")
  done
  ((${#ids[@]})) || { json_error "No items given."; return 2; }
  avail0=$(fs_avail)
  for id in "${ids[@]}"; do
    json_task "$id" run
    SCAN_BYTES=0 SCAN_NOTE=""
    "scan_$id" >/dev/null 2>&1; rc=$?
    before=$SCAN_BYTES
    if ((rc != 0)); then json_task "$id" ok "already clean" 0; continue; fi
    RES_BYTES[$id]=$before
    if declare -F "precheck_$id" >/dev/null && ! "precheck_$id" >/dev/null 2>&1; then
      json_task "$id" skip "Skipped: the app is running — close it and try again"; continue
    fi
    out=$(mktemp -p "$SESSION_TMP")
    task_clean "$id" >"$out" 2>&1 </dev/null; rc=$?
    if ((rc != 0)); then
      info=$(grep -v '^@@scan' "$out" | grep -v '^\s*$' | tail -n 1)
      json_task "$id" fail "${info:-failed (exit $rc)}" 0
      log "json clean $id failed: $info"
      continue
    fi
    if [[ ${ITEM_CAT[$id]} == privacy ]]; then
      freed=0 info=$( ((DRY_RUN)) && echo "would be cleared" || echo "cleared")
    elif ((DRY_RUN)); then
      freed=$before info="$(human "$freed") would be freed"
    else
      IFS=$'\t' read -r _ src bytes note < <(grep '^@@scan' "$out" | tail -n 1)
      freed=$((before - ${bytes:-0})); ((freed < 0)) && freed=0
      info="$(human "$freed") freed"
    fi
    total=$((total + freed))
    json_task "$id" ok "$info" "$freed"
  done
  avail1=$(fs_avail)
  ((DRY_RUN)) || record_cleanup "$total"
  log "GUI cleanup finished — $(human "$total") freed (dry-run=$DRY_RUN)"
  printf '{"event":"done","freed":%d,"avail_before":%d,"avail_after":%d}\n' "$total" "$avail0" "$avail1"
}

# ───────────────────────────── desktop app ──────────────────────────────────

GUI_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/clean-my-ubuntu/gui"

# Installed by a package (.deb): files live in ../share/clean-my-ubuntu next to the
# command, and apt — not this script — handles updates and removal.
PKG_SHARE="$(dirname "$SELF")/../share/clean-my-ubuntu"
packaged() { [[ -f $PKG_SHARE/packaged || -n ${SNAP:-} ]]; }
pkg_update_hint() { # how this copy gets updates
  if [[ -n ${SNAP:-} ]]; then printf '    Snaps update automatically (or: sudo snap refresh clean-my-ubuntu)\n'
  else printf '    sudo apt update && sudo apt upgrade\n'; fi
}

gui_dir() { # where the desktop app lives: next to this script (a clone), installed, or packaged
  local d
  for d in "$(dirname "$SELF")/gui" "$GUI_HOME" "$PKG_SHARE/gui"; do
    [[ -f $d/cmu-gui && -d $d/cmu_gui ]] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

gui_supported() { # Python + PyGObject + GTK 4 + libadwaita ≥ 1.5
  python3 - 2>/dev/null <<'PY'
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw
raise SystemExit(0 if (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 5) else 1)
PY
}

launch_gui() {
  local dir
  if ! dir=$(gui_dir); then
    err "The desktop app isn't installed. Get it from $REPO_URL (folder gui/) and run --install from there."
    return 1
  fi
  if ! gui_supported; then
    err "The desktop app needs GTK 4 + libadwaita 1.5 (Ubuntu 24.04 or newer)."
    err "On older systems use the terminal app: cmu"
    return 1
  fi
  local extra=()
  ((DRY_RUN)) && extra=(--dry-run)
  exec python3 "$dir/cmu-gui" --engine "$SELF" "${extra[@]}"
}

# ───────────────────────────── main ─────────────────────────────────────────

usage() {
  cat <<EOF
Clean My Ubuntu $VERSION — free up disk space and keep Ubuntu tidy. Inspired by CleanMyMac.

Usage: $(basename "$0") [options]        (installed as: cmu)

Run
  (no option)       Open the terminal app
      --gui         Open the desktop app (Ubuntu 24.04 or newer)
  -n, --dry-run     Show what would happen; delete nothing (works with everything)
      --no-mouse    Terminal app: don't capture the mouse

Scan & clean without the app
  -s, --scan        Print what a Smart Scan finds
  -c, --clean       Smart Scan, then clean the selected items (asks once)
  -y, --yes         With --clean: don't ask (running apps are skipped)
      --only LIST   Only these groups: system,logs,user,browser,apps,ai,models,dev,privacy
                    (privacy is only included when named)
      --auto        What automatic cleaning runs: user & developer junk, then a
                    desktop notification

Install & update
      --install     Install the cmu command, the desktop app and the app-grid entry
      --update      Check for a new version and install it (asks first)
      --uninstall   Remove everything --install added
  -v, --version     Print the version

For the desktop app
      --json CMD    Machine-readable engine: items, scan, details ID, clean ID…

Keys: ↑↓ or j/k move · space select · enter/→ open · / find · z undo · q back · ? help

Activity log:         $LOG_FILE
Remembered choices:   $PREF_FILE
Source & bug reports: $REPO_URL — made by HomieLab (https://homielab.com)
EOF
}

home_top() {
  local msg
  fl ""
  if [[ -n ${UPDATE_DONE:-} ]]; then
    fl "  ${GREEN}✔${NC} ${BOLD}Updated to $UPDATE_DONE.${NC} ${DIM}Quit and start cmu again to use the new version.${NC}"
  elif [[ -n ${STATS[last_time]} ]]; then
    local when last total runs
    agov when "${STATS[last_time]}"; humanv last "${STATS[last_freed]}"; humanv total "${STATS[lifetime]}"
    pluralv runs "${STATS[runs]}" cleanup
    fitv msg "Last cleanup $when freed $last · $total freed over $runs" $((UI_W - 18))
    fl "  ${BOLD}Welcome back.${NC} ${DIM}$msg${NC}"
  else
    fitv msg "Start with a Smart Scan — nothing is deleted until you confirm." $((UI_W - 14))
    fl "  ${BOLD}Welcome!${NC} ${DIM}$msg${NC}"
  fi
  fl ""
}

# Menu builders: mi KEY LABEL [DESC] [BADGE] adds an item, mh TITLE a section
# header (mh "" a blank line). Badges stay attached to their own row.
mi() { M_KEY+=("$1") M_LABEL+=("$2") M_DESC+=("${3:-}"); [[ -n ${4:-} ]] && M_BADGE[${#M_KEY[@]} - 1]=$4; return 0; }
mh() { # TITLE — a blank row, then the header row (each row is exactly one line)
  M_KEY+=("") M_LABEL+=("") M_DESC+=("")
  [[ -n $1 ]] && M_KEY+=("#") M_LABEL+=("$1") M_DESC+=("")
  return 0
}

main_menu() {
  while :; do
    M_KEY=() M_LABEL=() M_DESC=() M_BADGE=()
    load_update_state
    cat_badge "${CATEGORIES[@]}"; mi 1 "Smart Scan" "Scan everything and clean in one go" "$BADGE"
    mh "Cleanup"
    cat_badge system;            mi 2 "System Junk" "Package cache, old kernels, leftover configs, snaps, temp files" "$BADGE"
    cat_badge logs;              mi 3 "Logs" "Journal, oversized and rotated logs, crash reports, app logs" "$BADGE"
    cat_badge user browser apps; mi 4 "User & App Junk" "Trash, thumbnails, browser and app caches" "$BADGE"
    cat_badge ai models;         mi 5 "AI Tools" "Claude, Codex, Gemini, opencode, Zed: caches, old chats, models" "$BADGE"
    cat_badge dev;               mi 6 "Developer Junk" "Stale node_modules, npm, pip, Go, Cargo, Conda, Docker…" "$BADGE"
    cat_badge privacy;           mi 7 "Privacy" "Terminal history, recent files, run dialog…" "$BADGE"
    mh "Files"
    mi 8 "Space Lens" "Explore what takes up space, folder by folder"
    mi 9 "Large & Old Files" "Find space hogs and forgotten downloads"
    mi 0 "Duplicates" "Find identical files and keep one copy"
    mh "Apps & System"
    mi u "Uninstaller" "Remove apps and their leftovers"
    mi t "Startup Items" "Choose what launches at login"
    mi m "Maintenance" "Updates, repairs, TRIM, free RAM"
    mi i "System Overview" "Storage, memory and your biggest folders"
    mh ""
    ((${#UNDO_BATCH[@]})) && mi z "↶ Undo last Trash" "Put back the $(plural ${#UNDO_BATCH[@]} item) you just moved to the Trash"
    mi s "Settings" "Automatic cleaning, updates, retention, about"
    [[ -n $UPDATE_LATEST ]] && mi n "⬆ Update to $UPDATE_LATEST" "You have $VERSION — install the new version"
    mi q "Quit"
    ui_menu "Home" home_top || return 0
    case ${M_KEY[MENU_IDX]} in
      1) scan_and_review "Smart Scan" "${CATEGORIES[@]}" ;;
      2) scan_and_review "System Junk" system ;;
      3) scan_and_review "Logs" logs ;;
      4) scan_and_review "User & App Junk" user browser apps ;;
      5) scan_and_review "AI Tools" ai models ;;
      6) scan_and_review "Developer Junk" dev ;;
      7) scan_and_review "Privacy" privacy ;;
      8) space_lens_menu ;;
      9) large_files_menu ;;
      0) duplicates_menu ;;
      u) uninstaller_menu ;;
      t) startup_menu ;;
      m) maintenance_menu ;;
      i) overview ;;
      s) settings_menu ;;
      n) ui_update ;;
      z) undo_trash; undo_toast ;;
      q) return 0 ;;
    esac
    refresh_sysinfo
  done
}

# Sourced (e.g. by tests/run.sh)? Stop here: only define functions and defaults.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

while (($#)); do
  case $1 in
    -n | --dry-run) DRY_RUN=1 ;;
    -s | --scan) MODE=scan ;;
    -c | --clean) MODE=clean ;;
    -y | --yes) ASSUME_YES=1 ;;
    --auto) MODE=auto ;;
    --no-mouse) MOUSE=0 ;;
    --only)
      shift
      IFS=, read -ra CATEGORIES <<<"${1:-}"
      for _c in "${CATEGORIES[@]}"; do
        [[ -n ${CAT_TITLE[$_c]:-} ]] || { err "Unknown category: $_c (use system, logs, user, browser, apps, ai, models, dev, privacy)"; exit 2; }
      done ;;
    -h | --help) usage; exit 0 ;;
    -v | --version) echo "clean-my-ubuntu $VERSION"; exit 0 ;;
    --install) MODE=install ;;
    --uninstall) MODE=uninstall ;;
    --update) MODE=update ;;
    --json) MODE=json ;;
    --gui) MODE=gui ;;
    -*) err "Unknown option: $1"; usage; exit 2 ;;
    *)
      [[ $MODE == json ]] || { err "Unknown argument: $1"; usage; exit 2; }
      JSON_ARGS+=("$1") ;;
  esac
  shift
done

on_interrupt() { # stop every background job and its children (they ignore SIGINT)
  local p
  for p in $(jobs -p); do kill_tree "$p"; done
  ui_stop
  printf '%s\n' "$NC"
  exit 130
}

SESSION_TMP=$(mktemp -d -t clean-my-ubuntu.XXXXXX) || exit 1
trap 'rm -rf "$SESSION_TMP"' EXIT
trap 'on_interrupt' INT TERM

load_kv "$PREF_FILE" PREF '^[01]$'
load_kv "$STATS_FILE" STATS '^[0-9]+$'
load_kv "$SETTINGS_FILE" CFG '^[0-9]+$'
apply_settings
load_scan_cache

case $MODE in
  scan) INTERACTIVE=0; scan_report; exit 0 ;;
  clean) INTERACTIVE=0; smart_clean; exit 0 ;;
  auto) auto_mode; exit 0 ;;
  install) INTERACTIVE=0; cli_install; exit ;;
  uninstall) INTERACTIVE=0; cli_uninstall; exit ;;
  update) INTERACTIVE=0; cli_update; exit ;;
  json) INTERACTIVE=0 ASSUME_YES=1 JSON=1; json_main "${JSON_ARGS[@]}"; exit ;;
  gui) launch_gui; exit ;;
esac
((ASSUME_YES)) && { err "--yes only works together with --clean."; exit 2; }

[[ -t 0 && -t 1 ]] || { err "This script is interactive; run it from a terminal (or use --scan)."; exit 1; }

if ((EUID == 0)); then
  warn "Running as root: user-level cleanup will target /root, not your account."
  confirm "Continue anyway? (Recommended: run as your user, sudo is requested when needed)" || exit 1
fi

trap 'ui_stop; rm -rf "$SESSION_TMP"' EXIT
refresh_sysinfo
update_check_bg
ui_start
main_menu
ui_stop
printf '\n  %sBye! Keep it clean. ✨%s\n\n' "$ACCENT" "$NC"
