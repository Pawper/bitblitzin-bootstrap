#!/bin/sh
# Pure helpers for the merge queue's batch mode. Nothing here calls git or
# gh, so every function is tested with strings in tests/run.sh.

# batch_order ARGS...
# Print the PR numbers in the order given, one per line, with repeats
# dropped and anything that is not a number ignored.
batch_order() {
  seen=" "
  for bo_a in "$@"; do
    case "$bo_a" in ''|*[!0-9]*) continue ;; esac
    case "$seen" in *" $bo_a "*) continue ;; esac
    seen="$seen$bo_a "
    printf '%s\n' "$bo_a"
  done
}

# tests_for_diff PATHS
# PATHS is one changed path per line. Print the unit and component test
# files among them, one per line: anything under tests/ or ending in
# .test.* or .spec.* with a JavaScript or TypeScript extension. Browser
# runs (anything under e2e/, playwright/ or cypress/) are left out; the one
# full CI run covers those.
tests_for_diff() {
  printf '%s\n' "$1" | tr -d '\r' | tr '\\' '/' | awk '
    /^(e2e|playwright|cypress)\// { next }
    /\/(e2e|playwright|cypress)\// { next }
    /\.(test|spec)\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$/ { print; next }
    /^tests?\/.*\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$/ { print }
  ' | awk '!seen[$0]++'
}

# batch_branch_name DATE [N]
# "batch-2026-10-03", or "batch-2026-10-03-2" for the second batch of a day.
batch_branch_name() {
  if [ -n "$2" ] && [ "$2" -gt 1 ] 2>/dev/null; then
    printf 'batch-%s-%s\n' "$1" "$2"
  else
    printf 'batch-%s\n' "$1"
  fi
}

# carried_refs BODY
# The lines of a pull request body the batch must carry: each issue it
# closes ("Closes #12", "Fixes #12", "Resolves #12", any case) and each spec
# it names ("Spec: specs/004-dashboard"), one per line, in the order found.
# A batch body without them failed spec-check on every src-only batch and
# left every member's issue open after the merge.
carried_refs() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    {
      line = $0
      while (match(tolower(line), /(close[sd]?|fix(e[sd])?|resolve[sd]?)[ \t]+#[0-9]+/)) {
        m = substr(line, RSTART, RLENGTH); sub(/^[A-Za-z]+/, "", m); gsub(/[ \t]/, "", m)
        out = "Closes " m; if (!(out in seen)) { seen[out] = 1; print out }
        line = substr(line, RSTART + RLENGTH)
      }
      if (match($0, /[Ss]pec:[ \t]*[^ \t]+/)) {
        m = substr($0, RSTART, RLENGTH); sub(/^[Ss]pec:[ \t]*/, "", m)
        out = "Spec: " m; if (!(out in seen)) { seen[out] = 1; print out }
      }
    }'
}

# batch_pr_body CARRIED [REFS]
# CARRIED is one line per merged PR: "NUMBER<TAB>TITLE". REFS is what
# carried_refs gathered from every member's body. Print the body of the
# batch PR: one line per carried PR, then every member's Closes and Spec
# lines, so the batch passes spec-check whenever its members did and
# merging it closes their issues as well as the pull requests.
batch_pr_body() {
  printf 'One integration run for the pull requests below, merged in this order with merge commits. Each keeps its own history; the full suite runs once here.\n\n'
  printf '%s\n' "$1" | awk -F'\t' 'NF >= 1 && $1 != "" { printf "- #%s %s. Closes #%s\n", $1, $2, $1 }'
  if [ -n "$(printf '%s' "$2" | tr -d ' \n\r\t')" ]; then
    printf '\nCarried from the members:\n\n'
    printf '%s\n' "$2" | awk 'NF && !seen[$0]++'
  fi
}

# batch_line NUMBER OUTCOME [WHY]
# The one line printed per PR: "#12 merged into the batch", "#13 dropped:
# conflicts with main", "#14 merged serially".
batch_line() {
  if [ -n "$3" ]; then
    printf '#%s %s: %s\n' "$1" "$2" "$3"
  else
    printf '#%s %s\n' "$1" "$2"
  fi
}

# drain_candidates LIST BASE [TRIED]
# LIST is one open pull request per line:
#   "NUMBER<TAB>DRAFT(true|false)<TAB>MERGEABLE<TAB>ROLLUP<TAB>BASE_BRANCH"
# where ROLLUP is green, red, pending or none. Print, one per line in
# number order, the pull requests the drain should merge this round: not a
# draft, aimed at BASE, not conflicting, green, and not in TRIED (numbers a
# previous round already tried and could not merge).
drain_candidates() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base && toupper($3) != "CONFLICTING" && $4 == "green" && index(tried, " " $1 " ") == 0 { print $1 }' | sort -n
}

