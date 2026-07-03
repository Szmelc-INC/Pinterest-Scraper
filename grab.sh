#!/usr/bin/env bash
# grab.sh — full-res Pinterest downloader
# Supports: images + videos + gifs + idea/story pins
# Wrapper around gallery-dl + ffmpeg. Handles pins, boards, sections, pin.it links,
# and whole user profiles. Resumable, dedupes, pulls originals / HLS full-res video.
#
# Clean output: scans the board first and reports the total, then shows a single live
#   Downloading [N/total]   Success: X   Failed: Y
#   line. "Failed" is only counted after gallery-dl exhausts every retry AND fallback URL.
#   deps:  gallery-dl (pip install gallery-dl)  +  ffmpeg (for HLS video muxing)
#
# Usage:
#   ./grab.sh -b firefox "https://www.pinterest.com/serainox/teledysk-core/"
#   ./grab.sh -b firefox -L "https://pin.it/xxxxxxx"     # preview, download nothing


set -euo pipefail

# ---- defaults -------------------------------------------------------------
OUTDIR="" ; BROWSER="" ; COOKIES="" ; CURLFILE="" ; ARCHIVE="" ; RANGE="" ; URL=""
CURL_UA="" ; COOKIE_ARG=() ; UA_ARG=() ; TMPCK=""
VIDEOS=true ; SECTIONS=true ; STORIES=true ; FLAT=true
SLEEP="1.0" ; RETRIES=4 ; LIST=false ; METADATA=false ; INSECURE=false

# ---- pretty ---------------------------------------------------------------
if [[ -t 1 ]]; then TTY=1
  c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_cyn=$'\e[36m'
  c_dim=$'\e[2m'; c_bold=$'\e[1m'; c_rst=$'\e[0m'
