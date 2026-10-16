#!/bin/bash
# =============================================================================
# local-llm-checkup.sh - Local LLM prefix-cache checkup for macOS
#
# Checks the configuration that commonly breaks the KV prefix cache of local
# LLM servers (Ollama, LM Studio, llama.cpp) and proves with a live test whether
# the cache is hit. Writes a markdown report with results, score and fixes.
#
# Implements documentation/SPECIFICATION-MacOS.md (version 1.0.0).
# Bash 3.2 compatible (no associative arrays, no ${var,,}, no mapfile).
# Read-only: never changes configuration, environment variables or settings.
# Errors and diagnostics go to stderr; results go to stdout and the report.
# =============================================================================

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX_FILE="$SCRIPT_DIR/prefix.txt"
HYBRID_FILE="$SCRIPT_DIR/hybrid-models.txt"
MIN_CLAUDE="2.1.181"          # first Claude Code version with the attribution-header fix
MAX_TOKENS=64                 # spec 4.6
REQ_TIMEOUT=300               # per-request curl timeout (s); covers a cold model load
KEEP_ALIVE="10m"              # Ollama: keep the model (and its cache) loaded between requests

# ----------------------------------------------------------------------------
# Defaults for options
# ----------------------------------------------------------------------------
# Empty means "not given on the command line" so a config file can fill it in
# (precedence: CLI > config file > built-in default / auto-detect).
OPT_SERVER=""; OPT_URL=""; OPT_MODEL=""; OPT_LOG=""; OPT_SESSION_LOG=""
OPT_SKIP_LIVE=""; OPT_OUTPUT=""; OPT_NO_COLOR=""
OPT_CONFIG=""; OPT_LIST_MODELS=0; OPT_INTERACTIVE=0
MODEL_SOURCE=""     # how the model was chosen: CLI, config, interactive, default
CONFIG_USED=""      # config file actually read (for the report)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
err()  { printf 'local-llm-checkup: error: %s\n' "$*" >&2; }
warn() { printf 'local-llm-checkup: warning: %s\n' "$*" >&2; }

usage() {
cat <<USAGE
local-llm-checkup.sh $VERSION - check whether your local LLM server hits its prompt cache

Usage: local-llm-checkup.sh [options]

  -s, --server <ollama|lmstudio|llamacpp>   Server to test (default: auto-detect)
  -u, --url <url>                           Override endpoint
  -m, --model <name>                        Model to test (validated against installed models;
                                            default: first loaded model)
  -i, --interactive                         Choose server and model from a menu (automatic on a
                                            terminal when no model is given by CLI or config)
      --list-models                         List installed models for the server and exit
  -c, --config <file>                       Config file (default: ./local-llm-checkup.conf next to
                                            the script, then ~/.config/local-llm-checkup/config)
  -l, --log <path>                          Server log file for C3 and C4
      --session-log <path>                  Agent session log for C4 (optional)
      --skip-live                           Run static checks only
  -o, --output <dir>                        Report directory (default: ./reports); writes
                                            llm-checkup-macos-<timestamp>.md and a .html copy
      --no-color                            Disable colours
  -h, --help                                Show help
      --version                             Show version

Config file: KEY=value lines; keys SERVER, URL, MODEL, LOG, SESSION_LOG, OUTPUT,
SKIP_LIVE (0/1), NO_COLOR (0/1). Command-line options override the config file.

Exit codes: 0 all scored items PASS, 1 WARN (no FAIL), 2 at least one FAIL, 3 tool error.
USAGE
}

# Lower-case a string (Bash 3.2 has no ${var,,}).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Format an integer with thousands separators (locale independent).
fmtn() {
  case "$1" in ''|*[!0-9]*) printf '%s' "$1"; return;; esac
  printf '%s' "$1" | awk '{ s=$0; o=""; while (length(s)>3) { o="," substr(s,length(s)-2) o; s=substr(s,1,length(s)-3) } print s o }'
}

# Round seconds to 3 decimals for display.
r3() { awk -v x="$1" 'BEGIN{ printf "%.3f", x }'; }

# Compare dotted versions: returns 0 if $1 >= $2.
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na=split(a,x,"."); nb=split(b,y,"."); n=(na>nb)?na:nb
    for (i=1;i<=n;i++) { xi=x[i]+0; yi=y[i]+0; if (xi>yi) exit 0; if (xi<yi) exit 1 }
    exit 0 }'
}