# drain_waiting LIST BASE
# How many non-draft pull requests aimed at BASE are still running CI.
drain_waiting() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base && ($4 == "pending" || ($4 == "cancelled" && index(tried, " " $1 " ") == 0)) { n++ } END { print n + 0 }'
}

# drain_retry LIST BASE RETRIED
# The red pull requests (not drafts, aimed at BASE) whose failed run has
# not been re-run yet in this drain: one retry each, because a flaky test
# or a lost runner should not stop a change.
drain_retry() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base && ($4 == "red" || $4 == "cancelled") && index(tried, " " $1 " ") == 0 { print $1 }' | sort -n
}

# drain_attention LIST BASE RETRIED
# The pull requests a person or an agent must look at, one per line as
# "NUMBER<TAB>why": conflicting with the base, or red again after its one
# retry. The drain exits non-zero naming these, so nobody has to notice.
drain_attention() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v base="$2" -v tried=" $3 " '
    NF >= 5 && $2 == "false" && $5 == base {
      if (toupper($3) == "CONFLICTING") printf "%s\thas conflicts with %s\n", $1, base
      else if ($4 == "red" && index(tried, " " $1 " ") > 0) printf "%s\tfailed CI twice\n", $1
      else if ($4 == "cancelled" && index(tried, " " $1 " ") > 0) printf "%s\thad its CI cancelled twice\n", $1
    }' | sort -n
}

# rest_rollup WORDS
# WORDS is one check-run outcome per line as REST reports it: a conclusion
# (success, failure, neutral, cancelled, timed_out, action_required,
# skipped, stale) or, while the run is not complete, its status (queued,
# in_progress, waiting, pending). Print the one word the drain reads:
# none, red, pending, cancelled or green. A cancelled job is not a red one:
# a runner hiccup or a newer push cancels it, and the drain re-runs it
# once rather than calling the change broken.
rest_rollup() {
  printf '%s\n' "$1" | tr -d '\r' | tr 'A-Z' 'a-z' | awk '
    NF == 0 { next }
    { n++ }
    /failure|timed_out|action_required|startup_failure/ { red = 1 }
    /cancelled/ { canc = 1 }
    /queued|in_progress|waiting|pending|requested/ { pend = 1 }
    END { if (n == 0) print "none"; else if (red) print "red"; else if (pend) print "pending"; else if (canc) print "cancelled"; else print "green" }'
}

# mergeable_word STATE
# STATE is REST's mergeable_state: clean, unstable, has_hooks, behind,
# blocked, dirty, draft, unknown. Print the word the drain reads:
# CONFLICTING for dirty, UNKNOWN for unknown or empty, MERGEABLE otherwise.
mergeable_word() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    dirty) echo CONFLICTING ;;
    ''|unknown) echo UNKNOWN ;;
    *) echo MERGEABLE ;;
  esac
}

# drain_hold GREEN WAITING
# Print "yes" when the drain should wait before merging: one or two green
# pull requests would merge serially while WAITING others are still
# running CI, and a serial merge moves main under every one of them, so
# they are updated and sent back round CI and the batch that follows has
# nothing. Hold until they finish, then batch. Print "no" when nothing is
# waiting, nothing is green, or there are enough green ones to batch now.
drain_hold() {
  if [ "${1:-0}" -gt 0 ] && [ "${1:-0}" -le 2 ] && [ "${2:-0}" -gt 0 ]; then echo yes; else echo no; fi
}

# rate_wait RATE NOW [FLOOR]
# RATE is "remaining<TAB>reset_epoch" as gh api rate_limit reports it for
# the core API. Print the seconds the queue should wait before spending
# more calls: 0 when more than FLOOR (default 500) calls are left, when the
# window has already reset, or when RATE is empty (the budget could not be
# read, and the queue goes on rather than stall); otherwise the seconds
# until the reset, at least one.
rate_wait() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v floor="${3:-500}" '
    NR == 1 {
      rem = $1 + 0; reset = $2 + 0
      if ($1 == "" || rem > floor || reset <= now) { print 0; exit }
      w = reset - now; if (w < 1) w = 1; print w; exit
    }
    END { if (NR == 0) print 0 }'
}

# rate_limit_hit TEXT
# Print "yes" when TEXT, the error output of a gh call, says GitHub's API
# rate limit was exceeded, "no" otherwise.
rate_limit_hit() {
  case $(printf '%s' "$1" | tr 'A-Z' 'a-z') in
    *"rate limit exceeded"*|*"api rate limit"*|*"secondary rate limit"*) echo yes ;;
    *) echo no ;;
  esac
}