else TTY=0; c_red= c_grn= c_yel= c_cyn= c_dim= c_bold= c_rst= ; fi
info(){ printf '%s[i]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$c_yel" "$c_rst" "$*" >&2; }
die (){ printf '%s[-]%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

# Convert a browser "Copy as cURL" blob (or a raw Cookie header/string) into a
# Netscape cookies.txt at $2. Also sets global CURL_UA if a user-agent is present.
# Returns non-zero if no cookie data could be found. Handles values containing
# " { } % : by matching only up to the SAME quote that opened the header.
curl_to_netscape(){
  local src="$1" out="$2" cstr="" ua=""
  cstr=$(grep -oiP "(['\"])cookie:\s*\K.*(?=\1)"          "$src" | head -1)   # -H 'cookie: ...'
  [[ -n "$cstr" ]] || cstr=$(grep -oiP "(?:-b|--cookie)\s+(['\"])\K.*(?=\1)" "$src" | head -1)  # -b '...'
  [[ -n "$cstr" ]] || cstr=$(grep -oiP "^\s*cookie:\s*\K.*$" "$src" | head -1)  # bare "cookie: ..." line
  [[ -n "$cstr" ]] || cstr=$(grep -oiP "^[^=;[:space:]]+=[^;]*;.*"  "$src" | head -1)  # bare "a=b; c=d" line
  [[ -n "$cstr" ]] || return 1

  ua=$(grep -oiP "(['\"])user-agent:\s*\K.*(?=\1)" "$src" | head -1)
  [[ -n "$ua" ]] || ua=$(grep -oiP "^\s*user-agent:\s*\K.*$" "$src" | head -1)
  CURL_UA="$ua"

  umask 077
  { printf '# Netscape HTTP Cookie File\n'
    printf '%s\n' "$cstr" | tr ';' '\n' | while IFS= read -r pair || [[ -n "$pair" ]]; do
      pair="${pair#"${pair%%[![:space:]]*}"}"     # ltrim
      pair="${pair%"${pair##*[![:space:]]}"}"      # rtrim
      [[ -z "$pair" || "$pair" != *=* ]] && continue
      # domain  include_subdomains  path  secure  expiry  name  value
      printf '.pinterest.com\tTRUE\t/\tTRUE\t2000000000\t%s\t%s\n' "${pair%%=*}" "${pair#*=}"
    done
  } > "$out"

  [[ $(grep -c '^\.pinterest\.com' "$out") -gt 0 ]] || return 1
  return 0
}

usage(){ cat <<EOF
${c_bold}pin-grab.sh${c_rst} — full-res Pinterest downloader

USAGE:
  pin-grab.sh [OPTIONS] <PINTEREST_URL>

OPTIONS:
  -o, --outdir DIR     Output folder (default: derived from the URL slug)
  -b, --browser NAME   Read cookies from a logged-in browser:
                         firefox | chromium | chrome | brave | edge | vivaldi | opera
                         (append /PROFILE if needed, e.g. firefox/default-release)
  -c, --cookies FILE   Cookie file. Accepts EITHER a Netscape cookies.txt OR a
                         browser "Copy as cURL" blob — it auto-detects and, for a
                         cURL blob, extracts the cookie header (+ user-agent) itself.
      --curl FILE      Force cURL-blob mode (paste a full "Copy as cURL" request here).
                         Handy when Chromium keyring decryption fails on -b.
  -a, --archive FILE   Resume/dedupe DB (default: <outdir>/.gdl-archive)
  -r, --range RANGE    Only fetch items in RANGE, e.g. "1-100" or "50-"
  -s, --sleep SEC      Pause between downloads (default: $SLEEP)
  -R, --retries N      Retries per file before a fallback URL is tried (default: $RETRIES)
      --no-videos      Skip videos (images/gifs only)
      --no-sections    Don't descend into board sections
      --no-stories     Skip idea/story pins
      --tree           Keep gallery-dl's user/board folder tree (default: flat)
  -k, --insecure       Skip TLS cert verification (needed behind an intercepting proxy)
  -m, --metadata       Write a .json metadata sidecar per item
  -L, --list           Preview what WOULD download — no files written
  -h, --help           This help

EXAMPLES:
  pin-grab.sh -b firefox "https://www.pinterest.com/serainox/teledysk-core/"
  pin-grab.sh -o clip "https://pin.it/xxxxxxx"
  pin-grab.sh -b firefox -L "https://www.pinterest.com/user/board/"
EOF
}

# ---- args -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--outdir)   OUTDIR="${2:?}"; shift 2;;
    -b|--browser)  BROWSER="${2:?}"; shift 2;;
    -c|--cookies)  COOKIES="${2:?}"; shift 2;;
    --curl)        CURLFILE="${2:?}"; shift 2;;
    -a|--archive)  ARCHIVE="${2:?}"; shift 2;;
    -r|--range)    RANGE="${2:?}"; shift 2;;
    -s|--sleep)    SLEEP="${2:?}"; shift 2;;
    -R|--retries)  RETRIES="${2:?}"; shift 2;;
    --no-videos)   VIDEOS=false; shift;;
    --no-sections) SECTIONS=false; shift;;
    --no-stories)  STORIES=false; shift;;
    --tree)        FLAT=false; shift;;
    -k|--insecure) INSECURE=true; shift;;
    -m|--metadata) METADATA=true; shift;;
    -L|--list)     LIST=true; shift;;
    -h|--help)     usage; exit 0;;
    -*)            die "Unknown option: $1  (see --help)";;
    *)             [[ -z "$URL" ]] && URL="$1" || die "Pass only one URL."; shift;;
  esac
done
[[ -n "$URL" ]] || { usage; exit 1; }

# ---- deps -----------------------------------------------------------------
command -v gallery-dl >/dev/null 2>&1 || die "gallery-dl not found.  ->  pip install gallery-dl"
if [[ "$VIDEOS" == true ]]; then
  command -v ffmpeg >/dev/null 2>&1 || \
    warn "ffmpeg not found — most Pinterest videos need it to mux to mp4."
  { command -v yt-dlp >/dev/null 2>&1 || python3 -c 'import yt_dlp' 2>/dev/null; } || \
    warn "yt-dlp not found — some video pins (idea/story HLS) route through it and will"\
'\n    fail without it.  ->  pip install yt-dlp'
fi

