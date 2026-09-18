#!/usr/bin/env bash
# fanout.sh — Multi-agent task fan-out coordinator for herdr.
#
# Drives arbitrary agent panes through herdr's raw-pane primitives, enabling
# a lead agent (or human) to dispatch concurrent subtasks and collect results.
# Agent definitions are read from a config file so the script is not tied to
# any specific agent names.
#
# Usage:
#   fanout.sh agents                              # list agents from config + herdr
#   fanout.sh status [AGENT]                      # agent state + pane info
#   fanout.sh read <pane> [LINES]                 # tail a pane's recent output
#   fanout.sh send <pane> "<text>"                # send text + press Enter
#   fanout.sh pane-of <agent>                     # resolve agent name → pane id
#   fanout.sh fanout -a AGENT -t "task" [-a AGENT -t "task"] ... [-m MARKER] [-r RETRIES]
#   fanout.sh worktree                            # list herdr worktrees
#
# Config: ~/.config/fanout/agents.conf (or $FANOUT_CONFIG)
#   Format (one agent per line):
#     agent_name = pane_id
#   Example:
#     goose = w1:p1J
#     crush = w1:p1K
#
# Dependencies: bash 4+, herdr, python3 (for JSON parsing), awk, grep.

set -euo pipefail
HERDR_BIN="${HERDR_BIN:-herdr}"
CONFIG="${FANOUT_CONFIG:-$HOME/.config/fanout/agents.conf}"

# ---------------------------------------------------------------------------
# Config & agent resolution
# ---------------------------------------------------------------------------

# Load agent definitions from config file into associative arrays.
declare -A AGENT_PANE
load_config() {
  [[ -f "$CONFIG" ]] || { echo "config not found: $CONFIG" >&2; return 1; }
  while IFS= read -r line; do
    line="${line%%#*}"          # strip comments
    line="${line// /}"          # strip spaces
    [[ -z "$line" ]] && continue
    local name="${line%%=*}"
    local pane="${line#*=}"
    [[ -n "$name" && -n "$pane" ]] && AGENT_PANE["$name"]="$pane"
  done < "$CONFIG"
}

# Resolve agent name → pane id. Checks config first, falls back to herdr agent list.
resolve_pane() {
  local name="$1"
  if [[ -n "${AGENT_PANE[$name]:-}" ]]; then
    echo "${AGENT_PANE[$name]}"
    return 0
  fi
  # Fallback: query herdr
  local out
  out="$("$HERDR_BIN" agent list 2>/dev/null)" || return 1
  python3 -c "
import json,sys
name=sys.argv[1]
try:
    d=json.load(sys.stdin)['result']['agents']
except: sys.exit(1)
for a in d:
    n=a.get('agent') or a.get('agent_name','')
    if n==name:
        print(a['pane_id']); sys.exit(0)
sys.exit(1)" "$name" <<<"$out" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Low-level herdr wrappers
# ---------------------------------------------------------------------------

agents_list() {
  "$HERDR_BIN" agent list 2>/dev/null
}

agent_status() {
  local name="$1"
  "$HERDR_BIN" agent list 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)['result']['agents']
except: sys.exit(0)
for a in d:
    n=a.get('agent') or a.get('agent_name','')
    if n==sys.argv[1]:
        print(a.get('agent_status','unknown')); sys.exit(0)
" "$name" 2>/dev/null || true
}

agent_seq() {
  local name="$1"
  "$HERDR_BIN" agent list 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)['result']['agents']
except: print(0); sys.exit(0)
for a in d:
    n=a.get('agent') or a.get('agent_name','')
    if n==sys.argv[1]:
        print(a.get('state_change_seq',0)); sys.exit(0)
print(0)" "$name" 2>/dev/null || echo "0"
}

read_pane() {
  local pane="$1"; local lines="${2:-15}"
  "$HERDR_BIN" pane read "$pane" --source recent --lines "$lines" 2>/dev/null \
    || "$HERDR_BIN" agent read "$pane" --lines "$lines" 2>/dev/null
}

send_text() {
  local pane="$1"; local text="$2"
  "$HERDR_BIN" pane send-text "$pane" "$text" 2>/dev/null
  sleep 0.3
  "$HERDR_BIN" pane send-keys "$pane" Enter 2>/dev/null
}

grab_marker() {
  local pane="$1"; local tok="${2:-}"; local lines="${3:-250}"
  [[ -n "$tok" ]] || return 1
  read_pane "$pane" "$lines" | grep -F "$tok" | tail -1
}