# Expand a leading ~ in a path.
expand_path() { case "$1" in "~"/*) printf '%s' "$HOME/${1#\~/}";; *) printf '%s' "$1";; esac; }

# ----------------------------------------------------------------------------
# Argument parsing (bad arguments -> exit 3)
# ----------------------------------------------------------------------------
need_arg() { if [ -z "$2" ] || [ "${2#-}" != "$2" ]; then err "option $1 requires a value"; usage >&2; exit 3; fi; }
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--server) need_arg "$1" "$2"; OPT_SERVER="$(lower "$2")"; shift 2;;
    -u|--url) need_arg "$1" "$2"; OPT_URL="${2%/}"; shift 2;;
    -m|--model) need_arg "$1" "$2"; OPT_MODEL="$2"; shift 2;;
    -c|--config) need_arg "$1" "$2"; OPT_CONFIG="$(expand_path "$2")"; shift 2;;
    -i|--interactive) OPT_INTERACTIVE=1; shift;;
    --list-models) OPT_LIST_MODELS=1; shift;;
    -l|--log) need_arg "$1" "$2"; OPT_LOG="$(expand_path "$2")"; shift 2;;
    --session-log) need_arg "$1" "$2"; OPT_SESSION_LOG="$(expand_path "$2")"; shift 2;;
    --skip-live) OPT_SKIP_LIVE=1; shift;;
    -o|--output) need_arg "$1" "$2"; OPT_OUTPUT="$(expand_path "$2")"; shift 2;;
    --no-color|--no-colour) OPT_NO_COLOR=1; shift;;
    -h|--help) usage; exit 0;;
    --version) printf 'local-llm-checkup.sh %s\n' "$VERSION"; exit 0;;
    *) err "unknown option: $1"; usage >&2; exit 3;;
  esac
done
# ----------------------------------------------------------------------------
# Config file: parsed line by line as KEY=value. Never sourced or eval'd.
# ----------------------------------------------------------------------------
if [ -n "$OPT_CONFIG" ]; then
  [ -r "$OPT_CONFIG" ] || { err "config file not readable: $OPT_CONFIG"; exit 3; }
  CONFIG_USED="$OPT_CONFIG"
elif [ -r "$SCRIPT_DIR/local-llm-checkup.conf" ]; then
  CONFIG_USED="$SCRIPT_DIR/local-llm-checkup.conf"
elif [ -r "$HOME/.config/local-llm-checkup/config" ]; then
  CONFIG_USED="$HOME/.config/local-llm-checkup/config"
fi
CFG_MODEL=0   # 1 when MODEL came from the config file
if [ -n "$CONFIG_USED" ]; then
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Trim whitespace; skip blanks and full-line comments.
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$line" in ''|'#'*) continue;; esac
    case "$line" in *=*) ;; *) warn "$CONFIG_USED:$lineno: ignored (not KEY=value): $line"; continue;; esac
    key="$(printf '%s' "${line%%=*}" | sed 's/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')"
    val="$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//')"
    # Strip one pair of matching surrounding quotes; otherwise drop a trailing " # comment".
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}";;
      \'*\') val="${val#\'}"; val="${val%\'}";;
      *) val="$(printf '%s' "$val" | sed 's/[[:space:]]#.*$//')";;
    esac
    case "$key" in
      SERVER)      [ -z "$OPT_SERVER" ] && OPT_SERVER="$(lower "$val")";;
      URL)         [ -z "$OPT_URL" ] && OPT_URL="${val%/}";;
      MODEL)       if [ -z "$OPT_MODEL" ] && [ -n "$val" ]; then OPT_MODEL="$val"; CFG_MODEL=1; fi;;
      LOG)         [ -z "$OPT_LOG" ] && OPT_LOG="$(expand_path "$val")";;
      SESSION_LOG) [ -z "$OPT_SESSION_LOG" ] && OPT_SESSION_LOG="$(expand_path "$val")";;
      OUTPUT)      [ -z "$OPT_OUTPUT" ] && OPT_OUTPUT="$(expand_path "$val")";;
      SKIP_LIVE|NO_COLOR)
        case "$(lower "$val")" in 1|true|yes|on) b=1;; 0|false|no|off|'') b=0;;
          *) warn "$CONFIG_USED:$lineno: $key must be 0 or 1, got '$val'; ignored"; continue;; esac
        if [ "$key" = SKIP_LIVE ]; then [ -z "$OPT_SKIP_LIVE" ] && OPT_SKIP_LIVE=$b
        else [ -z "$OPT_NO_COLOR" ] && OPT_NO_COLOR=$b; fi;;
      *) warn "$CONFIG_USED:$lineno: unknown key '$key' ignored";;
    esac
  done < "$CONFIG_USED"
fi
# Built-in defaults for anything still unset.
[ -z "$OPT_SKIP_LIVE" ] && OPT_SKIP_LIVE=0
[ -z "$OPT_NO_COLOR" ] && OPT_NO_COLOR=0
[ -z "$OPT_OUTPUT" ] && OPT_OUTPUT="./reports"
if [ -n "$OPT_MODEL" ]; then if [ "$CFG_MODEL" -eq 1 ]; then MODEL_SOURCE="config"; else MODEL_SOURCE="CLI"; fi; fi

case "$OPT_SERVER" in ''|ollama|lmstudio|llamacpp) ;; *) err "invalid --server '$OPT_SERVER' (use ollama, lmstudio or llamacpp)"; exit 3;; esac
if [ -n "$OPT_URL" ] && [ -z "$OPT_SERVER" ]; then err "--url requires --server so the API type is known"; exit 3; fi
if [ -n "$OPT_LOG" ] && [ ! -r "$OPT_LOG" ]; then err "log file not readable: $OPT_LOG"; exit 3; fi
if [ -n "$OPT_SESSION_LOG" ] && [ ! -r "$OPT_SESSION_LOG" ]; then err "session log not readable: $OPT_SESSION_LOG"; exit 3; fi

# ----------------------------------------------------------------------------
# Colours (spec 6): off with --no-color, NO_COLOR, or non-tty stdout
# ----------------------------------------------------------------------------
if [ "$OPT_NO_COLOR" -eq 1 ] || [ -n "${NO_COLOR+x}" ] || [ ! -t 1 ]; then
  C_G=""; C_Y=""; C_R=""; C_D=""; C_C=""; C_B=""; C_0=""
else
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_D=$'\033[2;37m'; C_C=$'\033[36m'; C_B=$'\033[1m'; C_0=$'\033[0m'
fi
res_color() { case "$1" in PASS) printf '%s' "$C_G";; WARN) printf '%s' "$C_Y";; FAIL|ERROR) printf '%s' "$C_R";; *) printf '%s' "$C_D";; esac; }
heading() { printf '%s%s%s\n' "$C_C$C_B" "$*" "$C_0"; }
progress() { printf '%s  ... %s%s\n' "$C_C" "$*" "$C_0"; }

# ----------------------------------------------------------------------------
# Dependencies (spec 9). jq missing -> install hint, exit 3. Never installs.
# ----------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but not installed. Install it with: brew install jq"
  exit 3
fi
for dep in curl sed awk grep date sysctl sw_vers; do
  command -v "$dep" >/dev/null 2>&1 || { err "required command not found: $dep"; exit 3; }
done
[ -r "$PREFIX_FILE" ] || { err "prefix file missing: $PREFIX_FILE"; exit 3; }
[ -r "$HYBRID_FILE" ] || { err "hybrid model list missing: $HYBRID_FILE"; exit 3; }
mkdir -p "$OPT_OUTPUT" 2>/dev/null || { err "cannot create output directory: $OPT_OUTPUT"; exit 3; }
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/llm-checkup.XXXXXX")" || { err "cannot create temp dir"; exit 3; }
trap 'rm -rf "$TMPD"' EXIT

START_TS="$(date '+%Y%m%d-%H%M%S')"; START_HUMAN="$(date '+%Y-%m-%d %H:%M:%S %Z')"
REPORT="$OPT_OUTPUT/llm-checkup-macos-$START_TS.md"

# ----------------------------------------------------------------------------
# Results storage (parallel indexed arrays; Bash 3.2 has no associative arrays)
# ----------------------------------------------------------------------------
R_ID=(); R_NAME=(); R_RES=(); R_SCORE=(); R_DETAIL=()
record() {  # id name result detail
  local score="-"
  case "$3" in PASS) score="1.0";; WARN) score="0.5";; FAIL) score="0.0";; esac
  R_ID+=("$1"); R_NAME+=("$2"); R_RES+=("$3"); R_SCORE+=("$score"); R_DETAIL+=("$4")
  # One line per check: "[C1] Claude Code attribution header ........ PASS"
  local label="[$1] $2 " dots=""
  local n=$(( 52 - ${#label} )); [ $n -lt 3 ] && n=3
  dots="$(printf '%*s' "$n" '' | tr ' ' '.')"
  printf '%s%s %s%s%s  %s%s%s\n' "$label" "$dots" "$(res_color "$3")" "$3" "$C_0" "$C_D" "$4" "$C_0"
}

# ----------------------------------------------------------------------------
# Environment (spec 3.3)
# ----------------------------------------------------------------------------
[ "$OPT_LIST_MODELS" -eq 0 ] && heading "Local LLM Checkup for macOS $VERSION"
OS_VER="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
MEM_B="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
MEM_GB="$(awk -v b="$MEM_B" 'BEGIN{ printf "%.0f GB", b/1073741824 }')"
ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || warn "this tool targets Apple Silicon (arm64); detected $ARCH"

CLAUDE_VER_RAW=""; CLAUDE_VER=""
if command -v claude >/dev/null 2>&1; then
  CLAUDE_VER_RAW="$(claude --version 2>/dev/null | head -n 1)"
  CLAUDE_VER="$(printf '%s' "$CLAUDE_VER_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
fi
OLLAMA_VER=""; command -v ollama >/dev/null 2>&1 && OLLAMA_VER="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -n 1)"
LMS_VER=""; command -v lms >/dev/null 2>&1 && LMS_VER="$(lms version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
LLAMA_VER=""; command -v llama-server >/dev/null 2>&1 && LLAMA_VER="$(llama-server --version 2>&1 | grep -iE '^version' | head -n 1 | sed 's/^version: *//')"

# ----------------------------------------------------------------------------
# Server detection (spec 2.1): explicit --server or probe Ollama -> LM Studio -> llama.cpp
# ----------------------------------------------------------------------------
default_url() { case "$1" in ollama) echo "http://localhost:11434";; lmstudio) echo "http://localhost:1234";; llamacpp) echo "http://localhost:8080";; esac; }
server_label() { case "$1" in ollama) echo "Ollama";; lmstudio) echo "LM Studio";; llamacpp) echo "llama.cpp (llama-server)";; *) echo "none";; esac; }
probe() {  # server url -> 0 if it answers its detection endpoint; saves the reply as probe-<server>.json
  local path="/v1/models"; [ "$1" = "ollama" ] && path="/api/tags"
  curl -fsS -m 3 "$2$path" -o "$TMPD/probe-$1.json" 2>/dev/null && jq -e . "$TMPD/probe-$1.json" >/dev/null 2>&1
}
# Prompt only when both stdin and stdout are terminals.
is_tty() { [ -t 0 ] && [ -t 1 ]; }

# Interactive menu: prints numbered options to stderr-free stdout, reads a number from stdin.
# Usage: choose <title> <file with one option per line>  -> prints chosen line
choose() {
  local title="$1" file="$2" n i=1 ans line
  n="$(wc -l < "$file" | tr -d ' ')"
  printf '%s\n' "$title" >/dev/tty
  while IFS= read -r line; do printf '  %2d) %s\n' "$i" "$line" >/dev/tty; i=$((i+1)); done < "$file"
  while :; do
    printf 'Choose 1-%s [1]: ' "$n" >/dev/tty
    IFS= read -r ans || { err "no selection (end of input)"; exit 3; }
    [ -z "$ans" ] && ans=1
    case "$ans" in *[!0-9]*) printf '  Please enter a number.\n' >/dev/tty; continue;; esac
    if [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ]; then sed -n "${ans}p" "$file"; return 0; fi
    printf '  Out of range.\n' >/dev/tty
  done
}