# ---- resolve pin.it -------------------------------------------------------
if [[ "$URL" == *pin.it/* ]]; then
  resolved="$(curl -fsIL -o /dev/null -w '%{url_effective}' "$URL" 2>/dev/null || true)"
  [[ "$resolved" == http* ]] && URL="$resolved"
fi

# ---- derive outdir --------------------------------------------------------
if [[ -z "$OUTDIR" ]]; then
  path="${URL#*pinterest.com/}"; path="${path%%[?#]*}"; path="${path%/}"
  case "$path" in
    pin/*) OUTDIR="pin-${path##*/}";;
    */*)   OUTDIR="${path##*/}";;
    *)     OUTDIR="${path:-pinterest}";;
  esac
  OUTDIR="$(printf '%s' "$OUTDIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' \
            | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
  [[ -n "$OUTDIR" ]] || OUTDIR="pinterest"
fi
[[ -n "$ARCHIVE" ]] || ARCHIVE="$OUTDIR/.gdl-archive"
mkdir -p "$OUTDIR"
LOG="$OUTDIR/.pin-grab.log"; : > "$LOG"

# ---- cookie source: browser | netscape file | cURL blob ------------------
srcfile="${CURLFILE:-$COOKIES}"
if [[ -n "$srcfile" ]]; then
  [[ -r "$srcfile" ]] || die "Cookie file not readable: $srcfile"
  [[ -n "$BROWSER" ]] && { warn "Both a cookie file and --browser given; using the file."; BROWSER=""; }

  # decide whether to parse as a cURL blob: forced by --curl, or auto-detected for -c
  as_curl=false
  if [[ -n "$CURLFILE" ]]; then
    as_curl=true
  elif ! head -1 "$srcfile" | grep -qi "Netscape HTTP Cookie File" \
       && grep -qiE "curl |[-]{1,2}H |cookie:|(^|[[:space:]])-b " "$srcfile"; then
    as_curl=true
  fi

  if $as_curl; then
    TMPCK="$(mktemp "${TMPDIR:-/tmp}/pin-grab.cookies.XXXXXX")"
    trap '[[ -n "$TMPCK" ]] && rm -f "$TMPCK"' EXIT
    curl_to_netscape "$srcfile" "$TMPCK" \
      || die "Couldn't find a cookie header/string in: $srcfile  (paste a full 'Copy as cURL')"
    ncookies=$(( $(grep -c '^\.pinterest\.com' "$TMPCK") ))
    info "Parsed ${c_bold}${ncookies}${c_rst} cookies from cURL blob${CURL_UA:+ (+ user-agent)}"
    COOKIE_ARG=( --cookies "$TMPCK" )
    [[ -n "$CURL_UA" ]] && UA_ARG=( -o "extractor.pinterest.user-agent=$CURL_UA" )
  else
    COOKIE_ARG=( --cookies "$srcfile" )   # already Netscape
  fi
elif [[ -z "$BROWSER" ]]; then
  warn "No cookies set — private/large boards & many video pins are login-gated;"
  warn "you may get only a partial board. Use  -b firefox , or  --curl req.txt"
  warn "(paste a 'Copy as cURL' of any pinterest.com request — beats keyring decrypt)."
fi

# ---- shared extractor/auth args -------------------------------------------
base=( -o "extractor.pinterest.videos=$VIDEOS"
       -o "extractor.pinterest.sections=$SECTIONS"
       -o "extractor.pinterest.stories=$STORIES" )
[[ -n "$BROWSER" ]] && base+=( --cookies-from-browser "$BROWSER" )
base+=( ${COOKIE_ARG[@]+"${COOKIE_ARG[@]}"} )
base+=( ${UA_ARG[@]+"${UA_ARG[@]}"} )
[[ -n "$RANGE"   ]] && base+=( --range "$RANGE" )
[[ "$INSECURE" == true ]] && base+=( --no-check-certificate \
    -o "downloader.ytdl.raw-options.nocheckcertificate=true" )

