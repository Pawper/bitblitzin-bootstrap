#!/bin/sh
# Sourced by each refusing hook. When the hook exits 2 (a refusal), one
# line goes to .scratch/hooks.log in the project: the time and the hook's
# name, nothing of the command. The owner console's Delivery section counts
# them, to show which rules refuse most. The file stays in the project's
# ignored scratch folder on this machine; HOOK_LOG=0 turns it off.
refusal_log_file() {
  rl_dir=${CLAUDE_PROJECT_DIR:-.}
  [ -d "$rl_dir/.git" ] || [ -f "$rl_dir/.git" ] || return 1
  printf '%s/.scratch/hooks.log\n' "$rl_dir"
}
refusal_log() {
  [ "${HOOK_LOG:-1}" != 0 ] || return 0
  rl_f=$(refusal_log_file) || return 0
  mkdir -p "$(dirname "$rl_f")" 2>/dev/null || return 0
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0" .sh)" >> "$rl_f" 2>/dev/null || true
}
trap 'rl_rc=$?; [ "$rl_rc" -eq 2 ] && refusal_log; exit "$rl_rc"' EXIT