# Installed models for $SERVER -> $TMPD/models.tsv as "name<TAB>size_bytes<TAB>embed(0|1)".
# Embedding models are detected by name, Ollama family (bert) or LM Studio "type".
EMBED_RE='embed|bge-|minilm|e5-|gte-|nomic-bert|rerank'
list_installed() {
  local f="$TMPD/probe-$SERVER.json"
  if [ "$SERVER" = "ollama" ]; then
    jq -r --arg re "$EMBED_RE" '.models[] | [.name, (.size // 0 | tostring),
        (if (.name|test($re;"i")) or ((.details.family // "")|test("bert";"i")) then "1" else "0" end)] | @tsv' "$f"
  else
    jq -r --arg re "$EMBED_RE" '.data[] | [.id, "0",
        (if (.id|test($re;"i")) or ((.type // "")|test("embed";"i")) then "1" else "0" end)] | @tsv' "$f"
  fi > "$TMPD/models.tsv" 2>/dev/null
}
human_size() { awk -v b="$1" 'BEGIN{ if (b<=0) print "-"; else if (b>=1073741824) printf "%.1f GB", b/1073741824; else printf "%.0f MB", b/1048576 }'; }

SERVER=""; URL=""; SERVER_NOTE=""; RESPONDING=""
if [ -n "$OPT_SERVER" ]; then
  URL="${OPT_URL:-$(default_url "$OPT_SERVER")}"
  if probe "$OPT_SERVER" "$URL"; then SERVER="$OPT_SERVER"
  elif [ "$OPT_LIST_MODELS" -eq 1 ]; then err "$OPT_SERVER not reachable at $URL"; exit 3
  elif [ "$OPT_SKIP_LIVE" -eq 0 ]; then err "$OPT_SERVER not reachable at $URL (use --skip-live for static checks only)"; exit 3
  else SERVER_NOTE="$OPT_SERVER not reachable at $URL"; warn "$SERVER_NOTE"
  fi
else
  # Probe all three (refused connections return at once) so the menu can offer a choice.
  for s in ollama lmstudio llamacpp; do
    probe "$s" "$(default_url "$s")" && RESPONDING="$RESPONDING $s"
  done
  RESPONDING="${RESPONDING# }"
  SERVER="${RESPONDING%% *}"; [ -n "$SERVER" ] && URL="$(default_url "$SERVER")"
  if [ -z "$SERVER" ]; then
    SERVER_NOTE="no local server responded (Ollama :11434, LM Studio :1234, llama.cpp :8080)"
    [ "$OPT_LIST_MODELS" -eq 1 ] && { err "$SERVER_NOTE"; exit 3; }
    warn "$SERVER_NOTE"
  fi
fi

# Decide whether to prompt: -i, or automatically on a terminal when no model was given.
# Never prompt without a TTY (scripted use keeps the old defaults).
PROMPT=0
if [ "$OPT_LIST_MODELS" -eq 0 ] && [ -n "$SERVER" ]; then
  if [ "$OPT_INTERACTIVE" -eq 1 ] || [ -z "$OPT_MODEL" ]; then
    if is_tty; then PROMPT=1
    elif [ "$OPT_INTERACTIVE" -eq 1 ]; then warn "--interactive needs a terminal; using defaults"
    fi
  fi
fi

# Server choice when several respond and none was configured.
if [ "$PROMPT" -eq 1 ] && [ -z "$OPT_SERVER" ] && [ "$RESPONDING" != "$SERVER" ]; then
  : > "$TMPD/servers.txt"
  for s in $RESPONDING; do printf '%s  %s\n' "$s" "$(default_url "$s")" >> "$TMPD/servers.txt"; done
  pick="$(choose "Several local servers responded:" "$TMPD/servers.txt")" || exit 3   # choose runs in a subshell
  SERVER="${pick%% *}"; URL="$(default_url "$SERVER")"
fi

[ -n "$SERVER" ] && list_installed

# --list-models: print and exit 0.
if [ "$OPT_LIST_MODELS" -eq 1 ]; then
  printf '%s models at %s:\n' "$(server_label "$SERVER")" "$URL"
  if [ ! -s "$TMPD/models.tsv" ]; then printf '  (none)\n'; exit 0; fi
  while IFS="$(printf '\t')" read -r name size emb; do
    tag=""; [ "$emb" = "1" ] && tag="  [embedding, not selectable]"
    printf '  %-40s %9s%s\n' "$name" "$(human_size "$size")" "$tag"
  done < "$TMPD/models.tsv"
  exit 0
fi

MODEL=""; MODEL_NOTE=""
if [ -n "$OPT_MODEL" ] && [ -n "$SERVER" ]; then
  # Validate -m / config MODEL against the installed list (Ollama: ":latest" optional).
  MODEL="$(awk -F '\t' -v m="$OPT_MODEL" -v srv="$SERVER" '
    { n=$1; if (n==m) { print n; exit }
      if (srv=="ollama" && (n==m":latest" || n":latest"==m)) { print n; exit } }' "$TMPD/models.tsv")"
  if [ -z "$MODEL" ]; then
    err "model '$OPT_MODEL' ($MODEL_SOURCE) is not installed on $(server_label "$SERVER"). Installed models:"
    awk -F '\t' '{ printf "  %s%s\n", $1, ($3=="1" ? "  [embedding]" : "") }' "$TMPD/models.tsv" >&2
    exit 3
  fi
  if awk -F '\t' -v m="$MODEL" '$1==m && $3=="1" {f=1} END{exit !f}' "$TMPD/models.tsv"; then
    err "model '$MODEL' is an embedding model and cannot be chat-tested"; exit 3
  fi
elif [ -n "$OPT_MODEL" ]; then
  MODEL="$OPT_MODEL"   # server unreachable with --skip-live: cannot validate, used for C3 only
fi

if [ -z "$MODEL" ] && [ "$PROMPT" -eq 1 ]; then
  awk -F '\t' '$3!="1" { print $1 }' "$TMPD/models.tsv" > "$TMPD/menu.txt"
  if [ -s "$TMPD/menu.txt" ]; then
    : > "$TMPD/menu-labels.txt"
    while IFS= read -r name; do
      size="$(awk -F '\t' -v m="$name" '$1==m {print $2; exit}' "$TMPD/models.tsv")"
      printf '%-40s %9s\n' "$name" "$(human_size "$size")" >> "$TMPD/menu-labels.txt"
    done < "$TMPD/menu.txt"
    pick="$(choose "Installed models on $(server_label "$SERVER") (embedding models hidden):" "$TMPD/menu-labels.txt")" || exit 3
    MODEL="${pick%% *}"; MODEL_SOURCE="interactive"
  else
    warn "no chat models installed; falling back to defaults"
  fi
fi

# Default: first loaded model, else first installed non-embedding model.
if [ -z "$MODEL" ] && [ -n "$SERVER" ]; then
  if [ "$SERVER" = "ollama" ]; then
    MODEL="$(curl -fsS -m 5 "$URL/api/ps" 2>/dev/null | jq -r '.models[0].name // empty' 2>/dev/null)"
    [ -n "$MODEL" ] && MODEL_NOTE="first loaded model"
  fi
  if [ -z "$MODEL" ]; then
    MODEL="$(awk -F '\t' '$3!="1" { print $1; exit }' "$TMPD/models.tsv")"
    [ -n "$MODEL" ] && MODEL_NOTE="first installed model"
  fi
  [ -n "$MODEL" ] && MODEL_SOURCE="default"
fi

printf '  macOS %s, %s, %s\n' "$OS_VER" "$CHIP" "$MEM_GB"
printf '  Server: %s %s  Model: %s%s\n' "$(server_label "$SERVER")" "${URL:-}" "${MODEL:-none}" "${MODEL_SOURCE:+ (chosen by: $MODEL_SOURCE)}"
[ -n "$CONFIG_USED" ] && printf '  Config: %s\n' "$CONFIG_USED"

# Server log for C3 (spec 5 default locations).
LOG_FILE="$OPT_LOG"
if [ -z "$LOG_FILE" ]; then
  case "$SERVER" in
    ollama|"") [ -r "$HOME/.ollama/logs/server.log" ] && [ "$SERVER" = "ollama" ] && LOG_FILE="$HOME/.ollama/logs/server.log";;
    lmstudio) LOG_FILE="$(ls -t "$HOME"/.lmstudio/server-logs/* "$HOME"/.lmstudio/server-logs/*/* 2>/dev/null | head -n 1)";;
    llamacpp) warn "llama.cpp has no default log location; pass --log <file> (run llama-server with -v 4) for C3";;
  esac
fi
# Remember the log size now, so "during the session" means bytes written after start.
LOG_START=0; [ -n "$LOG_FILE" ] && [ -r "$LOG_FILE" ] && LOG_START="$(wc -c < "$LOG_FILE" | tr -d ' ')"

# ----------------------------------------------------------------------------
# C1: Claude Code attribution header
# ----------------------------------------------------------------------------
heading "Checklist"
ATTR="${CLAUDE_CODE_ATTRIBUTION_HEADER-}"
if ! command -v claude >/dev/null 2>&1; then
  record C1 "Claude Code attribution header" SKIP "Claude Code not installed"
elif [ "$ATTR" = "0" ]; then
  record C1 "Claude Code attribution header" PASS "CLAUDE_CODE_ATTRIBUTION_HEADER=0${CLAUDE_VER:+ (Claude Code $CLAUDE_VER)}"
elif [ -z "$CLAUDE_VER" ]; then
  record C1 "Claude Code attribution header" WARN "Version could not be parsed ('$CLAUDE_VER_RAW') and variable not 0"
elif version_ge "$CLAUDE_VER" "$MIN_CLAUDE"; then
  record C1 "Claude Code attribution header" PASS "Claude Code $CLAUDE_VER"
else
  record C1 "Claude Code attribution header" FAIL "Claude Code $CLAUDE_VER < $MIN_CLAUDE and variable ${ATTR:+is $ATTR}${ATTR:-not set}"
fi

# ----------------------------------------------------------------------------
# Live cache test (spec 4). Runs before C2 so a model is loaded for `ollama ps`.
# Per-turn values in indexed arrays (index 1..4).
# ----------------------------------------------------------------------------
L_TTFT=(); L_TOTAL=(); L_PROMPT=(); L_CACHED=(); L_SRC=(); L_THINK=()
LIVE_STATUS="skipped"; LIVE_NOTE=""; THINK_MODE=0; COUNTER_SRC=""
QUESTIONS=(""
  "Question A: In one sentence, what must the keeper do if they cannot oil the main bearing?"
  "Question B: In one sentence, which sections mention the lighthouse?"
  "Question C: In one sentence, how often must the alarm bell be tested?"
  "Question D: In one sentence, what is written in the ledger?")
PREFIX_TEXT="$(cat "$PREFIX_FILE")"
MSGS="$TMPD/msgs.json"   # running conversation (JSON array)

# Send the conversation in $MSGS; fill L_* for turn $1. Returns non-zero on error.
send_turn() {
  local t="$1" body="$TMPD/body$1.json" out="$TMPD/out$1.txt" times
  if [ "$SERVER" = "ollama" ]; then
    jq -n --arg m "$MODEL" --argjson msgs "$(cat "$MSGS")" --arg ka "$KEEP_ALIVE" \
          --argjson think "$THINK_MODE" --argjson n "$MAX_TOKENS" \
      '{model:$m, messages:$msgs, stream:true, keep_alive:$ka, options:{num_predict:$n}}
       + (if $think==1 then {think:true} else {} end)' > "$body"
    times="$(curl -sS -m "$REQ_TIMEOUT" -H 'Content-Type: application/json' -d @"$body" \
             -o "$out" -w '%{http_code} %{time_starttransfer} %{time_total}' "$URL/api/chat")" || { err "request $t failed (curl)"; return 1; }
    set -- $times
    if [ "$1" != "200" ] || ! jq -e 'select(.done==true)' "$out" >/dev/null 2>&1; then
      err "request $t: HTTP $1: $(jq -r '.error // empty' "$out" 2>/dev/null | head -n 1)"; return 1
    fi
    L_TTFT[$t]="$(r3 "$2")"; L_TOTAL[$t]="$(r3 "$3")"
    local fin; fin="$(jq -c 'select(.done==true)' "$out" | tail -n 1)"
    L_PROMPT[$t]="$(printf '%s' "$fin" | jq -r '.prompt_eval_count // empty')"
    # Ollama >= ~0.3x reports prompt_eval_cached_count directly; older builds report only
    # the evaluated (non-cached) tokens, so compare with request 1's full prompt length.
    local cc; cc="$(printf '%s' "$fin" | jq -r '.prompt_eval_cached_count // empty')"
    if [ -n "$cc" ]; then L_CACHED[$t]="$cc"; L_SRC[$t]="prompt_eval_cached_count"
    elif [ -n "${L_PROMPT[$t]}" ] && [ -n "${L_PROMPT[1]}" ] && [ "$t" -gt 1 ]; then
      local c=$(( ${L_PROMPT[1]} - ${L_PROMPT[$t]} )); [ $c -lt 0 ] && c=0
      L_CACHED[$t]="$c"; L_SRC[$t]="prompt_eval_count vs prompt length"
    else L_CACHED[$t]=""; L_SRC[$t]=""
    fi
    jq -js 'map(.message.content // "") | join("")' "$out" > "$TMPD/content$t.txt"
    jq -js 'map(.message.thinking // "") | join("")' "$out" > "$TMPD/thinking$t.txt"
  else
    # OpenAI-compatible (LM Studio / llama.cpp), streamed SSE with usage in the last chunk.
    jq -n --arg m "$MODEL" --argjson msgs "$(cat "$MSGS")" --argjson n "$MAX_TOKENS" \
      '{model:$m, messages:$msgs, stream:true, max_tokens:$n, cache_prompt:true,
        stream_options:{include_usage:true}}' > "$body"
    times="$(curl -sS -m "$REQ_TIMEOUT" -H 'Content-Type: application/json' -d @"$body" \
             -o "$out" -w '%{http_code} %{time_starttransfer} %{time_total}' "$URL/v1/chat/completions")" || { err "request $t failed (curl)"; return 1; }
    set -- $times
    sed -n 's/^data: *//p' "$out" | grep -v '^\[DONE\]' > "$out.jsonl"
    if [ "$1" != "200" ] || [ ! -s "$out.jsonl" ]; then err "request $t: HTTP $1: $(head -c 300 "$out")"; return 1; fi
    L_TTFT[$t]="$(r3 "$2")"; L_TOTAL[$t]="$(r3 "$3")"
    local v
    L_PROMPT[$t]="$(jq -rs '[.[] | .usage.prompt_tokens // empty] | last // empty' "$out.jsonl")"
    # Preference order (spec 4.5): usage.prompt_tokens_details.cached_tokens, then timings.cache_n.
    v="$(jq -rs '[.[] | .usage.prompt_tokens_details.cached_tokens // empty] | last // empty' "$out.jsonl")"
    if [ -n "$v" ]; then L_CACHED[$t]="$v"; L_SRC[$t]="usage.prompt_tokens_details.cached_tokens"
    else
      v="$(jq -rs '[.[] | .timings.cache_n // empty] | last // empty' "$out.jsonl")"
      if [ -n "$v" ]; then L_CACHED[$t]="$v"; L_SRC[$t]="timings.cache_n"
        [ -z "${L_PROMPT[$t]}" ] && L_PROMPT[$t]="$(jq -rs '[.[] | select(.timings) | (.timings.prompt_n + .timings.cache_n)] | last // empty' "$out.jsonl")"
      else L_CACHED[$t]=""; L_SRC[$t]=""
      fi
    fi
    jq -js 'map(.choices[0].delta.content // "") | join("")' "$out.jsonl" > "$TMPD/content$t.txt"
    jq -js 'map(.choices[0].delta.reasoning_content // .choices[0].delta.reasoning // "") | join("")' "$out.jsonl" > "$TMPD/thinking$t.txt"
  fi
  L_THINK[$t]="$(wc -c < "$TMPD/thinking$t.txt" | tr -d ' ')"
  return 0
}

# Append the assistant reply of turn $1 (with its reasoning, so it can be preserved) and a new user question.
extend_conversation() {
  local t="$1" q="$2" content thinking
  content="$(cat "$TMPD/content$t.txt")"; thinking="$(cat "$TMPD/thinking$t.txt")"
  local key="thinking"; [ "$SERVER" != "ollama" ] && key="reasoning_content"
  jq --arg c "$content" --arg th "$thinking" --arg k "$key" --arg q "$q" \
     '. + [ ({role:"assistant", content:$c} + (if $th != "" then {($k):$th} else {} end)), {role:"user", content:$q} ]' \
     "$MSGS" > "$MSGS.new" && mv "$MSGS.new" "$MSGS"
}

LIVE_START=""; LIVE_END=""
if [ "$OPT_SKIP_LIVE" -eq 1 ]; then
  LIVE_NOTE="--skip-live given"
elif [ -z "$SERVER" ]; then
  LIVE_NOTE="$SERVER_NOTE"
elif [ -z "$MODEL" ]; then
  LIVE_NOTE="no model available on the server (pass --model)"; warn "$LIVE_NOTE"
else
  heading "Live cache test ($MODEL)"
  # Enable thinking when the model advertises it (Ollama /api/show capabilities).
  if [ "$SERVER" = "ollama" ]; then
    jq -n --arg m "$MODEL" '{model:$m}' | curl -fsS -m 10 -d @- "$URL/api/show" -o "$TMPD/show.json" 2>/dev/null
    if ! jq -e . "$TMPD/show.json" >/dev/null 2>&1; then
      err "model '$MODEL' not found on Ollama"; exit 3
    fi
    jq -e '.capabilities // [] | index("thinking")' "$TMPD/show.json" >/dev/null 2>&1 && THINK_MODE=1
  fi
  [ "$THINK_MODE" -eq 1 ] && progress "model supports thinking; reasoning enabled for all turns"
  LIVE_STATUS="ok"; LIVE_START="$(date +%s)"
  jq -n --arg p "$PREFIX_TEXT" --arg q "${QUESTIONS[1]}" '[{role:"system",content:$p},{role:"user",content:$q}]' > "$MSGS"
  progress "request 1/4: prefix + question A (includes model load if not loaded)"
  if send_turn 1; then
    LIVE_START="$(date +%s)"   # spec 10.8: time limit excludes model load, so start after request 1
    jq -n --arg p "$PREFIX_TEXT" --arg q "${QUESTIONS[2]}" '[{role:"system",content:$p},{role:"user",content:$q}]' > "$MSGS"
    progress "request 2/4: same prefix + question B"
    if send_turn 2; then
      extend_conversation 2 "${QUESTIONS[3]}"; progress "turn 3/4: conversation + question C"
      if send_turn 3; then
        extend_conversation 3 "${QUESTIONS[4]}"; progress "turn 4/4: conversation + question D"
        send_turn 4 || LIVE_STATUS="error"
      else LIVE_STATUS="error"; fi
    else LIVE_STATUS="error"; fi
  else LIVE_STATUS="error"; fi
  LIVE_END="$(date +%s)"
  [ "$LIVE_STATUS" = "error" ] && LIVE_NOTE="a live request failed (see stderr)"
  COUNTER_SRC="${L_SRC[2]}"
  for t in 1 2 3 4; do
    [ -n "${L_TTFT[$t]}" ] && progress "turn $t: TTFT ${L_TTFT[$t]}s, total ${L_TOTAL[$t]}s, prompt $(fmtn "${L_PROMPT[$t]:-?}"), cached $(fmtn "${L_CACHED[$t]:-n/a}"), reasoning ${L_THINK[$t]:-0} chars"
  done
fi

# ----------------------------------------------------------------------------
# C2: Ollama context window (reads `ollama ps` CONTEXT column)
# ----------------------------------------------------------------------------
CTX=""; MODEL_MAX=""; C2_CAPPED=0
if [ "$SERVER" != "ollama" ]; then
  record C2 "Ollama context window" SKIP "Ollama not installed or not the selected server"
else
  if command -v ollama >/dev/null 2>&1; then
    # Columns: NAME ID SIZE PROCESSOR CONTEXT ...; find CONTEXT by header position.
    CTX="$(OLLAMA_HOST="$URL" ollama ps 2>/dev/null | awk -v m="$MODEL" '
      NR==1 { for (i=1;i<=NF;i++) if ($i=="CONTEXT") c=i; next }
      c && (m=="" || $1==m) { v=$0; n=split(v,f," "); # PROCESSOR can be "100% GPU" (2 fields)
        for (i=2;i<=n;i++) if (f[i] ~ /^[0-9]+$/ && f[i]+0 >= 512) { print f[i]; exit } }')"
  fi
  # Fallback to the API (context_length) if the CLI is unavailable or the format changed.
  [ -z "$CTX" ] && CTX="$(curl -fsS -m 5 "$URL/api/ps" 2>/dev/null | jq -r --arg m "$MODEL" '[.models[] | select($m=="" or .name==$m) | .context_length // empty][0] // empty' 2>/dev/null)"
  # Ollama caps the loaded context at the model's trained maximum, so OLLAMA_CONTEXT_LENGTH
  # cannot raise it beyond that. Read the maximum from /api/show model_info
  # ("<general.architecture>.context_length", else any "*.context_length"). Optional.
  if [ -n "$MODEL" ]; then
    MODEL_MAX="$(jq -n --arg m "$MODEL" '{model:$m}' | curl -fsS -m 10 -d @- "$URL/api/show" 2>/dev/null | jq -r '
      (.model_info // {}) as $i
      | ($i[(($i["general.architecture"] // "") + ".context_length")]
         // ([$i | to_entries[] | select(.key|endswith(".context_length")) | .value][0])) // empty' 2>/dev/null)"
    case "$MODEL_MAX" in *[!0-9]*) warn "unexpected model context length '$MODEL_MAX'; ignored"; MODEL_MAX="";; esac
    [ -z "$MODEL_MAX" ] && warn "could not read the trained context length of $MODEL from /api/show"
  fi
  max_txt=""; [ -n "$MODEL_MAX" ] && max_txt="; model maximum $(fmtn "$MODEL_MAX")"
  if [ -n "$CTX" ] && [ -n "$MODEL_MAX" ] && [ "$CTX" -lt 64000 ] && [ "$CTX" -ge "$MODEL_MAX" ]; then
    C2_CAPPED=1   # the setting cannot help; recommendation changes (same score thresholds)
    cdet="Context $(fmtn "$CTX") = model maximum $(fmtn "$MODEL_MAX"); setting cannot raise it"
  else
    cdet="Context $(fmtn "$CTX"), minimum 64,000$max_txt"
  fi
  if [ -z "$CTX" ]; then
    record C2 "Ollama context window" SKIP "No model loaded (run without --skip-live, or load a model)"
  elif [ "$CTX" -ge 64000 ]; then record C2 "Ollama context window" PASS "Context $(fmtn "$CTX")$max_txt"
  elif [ "$CTX" -ge 32000 ]; then record C2 "Ollama context window" WARN "$cdet"
  else record C2 "Ollama context window" FAIL "$cdet"
  fi
fi

# ----------------------------------------------------------------------------
# C3: Hybrid model and prompt reprocessing
# ----------------------------------------------------------------------------
HYBRID=0; HYBRID_PAT=""
if [ -n "$MODEL" ]; then
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$HYBRID_FILE" | grep -v '^$' > "$TMPD/patterns"
  while IFS= read -r pat; do
    if printf '%s\n' "$MODEL" | grep -qiE -- "$pat" 2>/dev/null; then HYBRID=1; HYBRID_PAT="$pat"; break; fi
  done < "$TMPD/patterns"
fi
REPRO_SESSION=0; REPRO_TOTAL=0
if [ -n "$LOG_FILE" ] && [ -r "$LOG_FILE" ]; then
  REPRO_TOTAL="$(grep -ci 'full prompt reprocessing' "$LOG_FILE" 2>/dev/null)"
  REPRO_SESSION="$(tail -c +$((LOG_START + 1)) "$LOG_FILE" 2>/dev/null | grep -ci 'full prompt reprocessing')"
  if [ "$REPRO_SESSION" -gt 0 ]; then
    record C3 "Hybrid model and prompt reprocessing" FAIL "Log shows full prompt reprocessing $REPRO_SESSION time(s) this session"
  elif [ "$HYBRID" -eq 1 ]; then
    record C3 "Hybrid model and prompt reprocessing" WARN "Hybrid model (matches '$HYBRID_PAT'), no reprocessing message yet"
  else
    record C3 "Hybrid model and prompt reprocessing" PASS "${MODEL:+Not hybrid; }no reprocessing message in log"
  fi
elif [ "$HYBRID" -eq 1 ]; then
  record C3 "Hybrid model and prompt reprocessing" WARN "Hybrid model (matches '$HYBRID_PAT'); server log not found"
else
  record C3 "Hybrid model and prompt reprocessing" SKIP "Server log not found and model not in hybrid list"
fi

# ----------------------------------------------------------------------------
# C4: Frontend cache tokens (request 2 cache counter, optional session log)
# ----------------------------------------------------------------------------
SESSION_HITS=""; SESSION_LINES=""
if [ -n "$OPT_SESSION_LOG" ]; then
  # Sum cache-hit counters commonly found in agent logs (Anthropic/Claude Code and OpenAI shapes).
  SESSION_HITS="$(grep -oE '"(cache_read_input_tokens|cached_tokens|cache_n)" *: *[0-9]+' "$OPT_SESSION_LOG" 2>/dev/null | grep -oE '[0-9]+$' | awk '{s+=$1} END{print s+0}')"
  SESSION_LINES="$(grep -cE '"(cache_read_input_tokens|cached_tokens|cache_n)"' "$OPT_SESSION_LOG" 2>/dev/null)"
fi
# Hybrid models restore only from saved checkpoints, so a prompt that diverges inside the
# cached region can show 0 cached tokens even with an identical prefix; say so in C4.
hybrid_hint() { if [ "$HYBRID" -eq 1 ]; then printf '; hybrid model, likely checkpoint limit (see C3)'; fi; }
session_suffix() { [ -n "$OPT_SESSION_LOG" ] && printf '; session log: %s cache-hit tokens in %s entries' "$(fmtn "$SESSION_HITS")" "$SESSION_LINES"; }
if [ "$LIVE_STATUS" = "skipped" ]; then
  record C4 "Frontend cache tokens" SKIP "Live test skipped${LIVE_NOTE:+ ($LIVE_NOTE)}"
elif [ -z "${L_TTFT[2]}" ]; then
  record C4 "Frontend cache tokens" ERROR "Request 2 did not complete"
elif [ -z "${L_CACHED[2]}" ]; then
  # No counter: infer from timing only (spec: WARN).
  ratio="$(awk -v a="${L_TTFT[1]}" -v b="${L_TTFT[2]}" 'BEGIN{ if (a>0) printf "%.0f", 100*b/a; else print "?" }')"
  record C4 "Frontend cache tokens" WARN "Server-side counter not reported; TTFT ${L_TTFT[2]}s vs ${L_TTFT[1]}s ($ratio%)$(session_suffix)"
else
  # Shared prefix = prompt tokens of request 2 (prefix dominates; the question is ~20 tokens).
  P2="${L_PROMPT[2]:-0}"; C2V="${L_CACHED[2]}"
  pct="$(awk -v c="$C2V" -v p="$P2" 'BEGIN{ if (p>0) printf "%.0f", 100*c/p; else print 0 }')"
  if [ "$C2V" -eq 0 ]; then
    record C4 "Frontend cache tokens" FAIL "Cached 0 of $(fmtn "$P2") prompt tokens on request 2 (identical prefix)$(hybrid_hint)$(session_suffix)"
  elif [ "$P2" -gt 0 ] && [ $(( C2V * 100 )) -ge $(( P2 * 80 )) ]; then
    if [ -n "$OPT_SESSION_LOG" ] && [ "${SESSION_LINES:-0}" -gt 0 ] && [ "${SESSION_HITS:-0}" -eq 0 ]; then
      record C4 "Frontend cache tokens" WARN "Server caches ($(fmtn "$C2V")/$(fmtn "$P2")) but the session log shows 0 cache-hit tokens"
    else
      record C4 "Frontend cache tokens" PASS "Cached $(fmtn "$C2V") of $(fmtn "$P2") prompt tokens ($pct%)$(session_suffix)"
    fi
  else
    record C4 "Frontend cache tokens" WARN "Cached $(fmtn "$C2V") of $(fmtn "$P2") prompt tokens ($pct%), below 80%$(hybrid_hint)$(session_suffix)"
  fi
fi

# ----------------------------------------------------------------------------
# C5: Thinking tokens preserved between turns (turns 2 -> 3 -> 4)
# ----------------------------------------------------------------------------
any_think=0; for t in 1 2 3 4; do [ "${L_THINK[$t]:-0}" -gt 0 ] && any_think=1; done
if [ "$LIVE_STATUS" = "skipped" ]; then
  record C5 "Thinking tokens preserved" SKIP "Live test skipped"
elif [ -z "${L_TTFT[4]}" ]; then
  record C5 "Thinking tokens preserved" ERROR "Turns 3-4 did not complete"
elif [ "$any_think" -eq 0 ]; then
  record C5 "Thinking tokens preserved" SKIP "Model produced no reasoning output"
elif [ -z "${L_CACHED[2]}" ] || [ -z "${L_CACHED[3]}" ] || [ -z "${L_CACHED[4]}" ]; then
  record C5 "Thinking tokens preserved" ERROR "Server did not report cache counters for turns 2-4"
else
  d3=0; d4=0
  [ "${L_CACHED[3]}" -lt "${L_CACHED[2]}" ] && d3=1
  [ "${L_CACHED[4]}" -lt "${L_CACHED[3]}" ] && d4=1
  seq="$(fmtn "${L_CACHED[2]}") -> $(fmtn "${L_CACHED[3]}") -> $(fmtn "${L_CACHED[4]}")"
  if [ $d3 -eq 1 ] && [ $d4 -eq 1 ]; then record C5 "Thinking tokens preserved" FAIL "Cache dropped on turns 3 and 4 ($seq)"
  elif [ $d3 -eq 1 ] || [ $d4 -eq 1 ]; then record C5 "Thinking tokens preserved" WARN "Cache dropped once ($seq)"
  else record C5 "Thinking tokens preserved" PASS "Cache grew on turns 2, 3, 4 ($seq)"
  fi
fi

# ----------------------------------------------------------------------------
# Score and exit code (spec 3.1, 8)
# ----------------------------------------------------------------------------
NP=0; NW=0; NF=0; NS=0; NE=0
for r in "${R_RES[@]}"; do case "$r" in PASS) NP=$((NP+1));; WARN) NW=$((NW+1));; FAIL) NF=$((NF+1));; SKIP) NS=$((NS+1));; ERROR) NE=$((NE+1));; esac; done
NSCORED=$((NP+NW+NF)); NEXCL=$((NS+NE))
if [ $NSCORED -gt 0 ]; then SCORE="$(awk -v p=$NP -v w=$NW -v n=$NSCORED 'BEGIN{ printf "%.0f", 100*(p+0.5*w)/n }')"; SCORE_TXT="$SCORE%"; else SCORE=""; SCORE_TXT="n/a"; fi
if [ $NF -gt 0 ]; then EXIT=2; elif [ $NW -gt 0 ]; then EXIT=1; else EXIT=0; fi
if [ -z "$SCORE" ]; then SC=""; elif [ "$SCORE" -ge 80 ]; then SC="$C_G"; elif [ "$SCORE" -ge 50 ]; then SC="$C_Y"; else SC="$C_R"; fi

# ----------------------------------------------------------------------------
# Recommendations text (spec 7.3): found / why / fix on macOS / verify
# ----------------------------------------------------------------------------
recommendation() {  # id detail
  case "$1" in
  C1) cat <<R
**Found:** $2

**Why it matters:** older Claude Code versions send an attribution header that changes the start of every request, so the server can never reuse its prompt cache.

**Fix on macOS:**
- Run \`claude update\`, or reinstall using the official installer, then open a new Terminal window.
- If an update is not possible, run \`echo 'export CLAUDE_CODE_ATTRIBUTION_HEADER=0' >> ~/.zshrc\`, then open a new Terminal window.
- If Claude Code is started from an app or launcher rather than Terminal, run \`launchctl setenv CLAUDE_CODE_ATTRIBUTION_HEADER 0\`, then restart the app.
R
  ;;
  C2) cat <<R
**Found:** $2

**Why it matters:** an agent's first request (about 33,000 tokens for Claude Code) does not fit in a small context window, so Ollama truncates the prompt and the cached prefix no longer matches.

**Fix on macOS:**
R
    if [ "$C2_CAPPED" -eq 1 ]; then cat <<R
- This model was trained with a maximum context of $(fmtn "$MODEL_MAX") tokens, and Ollama never loads it with more. Raising \`OLLAMA_CONTEXT_LENGTH\` will not change it.
- Use a model with a larger trained context window (64,000 tokens or more) for agent sessions. Check a model's limit with \`ollama show <model>\` (the "context length" line) before pulling or choosing it.
- Re-run the tool with that model (\`-m <model>\` or the interactive menu) and confirm C2 shows PASS.
R
    else cat <<R
- Run \`ollama ps\` and note the CONTEXT column.${MODEL_MAX:+ This model supports up to $(fmtn "$MODEL_MAX") tokens (\`ollama show $MODEL\`).}
- Set the context length to at least 64000. Run \`launchctl setenv OLLAMA_CONTEXT_LENGTH 65536\`, then quit Ollama from the menu bar and reopen it. For \`ollama serve\` started from Terminal, use \`OLLAMA_CONTEXT_LENGTH=65536 ollama serve\` instead.
- Run \`ollama ps\` again to confirm the new value. Ollama must reload the model before the change applies.
- Higher context uses more unified memory. On a 48 GB Mac, check Activity Monitor for memory pressure after the change.
R
    fi
  ;;
  C3) cat <<R
**Found:** $2

**Why it matters:** hybrid (SSM / recurrent) models cannot rewind their state past a checkpoint, so when the prompt changes the server may re-read the whole prompt from scratch ("full prompt reprocessing").

**Fix on macOS:**
- Open \`~/.ollama/logs/server.log\` (or the LM Studio log in \`~/.lmstudio/server-logs/\`, or your llama.cpp log) and search for \`full prompt reprocessing\`. Use \`grep -i "full prompt reprocessing" <log>\`.
- For llama.cpp, restart \`llama-server\` with \`-v 4\` (or \`--verbosity 4\`) to see the cache-related log lines.
- If the model is hybrid and reprocessing appears every turn, switch to a non-hybrid model for agent sessions, or accept the cold-read cost and keep sessions short.
R
  ;;
  C4) cat <<R
**Found:** $2

**Why it matters:** if the cached-token count stays near zero while the prefix is identical, every turn re-reads the whole prompt and time to first token grows with the conversation.

**Fix on macOS:**
- Confirm the server reports cache counters. If it does not, update the server (for Ollama, download the latest version from ollama.com or run \`brew upgrade ollama\` if you installed it with Homebrew).
- Test the frontend itself: run a short agent session, then check the cache-token counter the server logs (for Ollama, \`~/.ollama/logs/server.log\`). Zero cached tokens deep into a session means the frontend is changing the prompt prefix between turns.
- Try another frontend that caches correctly, and compare the cache counter for the same task.
R
  ;;
  C5) cat <<R
**Found:** $2

**Why it matters:** when reasoning output is removed from the history between turns, the conversation no longer matches what the server cached, so cached tokens fall and the prompt is re-read.

**Fix on macOS:**
- Find the setting in your frontend that controls whether reasoning output is kept in conversation history. Turn on preserved or kept thinking.
- If the frontend has no such setting, report the issue to its maintainer and consider a frontend that preserves thinking.
- Re-run the tool and confirm that cached tokens grow on each turn.
R
  ;;
  esac
  printf '\n**Verify:** re-run `%s` and confirm this item shows PASS.\n' "$(basename "$0")"
}

# ----------------------------------------------------------------------------
# HTML copy of the report: a small markdown-to-HTML converter (awk only) that
# covers exactly what the report uses: headings, paragraphs, bold, inline code,
# fenced code blocks, bullet lists, tables and links. Content is HTML-escaped
# first. Result cells PASS/WARN/FAIL/SKIP/ERROR become coloured badges.
# Usage: md_to_html <in.md> <out.html>; non-zero on failure.
# ----------------------------------------------------------------------------
md_to_html() {
  local in="$1" out="$2" title
  title="$(head -n 1 "$in" | sed -e 's/^# *//' -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  {
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
body { font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; color: #1d1d1f; background: #fafafa; max-width: 980px; margin: 2em auto; padding: 0 1.2em; }
h1 { font-size: 1.8em; border-bottom: 2px solid #ddd; padding-bottom: .3em; }
h2 { font-size: 1.35em; margin-top: 1.8em; border-bottom: 1px solid #e5e5e5; padding-bottom: .2em; }
h3 { font-size: 1.1em; margin-top: 1.4em; }
code { font: .9em ui-monospace, Menlo, monospace; background: #eee; padding: .1em .35em; border-radius: 4px; }
pre { background: #f0f0f0; padding: .8em 1em; border-radius: 6px; overflow-x: auto; }
pre code { background: none; padding: 0; }
table { border-collapse: collapse; margin: 1em 0; width: 100%; background: #fff; }
th, td { border: 1px solid #ddd; padding: .45em .7em; text-align: left; vertical-align: top; }
th { background: #f2f2f2; }
tr:nth-child(even) td { background: #fbfbfb; }
.badge { display: inline-block; min-width: 3.6em; text-align: center; font-weight: 600; font-size: .85em; padding: .15em .5em; border-radius: 999px; color: #fff; }
.pass { background: #1e8e3e; } .warn { background: #e8a10c; } .fail { background: #d93025; }
.skip { background: #8a8a8a; } .error { background: #a50e0e; }
a { color: #0b57d0; }
</style>
</head>
<body>
HTML
    awk '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    # bold and links on text that contains no inline code
    function fmt(s,   pre, mid, post, t, u, p) {
      while (match(s, /\*\*[^*]+\*\*/)) {
        pre = substr(s, 1, RSTART - 1); mid = substr(s, RSTART + 2, RLENGTH - 4); post = substr(s, RSTART + RLENGTH)
        s = pre "<strong>" mid "</strong>" post
      }
      while (match(s, /\[[^]]*\]\([^) ]*\)/)) {
        pre = substr(s, 1, RSTART - 1); mid = substr(s, RSTART, RLENGTH); post = substr(s, RSTART + RLENGTH)
        p = index(mid, "](")
        t = substr(mid, 2, p - 2); u = substr(mid, p + 2, length(mid) - p - 2)
        s = pre "<a href=\"" u "\">" t "</a>" post
      }
      return s
    }
    # inline formatting: split on backticks; odd segments are code
    function inl(s,   n, parts, i, r) {
      n = split(s, parts, "`"); r = ""
      if (n % 2 == 0) return fmt(s)          # unbalanced backticks: no code spans
      for (i = 1; i <= n; i++) r = r ((i % 2 == 0) ? "<code>" parts[i] "</code>" : fmt(parts[i]))
      return r
    }
    function badge(c,   t) {
      t = c; gsub(/^ +| +$/, "", t)
      if (t ~ /^(PASS|WARN|FAIL|SKIP|ERROR)$/) return "<span class=\"badge " tolower(t) "\">" t "</span>"
      return inl(c)
    }
    function close_blocks() {
      if (para != "") { print "<p>" inl(para) "</p>"; para = "" }
      if (inlist) { print "</ul>"; inlist = 0 }
      if (intable) { print "</tbody></table>"; intable = 0 }
    }
    function cells(line, tag,   n, a, i, r, c) {
      gsub(/\\\|/, "\001", line)             # escaped pipes inside cells
      sub(/^ *\|/, "", line); sub(/\| *$/, "", line)
      n = split(line, a, "|"); r = "<tr>"
      for (i = 1; i <= n; i++) {
        c = a[i]; gsub(/^ +| +$/, "", c); gsub(/\001/, "|", c)
        r = r "<" tag ">" (tag == "td" ? badge(c) : inl(c)) "</" tag ">"
      }
      return r "</tr>"
    }
    NR == 1 { next }                         # title is emitted as <h1> below
    {
      raw = $0
      if (incode) { if (raw ~ /^```/) { print "</code></pre>"; incode = 0 } else print esc(raw); next }
      if (raw ~ /^```/) { close_blocks(); print "<pre><code>"; incode = 1; next }
      line = esc(raw)
      if (line ~ /^#+ /) {
        close_blocks(); match(line, /^#+/); lvl = RLENGTH; t = substr(line, lvl + 2)
        print "<h" lvl ">" inl(t) "</h" lvl ">"; next
      }
      if (line ~ /^ *\|/) {
        if (!intable) { close_blocks(); print "<table><thead>" cells(line, "th") "</thead><tbody>"; intable = 1; hdr = 1; next }
        if (hdr && line ~ /^ *\|[-| :]+\| *$/) { hdr = 0; next }
        hdr = 0; print cells(line, "td"); next
      }
      if (line ~ /^- /) {
        if (para != "") { print "<p>" inl(para) "</p>"; para = "" }
        if (intable) { print "</tbody></table>"; intable = 0 }
        if (!inlist) { print "<ul>"; inlist = 1 }
        print "<li>" inl(substr(line, 3)) "</li>"; next
      }
      if (line ~ /^[ \t]*$/) { close_blocks(); next }
      if (inlist || intable) close_blocks()
      para = (para == "") ? line : para " " line
    }
    END { close_blocks(); if (incode) print "</code></pre>" }
    ' "$in" | { printf '<h1>%s</h1>\n' "$title"; cat; }
    printf '</body>\n</html>\n'
  } > "$out"
}