board_name="${URL#*pinterest.com/}"; board_name="${board_name%%[?#]*}"
printf '\n%s┌─ Pinterest grab ─────────────────────────────%s\n' "$c_cyn" "$c_rst"
printf '%s│%s target : %s\n' "$c_cyn" "$c_rst" "$board_name"
printf '%s│%s out    : %s\n' "$c_cyn" "$c_rst" "$(realpath "$OUTDIR" 2>/dev/null || echo "$OUTDIR")"
printf '%s│%s media  : videos=%s sections=%s stories=%s\n' "$c_cyn" "$c_rst" "$VIDEOS" "$SECTIONS" "$STORIES"
printf '%s└──────────────────────────────────────────────%s\n\n' "$c_cyn" "$c_rst"

# ---- scan pass: count total items -----------------------------------------
printf '%s[*]%s Scanning board … ' "$c_cyn" "$c_rst"
scan="$(stdbuf -oL gallery-dl "${base[@]}" --simulate --sleep 0 "$URL" 2>>"$LOG" || true)"
total="$(printf '%s\n' "$scan" | grep -c '^#' || true)"
printf '\r%s[*]%s Scan complete.            \n' "$c_cyn" "$c_rst"

if [[ "${total:-0}" -eq 0 ]]; then
  warn "Found 0 items. Usually means login-gated content — retry with -b <browser>."
  warn "Raw scan errors logged to: $LOG"
  exit 1
fi
info "Found ${c_bold}${total}${c_rst} downloadable item(s) ${c_dim}(images / videos / gifs; idea pins may be >1 file each)${c_rst}"

# ---- list mode: show and exit ---------------------------------------------
if [[ "$LIST" == true ]]; then
  echo; printf '%s\n' "$scan" | sed "s/^# /   /"
  exit 0
fi

# ---- download pass with live counter --------------------------------------
dl=( "${base[@]}" --sleep "$SLEEP" --retries "$RETRIES" --download-archive "$ARCHIVE" )
[[ "$FLAT" == true ]] && dl+=( -D "$OUTDIR" ) || dl+=( -d "$OUTDIR" )
[[ "$METADATA" == true ]] && dl+=( --write-metadata )

n=0 success=0 failed=0 skipped=0 rc=0
draw(){
  if [[ $TTY == 1 ]]; then
    printf '\r\e[K  %sDownloading%s [%d/%d]   %sSuccess:%s %d   %sFailed:%s %d' \
      "$c_cyn" "$c_rst" "$n" "$total" "$c_grn" "$c_rst" "$success" "$c_red" "$c_rst" "$failed"
  elif (( n % 20 == 0 )); then
    printf '  Downloading [%d/%d]   Success: %d   Failed: %d\n' "$n" "$total" "$success" "$failed"
  fi
}
echo
while IFS= read -r line; do
  if [[ $line == RC:* ]]; then rc="${line#RC:}"; continue; fi
  printf '%s\n' "$line" >> "$LOG"
  case "$line" in
    *.json) : ;;                                   # metadata sidecar — don't count
    "# $OUTDIR/"*) skipped=$((skipped+1)); success=$((success+1)); n=$((n+1)); draw ;;
    "$OUTDIR/"*)   success=$((success+1)); n=$((n+1)); draw ;;
    *"Failed to download"*) failed=$((failed+1)); n=$((n+1)); draw ;;
  esac
done < <( { stdbuf -oL -eL gallery-dl "${dl[@]}" "$URL" 2>&1; echo "RC:$?"; } )

# authoritative reconcile: anything on the board not on disk is a failure
success=$(( success > total ? total : success ))
failed=$(( total - success )); (( failed < 0 )) && failed=0
n=$total; draw
[[ $TTY == 1 ]] && echo

echo
if [[ $failed -eq 0 ]]; then
  info "${c_grn}${c_bold}Done.${c_rst} $success/$total downloaded${skipped:+ (${skipped} already had, skipped)} → $(realpath "$OUTDIR")"
else
  warn "Done with issues: ${c_grn}$success ok${c_rst}, ${c_red}$failed failed${c_rst} of $total."
  warn "Failure details: grep 'Failed to download' \"$LOG\""
  warn "Most failures = expired/absent cookies. Re-run same command (archive resumes)."
fi
exit "${rc:-0}"
