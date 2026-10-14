#!/bin/sh
# Stop and SubagentStop hook: a clean folder is part of "done".
#
# It acts only inside a linked worktree, where an agent works on one task.
# In the main checkout a person is usually mid-work, and it stays out of
# the way. Before the agent may finish it checks three things:
#   1. nothing modified or untracked outside the scratch folder (.scratch/);
#   2. no images, video or build output left in the worktree;
#   3. no process still running from the worktree folder.
# It refuses once, names what it found, and says what to do. It kills
# nothing and removes nothing. If the agent stops again without fixing it,
# the second stop goes through, so a session can never be trapped.
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/refusal-log.sh"
. "$here/worktree-lib.sh"

input=$(cat)
case "$input" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac

root=${CLAUDE_PROJECT_DIR:-$(json_field "$input" cwd)}
[ -n "$root" ] && [ -d "$root" ] && cd "$root" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
gitdir=$(git rev-parse --git-dir 2>/dev/null) || exit 0
common=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
# The main checkout has the same git dir and common dir; a linked worktree does not.
[ "$(cd "$gitdir" 2>/dev/null && pwd)" != "$(cd "$common" 2>/dev/null && pwd)" ] || exit 0

problems=""
dirty=$(dirty_non_scratch "$(git status --porcelain --untracked-files=all 2>/dev/null)")
if [ -n "$dirty" ]; then
  count=$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')
  media=$(stray_media "$dirty")
  first=$(printf '%s\n' "$dirty" | head -n 5 | tr '\n' ' ')
  problems="$count file(s) outside .scratch/ are uncommitted ($first); commit them, or list them in the pull request as deliberately left out, or move scratch into .scratch/."
  if [ "$media" -gt 0 ]; then
    problems="$problems $media of them are images or build output, which belong in the work folder outside the repository, not in a worktree."
  fi
fi

here_path=$(pwd -W 2>/dev/null || pwd)
if command -v powershell >/dev/null 2>&1 && [ -n "$WINDIR" ]; then
  plist=$(powershell -NoProfile -Command 'Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId)`t$($_.CommandLine)" }' 2>/dev/null)
else
  plist=$(ps -eo pid=,args= 2>/dev/null | awk '{ pid = $1; $1 = ""; sub(/^ /, ""); print pid "\t" $0 }')
fi
running=$(procs_in_dir "$plist" "$here_path" | grep -v "	.*$$" | head -n 3)
if [ -n "$running" ]; then
  names=$(printf '%s\n' "$running" | awk -F'\t' '{ c = $2; if (length(c) > 60) c = substr(c, 1, 60) "..."; printf "%s (%s); ", $1, c }')
  problems="$problems Processes started from this worktree are still running: $names stop them before finishing."
fi

[ -n "$problems" ] || exit 0
printf '%s\n' "Not done yet, because a clean folder is part of done: $problems" >&2
exit 2