# queue_lock_reason LOCK NOW ALIVE [STALE_SECONDS]
# LOCK is the text of the queue's lock file: "pid<TAB>started_epoch<TAB>mode".
# ALIVE is yes when that pid is still running. Print why a second queue must
# not start ("a --drain started 12 minutes ago is still running (pid 4242)"),
# or nothing when LOCK is empty, its process is gone, or it is older than
# STALE_SECONDS (default three hours), which is a lock a crash left behind.
queue_lock_reason() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v now="$2" -v alive="$3" -v stale="${4:-10800}" '
    NR == 1 && NF >= 3 && $1 != "" {
      age = now - ($2 + 0)
      if (alive != "yes" || age > stale) exit
      printf "a %s started %d minute(s) ago is still running (pid %s)\n", $3, int(age / 60), $1
      exit
    }'
}

# nearest_root FILE ROOTS
# ROOTS is one folder per line, each holding a package.json or tsconfig.json
# ("." for the repository root). Print the deepest root that contains FILE,
# so a test in web/src/a.test.ts runs from web/ when web/package.json exists,
# and from "." otherwise. Print nothing when no root contains it.
nearest_root() {
  nr_f=$(printf '%s' "$1" | tr '\\' '/')
  printf '%s\n' "$2" | tr -d '\r' | tr '\\' '/' | awk -v f="$nr_f" '
    { r = $0; sub(/\/$/, "", r); if (r == "" ) next
      if (r == ".") { if (length(best) == 0 && !seen) { best = "."; seen = 1 }; next }
      if (substr(f, 1, length(r) + 1) == r "/" && length(r) > length(best)) { best = r; seen = 1 } }
    END { if (seen) print best }'
}

# serial_refusal READY BECAUSE
# READY is the other open pull requests that are green and do not conflict
# with main, space separated; BECAUSE is the reason given with --because.
# Print why a serial merge is refused, or nothing when it may go: alone is
# fine when nothing else is ready, and a named reason always is. One agent
# hard-coded --serial into a landing script and copied it for every pull
# request; five that were ready together each landed alone, with a full CI
# run and a deploy apiece.
serial_refusal() {
  [ -z "$(printf '%s' "$2" | tr -d ' ')" ] || return 0
  [ -n "$(printf '%s' "$1" | tr -d ' ')" ] || return 0
  sr_n=$(printf '%s\n' $1 | wc -l | tr -d ' ')
  sr_list=$(printf '#%s ' $1 | sed 's/ $//')
  echo "$sr_n other green pull request(s) are ready to land with it ($sr_list); merge them together with --drain (or --batch), or give the reason this one must land alone: --serial N --because migration|conflict|must-land-alone|\"why\""
}

# serial_title TITLE NUMBER REASON
# The squash commit title of a serial merge, carrying its reason, so the
# nightly audit can read main's history: "Fix the chime (#79) [serial: alone]".
serial_title() {
  printf '%s (#%s) [serial: %s]\n' "$1" "$2" "${3:-alone}"
}

# serial_bursts LINES [WINDOW_SECONDS] [MAX]
# LINES is main's recent first-parent history, "epoch<TAB>subject", one per
# line. Print one line when more than MAX (default 2) serial merges landed
# within WINDOW (default an hour): how many, their reasons, and what to do.
# Nothing otherwise.
serial_bursts() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F'\t' -v win="${2:-3600}" -v max="${3:-2}" '
    $2 ~ /\[serial: [^]]*\]/ {
      r = $2; sub(/.*\[serial: /, "", r); sub(/\].*/, "", r)
      t[++n] = $1 + 0; why[n] = r
    }
    END {
      # times arrive newest first from git log; sort ascending
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (t[j] < t[i]) { x = t[i]; t[i] = t[j]; t[j] = x; y = why[i]; why[i] = why[j]; why[j] = y }
      best = 0
      for (i = 1; i <= n; i++) { k = 0; for (j = i; j <= n && t[j] - t[i] <= win; j++) k++; if (k > best) { best = k; bi = i } }
      if (best <= max) exit
      rs = ""; for (j = bi; j < bi + best; j++) rs = rs (rs == "" ? "" : ", ") why[j]
      printf "Main took %d serial merges within an hour (reasons: %s). Pull requests that are ready together should land as one batch: sh scripts/ci/merge-queue.sh --drain.\n", best, rs
    }'
}

# conflict_line FILES
# FILES is the conflicting paths from git merge-tree, one per line. Print
# the one line a serial run says for a pull request that conflicts with
# main, instead of "updated" round after round.
conflict_line() {
  cl=$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | head -n 5 | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$cl" ]; then echo "conflicts with main in $cl; resolve it on the branch, then queue it again"
  else echo "conflicts with main; resolve it on the branch, then queue it again"; fi
}