# ----------------------------------------------------------------------------
# Markdown report (spec 7)
# ----------------------------------------------------------------------------
md_escape() { printf '%s' "$1" | sed 's/|/\\|/g'; }
{
  printf '# Local LLM Checkup (macOS)\n\nGenerated %s by local-llm-checkup.sh %s\n\n' "$START_HUMAN" "$VERSION"
  printf '## Environment\n\n'
  printf -- '- macOS: %s (%s)\n- Chip: %s\n- Memory: %s\n' "$OS_VER" "$ARCH" "$CHIP" "$MEM_GB"
  printf -- '- Ollama: %s\n- LM Studio: %s\n- llama.cpp: %s\n' "${OLLAMA_VER:-not found}" "${LMS_VER:-not found}" "${LLAMA_VER:-not found}"
  printf -- '- Claude Code: %s\n' "${CLAUDE_VER:-not found}"
  printf -- '- Selected server: %s\n- Endpoint: %s\n- Model: %s%s\n' "$(server_label "$SERVER")" "${URL:-n/a}" "${MODEL:-n/a}" "${MODEL_NOTE:+ ($MODEL_NOTE)}"
  printf -- '- Model trained context (max): %s\n' "$( [ -n "$MODEL_MAX" ] && fmtn "$MODEL_MAX" || echo 'n/a')"
  printf -- '- Model chosen by: %s\n- Config file: %s\n' "${MODEL_SOURCE:-n/a}" "${CONFIG_USED:-none}"
  printf -- '- Server log: %s\n\n' "${LOG_FILE:-not found}"
  printf '## Summary\n\n**Overall score: %s** (%d items scored, %d excluded)\n\n' "$SCORE_TXT" "$NSCORED" "$NEXCL"
  printf '| PASS | WARN | FAIL | SKIP | ERROR |\n|------|------|------|------|-------|\n| %d | %d | %d | %d | %d |\n\n' $NP $NW $NF $NS $NE
  printf '## Results\n\n| ID | Item | Result | Score | Detail |\n|----|------|--------|-------|--------|\n'
  i=0; while [ $i -lt ${#R_ID[@]} ]; do
    printf '| %s | %s | %s | %s | %s |\n' "${R_ID[$i]}" "${R_NAME[$i]}" "${R_RES[$i]}" "${R_SCORE[$i]}" "$(md_escape "${R_DETAIL[$i]}")"; i=$((i+1))
  done
  printf '| | **Overall** | | **%s** | %d items scored, %d skipped%s |\n\n' "$SCORE_TXT" "$NSCORED" "$NS" "$( [ $NE -gt 0 ] && printf ', %d errored' $NE)"
  printf '## Live test details\n\n'
  if [ "$LIVE_STATUS" = "skipped" ]; then
    printf 'Live test skipped: %s.\n\n' "${LIVE_NOTE:-n/a}"
  else
    printf 'Prefix: `prefix.txt` (%s bytes, identical on every run). max_tokens: %d. Reasoning: %s. Cache counter: %s.\n\n' \
      "$(wc -c < "$PREFIX_FILE" | tr -d ' ')" "$MAX_TOKENS" "$( [ $THINK_MODE -eq 1 ] && echo enabled || echo 'not requested (model has no thinking capability or server is OpenAI-compatible)')" "${COUNTER_SRC:-server-side counter not reported}"
    printf '| Turn | Request | TTFT (s) | Total (s) | Prompt tokens | Cached tokens | Reasoning chars |\n|------|---------|----------|-----------|---------------|---------------|-----------------|\n'
    for t in 1 2 3 4; do
      case $t in 1) d="prefix + question A";; 2) d="prefix + question B";; 3) d="turn 2 + answer + question C";; 4) d="turn 3 + answer + question D";; esac
      printf '| %d | %s | %s | %s | %s | %s | %s |\n' $t "$d" "${L_TTFT[$t]:--}" "${L_TOTAL[$t]:--}" "$(fmtn "${L_PROMPT[$t]:--}")" "$(fmtn "${L_CACHED[$t]:--}")" "${L_THINK[$t]:--}"
    done
    [ -n "$LIVE_START" ] && [ -n "$LIVE_END" ] && printf '\nTurns 2-4 took %ss (after model load and request 1).\n' "$((LIVE_END - LIVE_START))"
    [ -n "$CTX" ] && printf '\nLoaded context (ollama ps): %s; model trained maximum: %s.\n' "$(fmtn "$CTX")" "$( [ -n "$MODEL_MAX" ] && fmtn "$MODEL_MAX" || echo 'n/a')"
    [ -n "$LIVE_NOTE" ] && printf '\nNote: %s.\n' "$LIVE_NOTE"
    printf '\n'
  fi
  printf '## Recommendations\n\n'
  any=0; i=0; while [ $i -lt ${#R_ID[@]} ]; do
    case "${R_RES[$i]}" in
      PASS) ;;
      SKIP) any=1; printf '### %s %s (SKIP)\n\n**Found:** %s\n\nNot applicable on this system; no action needed unless you expected this check to run.\n\n' "${R_ID[$i]}" "${R_NAME[$i]}" "${R_DETAIL[$i]}";;
      *) any=1; printf '### %s %s (%s)\n\n' "${R_ID[$i]}" "${R_NAME[$i]}" "${R_RES[$i]}"; recommendation "${R_ID[$i]}" "${R_DETAIL[$i]}"; printf '\n';;
    esac; i=$((i+1))
  done
  [ $any -eq 0 ] && printf 'All items passed. No action needed.\n\n'
  printf '## Notes and limitations\n\n'
  printf -- '- This tool only reads configuration and sends test requests; it changes no settings, environment variables or files outside the report directory.\n'
  printf -- '- Pass/fail decisions use server cache counters, not timing. Timings are for information and vary with load.\n'
  printf -- '- "Prompt tokens" on request 2 is used as the shared prefix size; the differing question adds roughly 20 tokens.\n'
  printf -- '- C3 counts `full prompt reprocessing` only in log lines written during this run (%s occurrence(s) in the whole log). Ollama and LM Studio may not log this phrase; llama.cpp logs it at verbosity 4.\n' "$REPRO_TOTAL"
  printf -- '- The hybrid model list (`hybrid-models.txt`) is pattern based and may not cover new or renamed models.\n'
  printf -- '- The live test leaves the model loaded (Ollama keep_alive %s) so the cache persists between requests.\n' "$KEEP_ALIVE"
  if [ -n "$SERVER_NOTE" ]; then printf -- '- %s.\n' "$SERVER_NOTE"; fi
  true   # the group's status must not depend on the last optional line
} > "$REPORT" || { err "could not write report: $REPORT"; exit 3; }

# HTML copy with the same basename. A failure here is logged and never changes
# the markdown report or the exit code.
REPORT_HTML="${REPORT%.md}.html"
if ! md_to_html "$REPORT" "$REPORT_HTML" 2>"$TMPD/html.err"; then
  err "could not write HTML report $REPORT_HTML: $(head -n 3 "$TMPD/html.err" | tr '\n' ' ')"
  rm -f "$REPORT_HTML" 2>/dev/null; REPORT_HTML=""
fi

# ----------------------------------------------------------------------------
# Final summary
# ----------------------------------------------------------------------------
heading "Summary"
printf '  Overall score: %s%s%s%s  (PASS %d, WARN %d, FAIL %d, SKIP %d, ERROR %d)\n' "$C_B" "$SC" "$SCORE_TXT" "$C_0" $NP $NW $NF $NS $NE
printf '  Report: %s\n' "$REPORT"
[ -n "$REPORT_HTML" ] && printf '  HTML:   %s\n' "$REPORT_HTML"
exit $EXIT