# ---------------------------------------------------------------------------
# Error detection
# ---------------------------------------------------------------------------

# Check if a pane's CURRENT run output contains provider/API errors.
# Only searches lines after the last marker occurrence to avoid false positives
# from stale errors in scrollback. Returns 0 if errors found, 1 if clean.
pane_has_error() {
  local pane="$1"; local tok="${2:-}"
  local out after
  out="$(read_pane "$pane" 60 2>/dev/null)" || return 1
  if [[ -n "$tok" ]]; then
    after="$(echo "$out" | awk -v tok="$tok" 'found{print} /tok/{found=1}' | tail -10)"
  else
    after="$(echo "$out" | tail -10)"
  fi
  [[ -z "$after" ]] && return 1
  echo "$after" | grep -qiE 'Provider returned error|Error:|failed|rate.limit|503|502|429|timeout' && return 0
  return 1
}

# ---------------------------------------------------------------------------
# Fan-out: parallel dispatch + completion detection
# ---------------------------------------------------------------------------

# fanout -a <agent> -t <task> [-a <agent> -t <task>...] [-m MARKER] [-r RETRIES] [-p POLLS] [-d DELAY]
#
# Sends each agent its task concurrently, waits for all to complete via
# state_change_seq tracking (catches fast completions that finish before
# the first poll), checks for provider errors, and retries failed agents.
#
# Agent pairs are positional: tasks are dispatched in the order given.
# For a simple 2-agent fan-out:
#   fanout -a goose -t "task A" -a crush -t "task B"
#
cmd_fanout() {
  local -a agent_names=() agent_tasks=()
  local marker="FANOUT" max_retries=5 polls=30 delay=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--agent)   agent_names+=("$2"); shift 2 ;;
      -t|--task)    agent_tasks+=("$2"); shift 2 ;;
      -m|--marker)  marker="$2"; shift 2 ;;
      -r|--retries) max_retries="$2"; shift 2 ;;
      -p|--polls)   polls="$2"; shift 2 ;;
      -d|--delay)   delay="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; return 1 ;;
    esac
  done

  [[ ${#agent_names[@]} -gt 0 ]] || { echo "no agents specified (use -a NAME -t TASK)" >&2; return 1; }
  [[ ${#agent_names[@]} -eq ${#agent_tasks[@]} ]] || { echo "agent/task count mismatch" >&2; return 1; }

  local run_tok
  run_tok="$marker.$(date +%s).$RANDOM"
  local -A pane_of
  local -a pre_seqs=()

  # Resolve panes + capture pre-send seq
  local display=""
  for name in "${agent_names[@]}"; do
    local pane
    pane="$(resolve_pane "$name")" || { echo "could not resolve pane for $name" >&2; return 1; }
    pane_of["$name"]="$pane"
    pre_seqs+=("$(agent_seq "$name")")
    display="${display:+$display  }$name=$pane"
  done

  echo "fanout: $display (marker=$run_tok)"

  # Dispatch all tasks concurrently
  local i=0
  for name in "${agent_names[@]}"; do
    send_text "${pane_of[$name]}" "$(printf '%s\nEnd with the token %s on its own final line.' "${agent_tasks[$i]}" "$run_tok")" &
    i=$((i + 1))
  done
  wait

  # Wait for all agents to complete (parallel polling)
  local -A finished=()
  for name in "${agent_names[@]}"; do finished["$name"]=0; done

  for ((p=1; p<=polls; p++)); do
    local all_done=1
    for name in "${agent_names[@]}"; do
      [[ "${finished[$name]}" == 1 ]] && continue
      all_done=0
      local st
      st="$(agent_status "$name")"
      case "$st" in
        done|idle) finished["$name"]=1; echo "[ok] $name finished" ;;
      esac
    done
    [[ "$all_done" == 1 ]] && break
    sleep "$delay"
  done

  # Seq-based fallback: detect agents that completed between dispatch and first poll
  local idx=0
  for name in "${agent_names[@]}"; do
    if [[ "${finished[$name]}" == 0 ]]; then
      local cur_seq
      cur_seq="$(agent_seq "$name")"
      if (( cur_seq > ${pre_seqs[$idx]} )); then
        finished["$name"]=1
        echo "[ok] $name finished (seq)"
      fi
    fi
    idx=$((idx + 1))
  done

  # Retry loop: if an agent hit a provider/API error, re-send its task
  local -A errored=()
  for name in "${agent_names[@]}"; do
    pane_has_error "${pane_of[$name]}" "$run_tok" && errored["$name"]=1
  done

  local attempt=0
  local has_errors=0
  for name in "${agent_names[@]}"; do [[ "${errored[$name]:-0}" == 1 ]] && has_errors=1; done

  while [[ "$has_errors" == 1 ]] && (( attempt < max_retries )); do
    attempt=$((attempt + 1))
    # Re-dispatch only errored agents
    local ri=0
    for name in "${agent_names[@]}"; do
      if [[ "${errored[$name]:-0}" == 1 ]]; then
        echo "[retry $attempt/$max_retries] $name — re-sending task"
        pre_seqs[$ri]="$(agent_seq "$name")"
        send_text "${pane_of[$name]}" "$(printf '%s\nEnd with the token %s on its own final line.' "${agent_tasks[$ri]}" "$run_tok")" &
      fi
      ri=$((ri + 1))
    done
    wait

    # Wait only for errored agents
    for ((p=1; p<=polls; p++)); do
      local retry_all_done=1
      for name in "${agent_names[@]}"; do
        [[ "${errored[$name]:-0}" == 0 ]] && continue
        local st
        st="$(agent_status "$name")"
        case "$st" in
          done|idle) errored["$name"]=0 ;;
          *) retry_all_done=0 ;;
        esac
      done
      [[ "$retry_all_done" == 1 ]] && break
      sleep "$delay"
    done

    # Re-check errors
    has_errors=0
    for name in "${agent_names[@]}"; do
      if [[ "${errored[$name]:-0}" == 1 ]]; then
        pane_has_error "${pane_of[$name]}" "$run_tok" && has_errors=1
      fi
    done
  done

  if (( attempt >= max_retries )) && [[ "$has_errors" == 1 ]]; then
    echo "[gave up] agent error persisted after $max_retries retries"
  fi

  # Print merged results
  echo "--- results ---"
  for name in "${agent_names[@]}"; do
    local marker_line
    marker_line="$(grab_marker "${pane_of[$name]}" "$run_tok" 250 2>/dev/null || echo '')"
    if [[ -n "$marker_line" ]]; then
      echo "[$name] $marker_line"
    else
      echo "[$name] <no output>"
    fi
  done
}

# ---------------------------------------------------------------------------
# Worktree helper
# ---------------------------------------------------------------------------

cmd_worktree() {
  printf 'worktrees (create via herdr prefix+shift+g):\n'
  "$HERDR_BIN" worktree list 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Status command
# ---------------------------------------------------------------------------

cmd_status() {
  local pane="${1:-}"
  if [[ -n "$pane" ]]; then
    "$HERDR_BIN" agent get "$pane" 2>/dev/null || "$HERDR_BIN" pane get "$pane" 2>/dev/null
  else
    agents_list
  fi
}

# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------

cmd="${1:-help}"
shift || true

case "$cmd" in
  agents)   load_config; agents_list ;;
  status)   load_config; cmd_status "${1:-}" ;;
  read)     read_pane "${1:?pane}" "${2:-15}" ;;
  send)     send_text "${1:?pane}" "${2:?text}" ;;
  pane-of)  load_config; resolve_pane "${1:?agent}" ;;
  fanout)   load_config; cmd_fanout "$@" ;;
  worktree) cmd_worktree ;;
  help|-h|--help)
    cat <<'EOF'
fanout.sh — Multi-agent task fan-out coordinator for herdr.

COMMANDS:
  agents                              List all agents (config + herdr)
  status [AGENT]                     Agent state + pane info
  read <pane> [LINES]                Tail a pane's recent output
  send <pane> "<text>"               Send text + Enter to a pane
  pane-of <agent>                    Resolve agent name → pane id
  fanout -a AGENT -t TASK [...]      Dispatch concurrent tasks, wait, collect
  worktree                           List herdr worktrees

FANOUT OPTIONS:
  -a, --agent NAME    Agent name (repeat for each agent)
  -t, --task TEXT     Task text (repeat, matched by position to agents)
  -m, --marker TEXT   Completion marker prefix (default: FANOUT)
  -r, --retries N     Max retries on provider error (default: 5)
  -p, --polls N       Max polls for completion detection (default: 30)
  -d, --delay SECS    Seconds between polls (default: 1)

CONFIG:
  ~/.config/fanout/agents.conf (or $FANOUT_CONFIG)
  Format: agent_name = pane_id (one per line)

EXAMPLE:
  fanout.sh fanout -a goose -t "What is 2+2?" -a crush -t "Capital of France?"
EOF
    ;;
  *) echo "unknown command: $cmd (try 'fanout.sh help')" >&2; exit 2 ;;
esac
