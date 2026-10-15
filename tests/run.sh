#!/bin/sh
# Tests for the pure part of every script in this repository.
# Run from the repository root with: sh tests/run.sh
# Needs only sh and awk, like the scripts themselves.

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/hooks/scripts/lib.sh"
. "$root/templates/status/lib.sh"
. "$root/templates/scripts/ci/lib.sh"

pass=0
fail=0

# eq NAME EXPECTED ACTUAL
eq() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf 'ok    %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
  fi
}

printf '\n# json_field\n'
eq "reads a string field" "ls -la" "$(json_field '{"tool_input":{"command":"ls -la"}}' command)"
eq "undoes escapes" 'echo "hi" && cat a\b' "$(json_field '{"command":"echo \"hi\" && cat a\\b"}' command)"
eq "turns \\n into a newline" "a
b" "$(json_field '{"command":"a\nb"}' command)"
eq "missing key prints nothing" "" "$(json_field '{"x":"y"}' command)"
eq "skips spaces around the colon" "p" "$(json_field '{ "file_path" : "p" }' file_path)"

printf '\n# split_commands\n'
eq "splits on && ; | and ||" "a
b
c
d" "$(split_commands 'a && b; c | d')"
eq "strips env assignments and sudo" "rm x" "$(split_commands 'FOO=1 sudo rm x')"
eq "sees inside a subshell" "echo
rm x" "$(split_commands 'echo $(rm x)')"
eq "joins a backslash continuation" "gh issue create --title x --label state:ready" "$(split_commands 'gh issue create \
  --title x \
  --label state:ready')"
eq "skips a heredoc body" "cat > f.yml <<EOF
echo done" "$(split_commands 'cat > f.yml <<EOF
run: gh issue create --title x
rm -rf nothing
EOF
echo done')"
eq "skips a quoted heredoc body" "cat <<'EOF' > f
ls" "$(split_commands "cat <<'EOF' > f
rm -rf /
EOF
ls")"
eq "a label on a continued line counts" "" "$(state_label_reason 'gh issue create \
  --title "main is red" \
  --label "ci-red,state:ready" \
  --body "x"')"
eq "a create inside a heredoc is not a command" "" "$(state_label_reason 'cat > .github/workflows/ci.yml <<EOF
        run: gh issue create --title x
EOF')"
eq "a heredoc file first, then the labeled create" "" "$(state_label_reason "cat > b.md <<'EOF'
Body text here.
EOF
gh issue create --title t --label \"state: in progress\" --body-file b.md")"
eq "the label after --body-file" "" "$(state_label_reason 'gh issue create --title t --body-file b.md --label "state: in progress"')"
eq "a body from a heredoc inside a substitution, label after it" "" "$(state_label_reason "gh issue create --title t --body \"\$(cat <<'EOF'
Body text here.
EOF
)\" --label \"state: ready\"")"
eq "the same shape with no label is still refused" "gh issue create" "$(state_label_reason "gh issue create --title t --body \"\$(cat <<'EOF'
Body text here.
EOF
)\"")"
eq "a heredoc body that mentions gh issue create" "" "$(state_label_reason "cat > b.md <<'EOF'
Run gh issue create without a label to see the hook refuse it.
EOF
gh issue create --title t --label state:ready --body-file b.md")"
eq "an rm inside a heredoc is not a command" "" "$(delete_reason 'cat > script.sh <<EOF
rm -rf build
EOF')"
eq "a command after the heredoc still counts" "rm" "$(delete_reason 'cat > s.sh <<EOF
echo hi
EOF
rm -rf build')"

printf '\n# delete_reason\n'
eq "rm" "rm" "$(delete_reason 'rm -rf build')"
eq "rm after cd" "rm" "$(delete_reason 'cd x && rm -r y')"
eq "rm by full path" "rm" "$(delete_reason '/bin/rm x')"
eq "rmdir" "rmdir" "$(delete_reason 'rmdir empty')"
eq "del" "del" "$(delete_reason 'del /q file.txt')"
eq "Remove-Item" "Remove-Item" "$(delete_reason 'Remove-Item -Recurse out')"
eq "Remove-Item inside powershell" "remove-item" "$(delete_reason 'powershell -Command "Remove-Item out"')"
eq "del inside cmd /c" "del" "$(delete_reason 'cmd /c del x.txt')"
eq "git clean" "git clean" "$(delete_reason 'git clean -fdx')"
eq "git status is fine" "" "$(delete_reason 'git status && ls')"
eq "a word containing rm is fine" "" "$(delete_reason 'npm run format')"
eq "git rm is not a delete of history" "" "$(delete_reason 'git rm --cached x')"
eq "removing in a string is fine" "" "$(delete_reason 'echo "do not rm this"')"

printf '\n# force_push_reason\n'
eq "--force" "--force" "$(force_push_reason 'git push --force origin main')"
eq "--force-with-lease" "--force-with-lease=main" "$(force_push_reason 'git push --force-with-lease=main origin main')"
eq "-f" "-f" "$(force_push_reason 'git push -f')"
eq "combined short flags" "-uf" "$(force_push_reason 'git push -uf origin x')"
eq "plus refspec" "+main" "$(force_push_reason 'git push origin +main')"
eq "quoted plus refspec" "+main" "$(force_push_reason "git push origin '+main'")"
eq "after git -C" "--force" "$(force_push_reason 'git -C /repo push --force')"
eq "plain push is fine" "" "$(force_push_reason 'git push -u origin feature')"
eq "a commit named force is fine" "" "$(force_push_reason 'git commit -m "force"')"
eq "push in a later command" "-f" "$(force_push_reason 'git fetch && git push -f')"

printf '\n# full_sweep_reason\n'
eq "bare pytest" "pytest" "$(full_sweep_reason 'pytest')"
eq "pytest with options only" "pytest" "$(full_sweep_reason 'pytest -q --maxfail=1')"
eq "pytest with a file is fine" "" "$(full_sweep_reason 'pytest tests/test_a.py')"
eq "listing the runner binary is not a sweep" "" "$(full_sweep_reason 'ls node_modules/.bin/vitest')"
eq "a quoted test path is targeted" "" "$(full_sweep_reason 'npx vitest run "tests/unit/a.test.ts"')"
eq "npm t with a file is targeted" "" "$(full_sweep_reason 'npm t -- a.test.ts')"
eq "the runner named in a string is not a run" "" "$(full_sweep_reason 'gh issue create --title "vitest sweeps" --body "npm test is a gate" --label state:ready')"
eq "pytest with -k is fine" "" "$(full_sweep_reason 'pytest -k login')"
eq "npm test" "npm test" "$(full_sweep_reason 'npm test')"
eq "npm run test" "npm test" "$(full_sweep_reason 'npm run test -- --coverage')"
eq "npm test with a file is fine" "" "$(full_sweep_reason 'npm test -- src/a.test.ts')"
eq "yarn test" "yarn test" "$(full_sweep_reason 'yarn test')"
eq "pnpm test" "pnpm test" "$(full_sweep_reason 'pnpm test')"
eq "npx jest" "jest" "$(full_sweep_reason 'npx jest')"
eq "npx vitest run with a file is fine" "" "$(full_sweep_reason 'npx vitest run src/a.test.ts')"
eq "vitest run alone" "vitest" "$(full_sweep_reason 'vitest run')"
eq "go test ./..." "go test" "$(full_sweep_reason 'go test ./...')"
eq "go test one package is fine" "" "$(full_sweep_reason 'go test ./pkg/auth')"
eq "cargo test" "cargo test" "$(full_sweep_reason 'cargo test')"
eq "cargo test with a filter is fine" "" "$(full_sweep_reason 'cargo test parse_date')"
eq "dotnet test" "dotnet test" "$(full_sweep_reason 'dotnet test')"
eq "dotnet test with --filter is fine" "" "$(full_sweep_reason 'dotnet test --filter Name~Login')"
eq "python -m pytest" "pytest" "$(full_sweep_reason 'python -m pytest')"
eq "uv run pytest" "pytest" "$(full_sweep_reason 'uv run pytest')"
eq "a sweep after cd" "pytest" "$(full_sweep_reason 'cd app && pytest')"
for ext in ts tsx js jsx mjs cjs; do
  eq "one named .test.$ext file is not a sweep" "" "$(full_sweep_reason "npx vitest run src/Foo.test.$ext")"
  eq "one named .spec.$ext file is not a sweep" "" "$(full_sweep_reason "npx vitest run src/Foo.spec.$ext")"
done
eq "one .tsx file with a project flag" "" "$(full_sweep_reason 'npx vitest run src/Foo.test.tsx --project dom')"
eq "one .tsx file with a config flag first" "" "$(full_sweep_reason 'npx vitest run --config vitest.dom.config.ts src/Foo.test.tsx')"
eq "one .tsx file with Windows separators" "" "$(full_sweep_reason 'npx vitest run src\Foo.test.tsx')"
eq "one .tsx file piped to tail" "" "$(full_sweep_reason 'npx vitest run src/Foo.test.tsx 2>&1 | tail -20')"
eq "npm run build is fine" "" "$(full_sweep_reason 'npm run build')"
eq "ls is fine" "" "$(full_sweep_reason 'ls tests')"

printf '\n# generated_page_reason\n'
pages="# comment
STATUS.md
docs/generated/*"
eq "matches by file name" "STATUS.md" "$(generated_page_reason /proj/STATUS.md /proj "$pages")"
eq "matches a Windows path" "STATUS.md" "$(generated_page_reason 'C:\proj\STATUS.md' 'C:\proj' "$pages")"
eq "matches a path pattern" "docs/generated/api.md" "$(generated_page_reason /proj/docs/generated/api.md /proj "$pages")"
eq "matches a path pattern when the root is unknown" "/other/docs/generated/api.md" "$(generated_page_reason /other/docs/generated/api.md /proj "$pages")"
eq "a stub is fine" "" "$(generated_page_reason /proj/status/stubs/x.md /proj "$pages")"
eq "an unrelated file is fine" "" "$(generated_page_reason /proj/src/a.ts /proj "$pages")"
eq "a comment line never matches" "" "$(generated_page_reason '/proj/# comment' /proj "$pages")"

printf '\n# state_label_reason\n'
eq "no label" "gh issue create" "$(state_label_reason 'gh issue create --title x --body y')"
eq "a label without a state" "gh issue create" "$(state_label_reason 'gh issue create -t x -l bug')"
eq "--label state:" "" "$(state_label_reason 'gh issue create -t x --label state:ready')"
eq "-l with a list" "" "$(state_label_reason 'gh issue create -t x -l bug,state:parked')"
eq "--label= form" "" "$(state_label_reason 'gh issue create --label=state:dated -t x')"
eq "quoted label" "" "$(state_label_reason "gh issue create -l 'state:waiting-on-owner' -t x")"
eq "--web opens the form, which requires it" "" "$(state_label_reason 'gh issue create --web')"
eq "a quoted list with spaces" "" "$(state_label_reason 'gh issue create --title x --label "ci-red, state: ready" --body y')"
eq "a quoted list with spaces on a continued line" "" "$(state_label_reason 'gh issue create \
  --title "main is red" \
  --label "ci-red, state: ready" \
  --body y')"
eq "a quoted label with a space but no state" "gh issue create" "$(state_label_reason 'gh issue create -l "needs triage" -t x')"
eq "gh issue list is fine" "" "$(state_label_reason 'gh issue list')"
eq "create in a later command" "gh issue create" "$(state_label_reason 'git push && gh issue create -t x')"

printf '
# project_flag_reason
'
eq "no --project" "gh issue create" "$(project_flag_reason 'gh issue create -t x -b y')"
eq "--project" "" "$(project_flag_reason 'gh issue create -t x --project "Retro Jam"')"
eq "-p" "" "$(project_flag_reason 'gh issue create -t x -p Board')"
eq "a state label alone is not enough here" "gh issue create" "$(project_flag_reason 'gh issue create -t x -l state:ready')"
eq "--web" "" "$(project_flag_reason 'gh issue create --web')"

printf '\n# batch_merge_reason\n'
eq "three PRs with no flag" "3" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh 41 42 45')"
eq "three PRs with --batch" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh --batch 41 42 45')"
eq "three PRs with --serial" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh --serial 41 42 45')"
eq "two PRs with no flag" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh 41 42')"
eq "one PR as before" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh 41 main')"
eq "a chained serial run after cd" "4" "$(batch_merge_reason 'cd app && sh ./scripts/ci/merge-queue.sh 1 2 3 4')"
eq "another script with numbers is fine" "" "$(batch_merge_reason 'sh scripts/other.sh 1 2 3')"

printf '\n# batch helpers\n'
. "$root/templates/scripts/ci/batch-lib.sh"
eq "order kept, repeats dropped, words ignored" "41
42
45" "$(batch_order 41 42 41 x 45 | tr '\n' ' ' | sed 's/ $//' | tr ' ' '\n')"
eq "test files from a diff" "tests/unit/a.test.ts
src/b.spec.tsx" "$(tests_for_diff 'src/a.ts
tests/unit/a.test.ts
src/b.spec.tsx
docs/x.md
e2e/login.spec.ts
tests/e2e/flow.test.ts')"
eq "no test files, nothing" "" "$(tests_for_diff 'src/a.ts
README.md')"
eq "branch name for the day" "batch-2026-10-03" "$(batch_branch_name 2026-10-03)"
eq "second batch of the day" "batch-2026-10-03-2" "$(batch_branch_name 2026-10-03 2)"
eq "batch PR body" "- #41 Add retries. Closes #41
- #45 Fix the parser. Closes #45" "$(batch_pr_body "$(printf '41\tAdd retries\n45\tFix the parser\n')" | tail -n 2)"
eq "one line per PR" "#13 dropped: conflicts with the batch so far" "$(batch_line 13 dropped 'conflicts with the batch so far')"
eq "one line without a reason" "#12 merged into the batch" "$(batch_line 12 'merged into the batch')"

printf '\n# session brief\n'
. "$root/hooks/scripts/session-brief-lib.sh"
fx="$root/tests/fixtures"
eq "json_number reads a number" "40" "$(json_number '{"maxLines": 40, "x": "y"}' maxLines)"
eq "json_number missing key" "" "$(json_number '{"x": 1}' maxLines)"
eq "pr line, green" "#41 Add retries to the client (mergeable, CI green)" "$(pr_line "$(sed -n 1p "$fx/pr-list.tsv")")"
eq "pr line, conflicts and a failure" "#42 Fix the date parser (has conflicts, CI 1 failed)" "$(pr_line "$(sed -n 2p "$fx/pr-list.tsv")")"
eq "pr line, pending" "#45 Rename the status page (mergeability unknown, CI 2 pending)" "$(pr_line "$(sed -n 3p "$fx/pr-list.tsv")")"
eq "pr line, no CI" "#47 Docs only (mergeable, no CI yet)" "$(pr_line "$(sed -n 4p "$fx/pr-list.tsv")")"
eq "today names the zone" "Today: Friday 2026-10-09, 22:00 PDT. Dates in this repository are America/Los_Angeles days; gh and runner timestamps are UTC, convert before writing one." "$(today_line 'Friday 2026-10-09, 22:00 PDT' America/Los_Angeles)"
eq "today without a zone says local" "Today: Friday 2026-10-09, 22:00 PDT. Dates in this repository are the owner's local day; gh and runner timestamps are UTC, convert before writing one." "$(today_line 'Friday 2026-10-09, 22:00 PDT' TIMEZONE)"
eq "a Windows path becomes Claude Code's project slug" "C--Users-me-Documents-GitHub-repo" "$(project_slug 'C:\Users\me\Documents\GitHub\repo')"
eq "a Unix path becomes the slug too" "-Users-me-repo" "$(project_slug '/Users/me/repo')"
eq "log written an hour ago is recent" "yes" "$(log_is_recent 1000000 1003600)"
eq "log written three hours ago is not" "no" "$(log_is_recent 1000000 1010800)"
eq "log with a bad time is not" "no" "$(log_is_recent '' 1000000)"
eq "a low API budget is one line" "GitHub API budget: 312 of 5000 left; resets in 41 minute(s). Poll slowly (30s or more) and run one queue at a time." "$(rate_line "312	5000	3460" 1000)"
eq "no API budget says so" "GitHub API budget: none left of 5000; resets in 10 minute(s). Do not poll; run the queue with --drain after that." "$(rate_line "0	5000	1600" 1000)"
eq "a healthy API budget is silent" "" "$(rate_line "4800	5000	1600" 1000)"
eq "an unknown API budget is silent" "" "$(rate_line '' 1000)"
eq "newest handoff, ignoring other notes" "/mem/handoff-2026-10-02.md" "$(newest_handoff "$(cat "$fx/handoff-listing.tsv")")"
eq "no handoff files, nothing" "" "$(newest_handoff "$(printf '1\t/mem/notes.md\n')")"
eq "handoff head skips front matter" "The batch queue PR is open and waiting on one full run.
Next: merge it, then run the serial queue for #45, which conflicted." "$(handoff_head "$(cat "$fx/handoff-2026-10-02.md")" 2)"
eq "trim within the limit" "a
b" "$(trim_section 'a
b' 5)"
eq "trim past the limit says how many" "a
b
(and 2 more)" "$(trim_section 'a
b
c
d' 2)"
eq "a clear prints the short form" "main inprogress" "$(brief_sections clear)"
eq "a startup prints everything" "main prs queue inprogress leftover handoff owner proposal" "$(brief_sections startup)"
facts=$(cat "$fx/board-facts.tsv")
eq "pr lines from the one-call facts" "#41 Add retries (mergeable, CI green)
#42 Fix the parser (has conflicts, CI red)
#45 Rename the page (mergeability unknown, CI running)
#47 Docs only (mergeable, no CI yet)" "$(pr_brief_lines "$facts" 10)"
eq "pr lines past the limit are counted" "#41 Add retries (mergeable, CI green)
(and 3 more)" "$(pr_brief_lines "$facts" 1)"
eq "state from labels, either spelling" "in-progress in-progress none" "$(printf '%s %s %s' "$(state_of_labels 'task,state:in-progress')" "$(state_of_labels 'state: in progress')" "$(state_of_labels 'bug,task')")"
eq "issues grouped by state, long lists counted" "Issues: 57 open. 3 ready, 2 in progress, 1 waiting on owner, 1 parked, 1 no state (first 8 read)
In progress:
#20 Billing
#21 Search
Owner actions waiting:
#30 Choose the logo
Ready:
#12 Add the exporter
#13 Set the price of the plan
#77 main is red" "$(issues_summary "$facts")"
eq "no issues, no summary" "" "$(issues_summary 'pr	1	x	NONE	MERGEABLE	b	')"
eq "leftover work from one local listing" "Leftover work: 2 of 4 local branches have commits not on main.
retries (3)
rename (1)" "$(leftover_summary "$(printf 'main\t0 0\nretries\t3 12\nparser\t0 4\nrename\t1 0\n')" 5)"
eq "nothing ahead, nothing said" "" "$(leftover_summary "$(printf 'main\t0 0\nparser\t0 4\n')" 5)"
porcelain=$(cat "$fx/worktrees.porcelain")
eq "worktrees counted with their folders, the agent runtime's apart" "Worktrees: 2 besides the main checkout, in 1 folder, and 2 made by Claude Code for dispatched agents in .claude/worktrees." "$(worktree_summary "$porcelain")"
eq "only the main checkout, nothing said" "" "$(worktree_summary 'worktree /repo
branch refs/heads/main')"

printf '\n# reading a run\n'
. "$root/templates/scripts/ci/run-lib.sh"
eq "green run" "green" "$(run_verdict "$(printf 'build\tcompleted\tsuccess\t1000\t\ntest\tcompleted\tskipped\t1000\t\n')" 2000)"
eq "pending run" "pending" "$(run_verdict "$(printf 'build\tin_progress\t\t1000\t\n')" 2000)"
eq "failed run names the job" "failed: test, lint" "$(run_verdict "$(printf 'build\tcompleted\tsuccess\t1\t\ntest\tcompleted\tfailure\t1\t\nlint\tcompleted\tfailure\t1\t\n')" 2000)"
eq "canceled run" "canceled: test" "$(run_verdict "$(printf 'test\tcompleted\tcancelled\t1\t\n')" 2000)"
eq "outage by annotation" "outage: build: The job was not acquired by Runner of type hosted" "$(run_verdict "$(printf 'build\tqueued\t\t1000\tThe job was not acquired by Runner of type hosted\n')" 1100)"
eq "outage by a long queue while our runners idle" "outage: build: queued for 10 minutes while 2 of our runners were idle" "$(run_verdict "$(printf 'build\tqueued\t\t1000\t\n')" 1600 2)"
eq "a long queue with no idle runner is just pending" "pending" "$(run_verdict "$(printf 'build\tqueued\t\t1000\t\n')" 1600 0)"
eq "githubstatus degraded" "GitHub Actions: degraded_performance" "$(githubstatus_verdict '{"components":[{"name":"Git Operations","status":"operational"},{"name":"Actions","status":"degraded_performance"}]}')"
eq "githubstatus fine" "" "$(githubstatus_verdict '{"components":[{"name":"Actions","status":"operational"}]}')"
eq "githubstatus empty" "" "$(githubstatus_verdict '')"
eq "failing tests from three runner formats" "src/preview.test.tsx > renders the preview
tests/test_a.py::test_x
TestParse" "$(failed_tests_from_log "$(printf ' FAIL  src/preview.test.tsx > renders the preview 120ms\n   ok other\nFAILED tests/test_a.py::test_x - assert 1 == 2\n--- FAIL: TestParse (0.00s)\n FAIL  src/preview.test.tsx > renders the preview\n')")"
flog=$(flaky_log_add '' 2026-10-05 41 'src/preview.test.tsx > renders' failed)
flog=$(flaky_log_add "$flog" 2026-10-05 41 'src/preview.test.tsx > renders' passed)
flog=$(flaky_log_add "$flog" 2026-10-05 42 'src/preview.test.tsx > renders' failed)
flog=$(flaky_log_add "$flog" 2026-10-05 42 'src/preview.test.tsx > renders' passed)
flog=$(flaky_log_add "$flog" 2026-10-05 43 'src/other.test.ts > once' failed)
flog=$(flaky_log_add "$flog" 2026-10-05 43 'src/other.test.ts > once' passed)
flog=$(flaky_log_add "$flog" 2026-10-05 44 'src/real.test.ts > broken' failed)
eq "the log grows one line at a time" "7" "$(printf '%s\n' "$flog" | wc -l | tr -d ' ')"
eq "offenders: failed then passed, twice, with their PRs" "2	src/preview.test.tsx > renders	41,42" "$(flaky_offenders "$flog" 2)"
eq "one flake is not yet an offender, a plain failure never is" "1	src/other.test.ts > once	43
2	src/preview.test.tsx > renders	41,42" "$(flaky_offenders "$flog" 1 | sort -t'	' -k2)"
eq "main in flight" "yes" "$(main_in_flight "$(printf '1\tmain\tin_progress\tpush\n2\tfeature\tqueued\tpull_request\n')")"
eq "main quiet" "no" "$(main_in_flight "$(printf '1\tmain\tcompleted\tpush\n2\tfeature\tin_progress\tpull_request\n')")"

printf '\n# runner doctor\n'
. "$root/templates/scripts/ci/doctor-lib.sh"
eq "WSL bash on PATH warns" "warn" "$(bash_verdict 'C:\Windows\System32\bash.exe')"
eq "Git bash is fine" "ok" "$(bash_verdict '/c/Program Files/Git/usr/bin/bash')"
eq "no bash warns" "warn" "$(bash_verdict '')"
eq "a tool whose folder is on the machine PATH" "ok" "$(tool_on_machine_path '/c/Program Files/nodejs/node' 'C:\Windows;C:\Program Files\nodejs\;C:\Program Files\Git\cmd')"
eq "a tool missing from the machine PATH" "warn" "$(tool_on_machine_path '/c/Users/me/AppData/Roaming/npm/node' 'C:\Windows;C:\Program Files\Git\cmd')"
eq "a restricted machine policy warns" "warn" "$(policy_verdict 'MachinePolicy=Undefined UserPolicy=Undefined Process=Undefined CurrentUser=Undefined LocalMachine=Restricted')"
eq "an open policy is fine" "ok" "$(policy_verdict 'MachinePolicy=Undefined LocalMachine=RemoteSigned')"
eq "a shell that sets NoDefaultCurrentDirectoryInExePath warns" "warn" "$(exepath_verdict 1)"
eq "a shell that does not set it is fine" "ok" "$(exepath_verdict '')"

printf '\n# board digest\n'
. "$root/scripts/board/board-lib.sh"
dfacts=$(cat "$fx/board-facts-dated.tsv")
ddigest=$(cat "$fx/board-digest.tsv")
eq "open items with their last-updated time" "41	pr	2026-10-04T10:00:00Z	Add retries
12	issue	2026-10-03T09:00:00Z	Add the exporter" "$(open_items "$dfacts" | head -n 2)"
eq "only items with a missing or older summary are changed" "12	issue
30	issue" "$(changed_items "$dfacts" "$ddigest")"
eq "with no digest everything is changed" "6" "$(changed_items "$dfacts" '' | wc -l | tr -d ' ')"
eq "freshness counts current over open" "4	6" "$(digest_freshness "$dfacts" "$ddigest")"
merged=$(merge_digest "$ddigest" '12 | Agent | start the exporter | - | Ready to build; nothing decided yet.
30 | agent | use option B | - | The owner chose B.
77 | agent | not open | - | Should be ignored.
garbage line' "$dfacts")
eq "merge keeps open items, replaces the re-read, drops the closed" "6" "$(printf '%s\n' "$merged" | wc -l | tr -d ' ')"
eq "a re-read item is stamped with its current time" "30	issue	2026-10-04T11:30:00Z	agent	use option B	-	The owner chose B." "$(printf '%s\n' "$merged" | grep '^30	')"
eq "a new item is added with its kind and time" "12	issue	2026-10-03T09:00:00Z	agent	start the exporter	-	Ready to build; nothing decided yet." "$(printf '%s\n' "$merged" | grep '^12	')"
eq "a closed item drops out and an unknown one is ignored" "" "$(printf '%s\n' "$merged" | grep -E '^(99|77)	')"
eq "after the merge everything is current" "6	6" "$(digest_freshness "$dfacts" "$merged")"
eq "batches of paths for readers" "a b
c" "$(batch_paths 'a
b
c' 2)"
eq "the brief's lines: who has the ball, owner first" "#30 Choose the logo: ball owner; next owner picks a logo (changed since)
#31 Pick the price: ball agent; next set the price to 48 and continue
#40 Mail is bouncing: ball service; next wait for the mail provider; blocked by the provider's outage
#20 Billing: ball owner; next owner picks monthly or yearly first
#41 Add retries: ball reviewer; next review and merge" "$(digest_brief_lines "$dfacts" "$ddigest" 8)"
eq "the brief's lines are counted past the limit" "#30 Choose the logo: ball owner; next owner picks a logo (changed since)
(and 4 more in the digest)" "$(digest_brief_lines "$dfacts" "$ddigest" 1)"
eq "goals labels alone would miss, from current summaries only" "mark-waiting 20	Billing (a question to the owner is open)
set-ready 31	Pick the price (the owner answered)" "$(digest_goals "$dfacts" "$ddigest")"
eq "no digest, no extra goals" "" "$(digest_goals "$dfacts" '')"

printf '\n# clean endings (hook library)\n'
. "$root/hooks/scripts/worktree-lib.sh"
status=' M scripts/upload.sh
?? tests/admin.test.ts
?? .scratch/probe.mjs
?? shots/a.png
?? shots/b.JPG
R  old.md -> docs/new.md'
eq "dirty files outside the scratch folder" "scripts/upload.sh
tests/admin.test.ts
shots/a.png
shots/b.JPG
docs/new.md" "$(dirty_non_scratch "$status")"
eq "only scratch is clean" "" "$(dirty_non_scratch '?? .scratch/notes.md
?? .scratch/')"
eq "a clean tree is clean" "" "$(dirty_non_scratch '')"
eq "images and build output counted" "3" "$(stray_media 'shots/a.png
shots/b.JPG
src/a.ts
dist/')"
eq "no media, zero" "0" "$(stray_media 'src/a.ts')"
eq "processes started from the folder" "412	node C:\\Users\\me\\wt\\task\\node_modules\\next\\dist\\bin\\next start" "$(procs_in_dir "$(printf '412\tnode C:\\Users\\me\\wt\\task\\node_modules\\next\\dist\\bin\\next start\n77\tnode D:/other/server.js\n90\tsh C:/Users/me/wt/task/../hooks/scripts/session-brief.sh\n')" 'C:/Users/me/wt/task')"
eq "no process in the folder" "" "$(procs_in_dir "$(printf '77\tnode D:/other/server.js\n')" '/home/me/wt/task')"
eq "closing a PR with no comment" "gh pr close" "$(pr_close_reason 'gh pr close 41')"
eq "closing with a comment is fine" "" "$(pr_close_reason 'gh pr close 41 --comment "replaced by #52"')"
eq "closing with -c is fine" "" "$(pr_close_reason 'gh pr close 41 -c "duplicate of #40"')"

printf '\n# long_command_reason\n'
eq "a short titled command is fine" "" "$(long_command_reason 'git status' 'Show the working tree')"
eq "no description is named" "no description" "$(long_command_reason 'git status' '')"
eq "a whitespace description is no description" "no description" "$(long_command_reason 'git status' '  ')"
eq "too many lines is named by count" "14 lines" "$(long_command_reason "$(seq 1 14 | sed 's/^/echo /')" 'Echo fourteen lines')"
eq "too many characters is named by count" "1200 characters" "$(long_command_reason "$(head -c 1200 /dev/zero | tr '\0' 'x')" 'A long one')"
eq "the limits can be set" "3 lines" "$(long_command_reason 'a
b
c' 'Three' 2)"
eq "a long quoted body is not counted" "" "$(long_command_reason "gh api -X POST repos/o/r/pulls -f title=x -f body=\"$(head -c 1500 /dev/zero | tr '\0' 'y')\"" 'Open the pull request')"
eq "a long quoted body with newlines is not counted" "" "$(long_command_reason "gh api -f body=\"$(seq 1 30 | tr '\n' ' ' | sed 's/ /\
/g')\"" 'Open it')"
eq "a long program in a heredoc still counts" "14 lines" "$(long_command_reason "python - <<'EOF'
$(seq 1 12 | sed 's/^/print(/; s/$/)/')
EOF" 'Run it')"
eq "a rate limit is a refusal, not a sign-out" "yes" "$(gh_refusal 'GraphQL: API rate limit exceeded for user ID 1')"
eq "unknown owner type is a refusal" "yes" "$(gh_refusal 'unknown owner type: Pawper')"
eq "a sign-out is not" "no" "$(gh_refusal 'You are not logged into any GitHub hosts')"

printf '\n# daemon_stop_reason\n'
eq "gradlew --stop is refused" "gradlew --stop" "$(daemon_stop_reason './gradlew --stop')"
eq "the Windows wrapper too" "gradlew --stop" "$(daemon_stop_reason 'cd android && .\gradlew.bat --stop')"
eq "gradle --stop is refused" "gradle --stop" "$(daemon_stop_reason 'gradle --stop')"
eq "nx reset is refused" "nx reset" "$(daemon_stop_reason 'npx nx reset')"
eq "dotnet build-server shutdown is refused" "dotnet build-server shutdown" "$(daemon_stop_reason 'dotnet build-server shutdown')"
eq "a build is fine" "" "$(daemon_stop_reason './gradlew assembleDebug')"
eq "the word in a string is fine" "" "$(daemon_stop_reason 'git commit -m "never run gradlew --stop"')"
eq "no runner on this machine, allowed" "" "$(daemon_stop_reason 'DAEMON_STOP_OK=1 ./gradlew --stop')"
eq "viewing a PR is fine" "" "$(pr_close_reason 'gh pr view 41')"
eq "a detached worktree" "detached" "$(worktree_add_reason 'git worktree add --detach ../wt/x HEAD')"
eq "a worktree with a branch is fine" "" "$(worktree_add_reason 'git worktree add -b task-x ../wt/x')"
eq "git branch -d is not a worktree add" "" "$(worktree_add_reason 'git branch -d old')"
wtpairs=$(printf '/w/a\tretries\n/w/b\tparser\n/w/c\trename\n/w/d\t\n')
eq "stale and detached worktrees counted" "1	1" "$(stale_worktrees "$wtpairs" 'retries' "$(printf 'retries\t1000000\nparser\t1000000\nrename\t1900000\n')" 2000000 3)"

printf '\n# worktrees\n'
. "$root/templates/scripts/worktrees-lib.sh"
pairs=$(worktree_branches "$porcelain")
eq "the worktree of a branch" "C:/Users/me/Documents/GitHub/app-parser" "$(worktree_for_branch "$pairs" parser)"
eq "no worktree for a branch" "" "$(worktree_for_branch "$pairs" nothing)"
eq "detached worktrees named" "C:/Users/me/Documents/GitHub/app/.claude/worktrees/loose" "$(detached_worktrees "$pairs")"
ends=$(printf 'merged\tretries\nclosed\tparser\nmerged\tgone\n')
eq "merged heads from ended pull requests" "retries
gone" "$(pr_ends "$ends" merged)"
eq "closed heads from ended pull requests" "parser" "$(pr_ends "$ends" closed)"
eq "merged local branches with no worktree" "old-fix" "$(mergeable_local_branches 'main
retries
old-fix
wip' 'main
retries
old-fix' "$pairs" main)"
eq "the queue's folder test matches the hook's" "scripts/upload.sh" "$(dirty_non_scratch ' M scripts/upload.sh
?? .scratch/x')"

printf '\n# shared code and ended branches\n'
shared='# comment
scripts/build/*
src/lib/*'
eq "shared code mixed with other work" "scripts/build/pack.mjs" "$(shared_mix_reason 'scripts/build/pack.mjs
packs/durer/index.json' "$shared")"
eq "only shared code is fine" "" "$(shared_mix_reason 'scripts/build/pack.mjs
src/lib/a.ts' "$shared")"
eq "no shared code is fine" "" "$(shared_mix_reason 'packs/durer/index.json' "$shared")"
eq "an empty list never fails" "" "$(shared_mix_reason 'scripts/build/pack.mjs
packs/x' '# nothing listed')"
eq "remote branches whose pull request ended" "retries
parser" "$(ended_remote_branches 'main
retries
parser
wip' 'retries
parser
main')"
eq "the audit counts ended branches" "2 branch(es) are still on the remote after their pull request merged or closed. Their worktrees, if any, are leftovers; run sh scripts/worktrees.sh audit locally.
- retries
- parser" "$(audit_comment '' '' '' 'retries
parser')"
eq "path and branch per worktree, main left out" "C:/Users/me/Documents/GitHub/app-retries	retries
C:/Users/me/Documents/GitHub/app-parser	parser
C:/Users/me/Documents/GitHub/app/.claude/worktrees/rename	rename
C:/Users/me/Documents/GitHub/app/.claude/worktrees/loose	" "$pairs"
eq "merged branches are prunable, detached never" "C:/Users/me/Documents/GitHub/app-retries
C:/Users/me/Documents/GitHub/app/.claude/worktrees/rename" "$(prunable_worktrees "$pairs" 'retries
rename
loose')"
eq "one branch only" "C:/Users/me/Documents/GitHub/app/.claude/worktrees/rename" "$(prunable_worktrees "$pairs" 'retries
rename' rename)"
eq "an unmerged branch is not prunable" "" "$(prunable_worktrees "$pairs" 'other')"
eq "places counted" "2 2" "$(worktree_places "$pairs" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"

printf '\n# project drive\n'
. "$root/scripts/drive/drive-lib.sh"
snap=$(cat "$fx/drive-snapshot.tsv")
eq "a full proposal, in order" "merge-batch 41 42 45 46
fix-pr 47	Broken build
ask-owner 13	Set the price of the plan
dispatch 12	Add the exporter
defer 2 ready issue(s): no free runner this round
fix-main 77
audit Open issues with no State label: #33
restart-queue
stop: proposal ready for approval" "$(propose_round "$snap" 2 4)"
eq "two green PRs merge one by one" "merge 41
merge 42
stop: proposal ready for approval" "$(propose_round 'pr	41	A	green	mergeable	app
pr	42	B	green	mergeable	app' 2 4)"
eq "three green but only two app PRs merge one by one" "merge 41
merge 42
merge 46
stop: proposal ready for approval" "$(propose_round 'pr	41	A	green	mergeable	app
pr	42	B	green	mergeable	app
pr	46	Docs	green	mergeable	other' 2 4)"
eq "more runners, more starts, within the agent budget" "dispatch 12	Add the exporter
dispatch 14	Fix the date format
dispatch 15	Rework the search
stop: proposal ready for approval" "$(propose_round 'issue	12	Add the exporter	ready	no
issue	14	Fix the date format	ready	no
issue	15	Rework the search	ready	no' 4 3)"
eq "nothing to propose stops" "stop: nothing to propose" "$(propose_round 'queue	none' 2 4)"
eq "only owner waits stops with the reason" "stop: everything left waits on a person" "$(propose_round 'issue	30	Logo	waiting-on-owner	no' 2 4)"
eq "work in flight stops with the reason" "stop: work is in flight; nothing to propose until it lands" "$(propose_round 'pr	48	Running	pending	mergeable	app
issue	20	Billing	in-progress	no' 2 4)"
eq "a conflicting green PR is not proposed for merge" "stop: work is in flight; nothing to propose until it lands" "$(propose_round 'pr	49	Old	green	conflicting	app' 2 4)"
eq "proposal numbered, defer and stop unnumbered" "$(cat "$fx/drive-proposal.txt")" "$(number_proposal "$(propose_round "$snap" 2 4)")"
numbered=$(cat "$fx/drive-proposal.txt")
eq "approve a list" "merge-batch 41 42 45 46
dispatch 12	Add the exporter" "$(approved_goals "$numbered" '1, 4')"
eq "approve all" "7" "$(approved_goals "$numbered" 'all' | wc -l | tr -d ' ')"
eq "approve all but some" "merge-batch 41 42 45 46
dispatch 12	Add the exporter
fix-main 77
audit Open issues with no State label: #33
restart-queue" "$(approved_goals "$numbered" 'All but 2 3')"
eq "approve none" "" "$(approved_goals "$numbered" 'none')"
eq "a reply that names nothing approves nothing" "" "$(approved_goals "$numbered" 'looks good')"
eq "queue stale: old and unfinished" "yes" "$(queue_is_stale 1000000 1010000 'merging PR 41')"
eq "queue not stale: old but finished" "no" "$(queue_is_stale 1000000 1010000 'queue done')"
eq "queue not stale: recent" "no" "$(queue_is_stale 1000000 1003000 'merging PR 41')"
eq "queue not stale: no log" "no" "$(queue_is_stale '' 1000000 '')"
eq "owner decision found" "prices" "$(owner_decision_hit 'Set the Prices for the yearly plan' 'prices
policy')"
eq "owner decision absent" "" "$(owner_decision_hit 'Fix the date parser' 'prices
policy')"
eq "report trimmed per section" "Merged:
#1
#2
(and 1 more)
Blocked:
#9 on the owner" "$(trim_report 'Merged:
#1
#2
#3
Blocked:
#9 on the owner' 2)"

printf '\n# task_tier and agent_model_reason\n'
eq "Explore is a lookup" "lookup" "$(task_tier Explore 'Find config' 'Find where the port is set')"
eq "Plan is hard" "hard" "$(task_tier Plan 'Plan it' 'Plan the cache')"
eq "a short find is a lookup" "lookup" "$(task_tier general-purpose 'Find the parser' 'Find which file parses dates and report the path')"
eq "implement is hard" "hard" "$(task_tier general-purpose 'Add retries' 'Implement retries in the client')"
eq "a long find is routine" "routine" "$(task_tier general-purpose 'Survey' "$(awk 'BEGIN { for (i = 0; i < 130; i++) printf "find word "; }')")"
eq "a summary is routine" "routine" "$(task_tier general-purpose 'Summarize' 'Summarize the release notes in five lines')"
eq "no model on a lookup" "haiku lookup" "$(agent_model_reason Explore 'Find x' 'Find x' '')"
eq "no model on hard work" "opus hard" "$(agent_model_reason general-purpose 'Fix the bug' 'Debug the crash' '')"
eq "opus on a lookup is heavier than needed" "haiku lookup" "$(agent_model_reason Explore 'Find x' 'Find x' opus)"
eq "fable on routine work is heavier than needed" "sonnet routine" "$(agent_model_reason general-purpose 'Summarize' 'Summarize the notes' fable)"
eq "haiku on a lookup is fine" "" "$(agent_model_reason Explore 'Find x' 'Find x' haiku)"
eq "sonnet on routine is fine" "" "$(agent_model_reason general-purpose 'Summarize' 'Summarize the notes' sonnet)"
eq "a lighter model is always fine" "" "$(agent_model_reason general-purpose 'Fix it' 'Debug the crash' haiku)"
eq "opus on hard work is fine" "" "$(agent_model_reason Plan 'Plan it' 'Plan the cache' opus)"
eq "model ranks" "1 2 3 4 0" "$(printf '%s %s %s %s %s' "$(model_rank haiku)" "$(model_rank claude-sonnet-5-5)" "$(model_rank Opus)" "$(model_rank fable)" "$(model_rank '')")"

printf '\n# workflow_model_reason\n'
eq "every call has a model" "" "$(workflow_model_reason 'await agent("a", {model: "haiku"}); await agent("b", { model : "sonnet" })')"
eq "one call without a model" "1" "$(workflow_model_reason 'await agent("a", {model: "haiku"}); await agent("b", {label: "x"})')"
eq "no agents, nothing" "" "$(workflow_model_reason 'return 1')"

printf '\n# status page\n'
fixtures=$(mktemp -d)
mkdir -p "$fixtures/stubs"
printf 'name: Sign in\nstate: done\nissue: #3\nnote: Password and magic link.\n' > "$fixtures/stubs/sign-in.md"
printf 'name: Billing\nstate: blocked\nissue: #9\nnote: Waiting on the payment provider.\n' > "$fixtures/stubs/billing.md"
printf 'state: in progress\n' > "$fixtures/stubs/export.md"
printf '# comment\nDatabase: running\nMail: degraded\n' > "$fixtures/services.txt"
eq "stub_field reads a value" "Sign in" "$(stub_field "$fixtures/stubs/sign-in.md" name)"
eq "stub_field missing key prints nothing" "" "$(stub_field "$fixtures/stubs/sign-in.md" owner)"
page=$(render_status "$fixtures/stubs" "$fixtures/services.txt")
eq "one row per feature, sorted by file" "| Billing | blocked | #9 | Waiting on the payment provider. |
| export | in progress |  |  |
| Sign in | done | #3 | Password and magic link. |" "$(printf '%s\n' "$page" | grep '^| ' | grep -v -e 'Feature' -e 'Service' -e 'Database' -e 'Mail')"
eq "services table" "| Database | running |
| Mail | degraded |" "$(printf '%s\n' "$page" | grep -e '^| Database' -e '^| Mail')"
eq "not-done list leaves out done" "- Billing (blocked)
- export (in progress)" "$(printf '%s\n' "$page" | grep '^- ')"
eq "no services file, no services section" "" "$(render_status "$fixtures/stubs" "$fixtures/none.txt" | grep '^## Services')"
printf 'name: Only\nstate: done\n' > "$fixtures/stubs/billing.md"
printf 'name: Only\nstate: done\n' > "$fixtures/stubs/sign-in.md"
printf 'name: Only\nstate: done\n' > "$fixtures/stubs/export.md"
eq "all done says so" "Nothing. Every feature is done." "$(render_status "$fixtures/stubs" | tail -n 1)"

printf '\n# status check\n'
proj=$(mktemp -d)
cp -R "$root/templates/status" "$proj/status"
check=$(cd "$proj" && sh status/check.sh 2>&1; echo "exit $?")
eq "missing page fails" "STATUS.md is missing: run sh status/build.sh and commit the result.
exit 1" "$check"
(cd "$proj" && sh status/build.sh >/dev/null)
check=$(cd "$proj" && sh status/check.sh 2>&1; echo "exit $?")
eq "fresh page passes" "STATUS.md is current.
exit 0" "$check"
printf 'name: New\nstate: not started\n' > "$proj/status/stubs/new.md"
check=$(cd "$proj" && sh status/check.sh 2>&1; echo "exit $?")
eq "stale page fails" "STATUS.md is stale: run sh status/build.sh and commit the result.
exit 1" "$check"

printf '\n# classify_paths\n'
rules=$(cat "$root/templates/scripts/ci/classes.txt")
eq "app" "app" "$(classify_paths 'src/a.ts' "$rules")"
eq "deep path under src" "app" "$(classify_paths 'src/deep/er/a.ts' "$rules")"
eq "docs" "docs" "$(classify_paths 'README.md' "$rules")"
eq "a status stub is status, not docs" "status" "$(classify_paths 'status/stubs/a.md' "$rules")"
eq "workflow is ci" "ci" "$(classify_paths '.github/workflows/ci.yml' "$rules")"
eq "several classes, sorted, unique" "app docs tests" "$(classify_paths 'src/a.ts
docs/x.md
tests/a_test.py
src/b.ts' "$rules")"
eq "unknown path is other" "other" "$(classify_paths 'weird.bin' "$rules")"
eq "Windows separators are fine" "app" "$(classify_paths 'src\a.ts' "$rules")"
eq "empty input, no classes" "" "$(classify_paths '' "$rules")"

printf '\n# needs_rerun\n'
eq "no overlap merges" "no" "$(needs_rerun 'app' 'docs')"
eq "overlap reruns" "yes" "$(needs_rerun 'app tests' 'data app')"
eq "other on main reruns" "yes" "$(needs_rerun 'app' 'other')"
eq "other on the PR reruns" "yes" "$(needs_rerun 'other' 'docs')"
eq "ci on main reruns" "yes" "$(needs_rerun 'app' 'ci')"
eq "main unchanged merges" "no" "$(needs_rerun 'app' '')"
eq "an unclassified file on the PR merges when main has not moved" "no" "$(needs_rerun 'ci docs other' '')"
eq "blank main classes count as unmoved" "no" "$(needs_rerun 'other' ' ')"

printf '\n# state_label_from_body\n'
body="### State

waiting on owner

### Outcome

Something."
eq "reads the field" "state:waiting-on-owner" "$(state_label_from_body "$body")"
eq "ready" "state:ready" "$(state_label_from_body '### State
Ready')"
eq "after launch" "state:after-launch" "$(state_label_from_body '### State
After launch')"
eq "no field, no label" "" "$(state_label_from_body '### Outcome
x')"
eq "empty response, no label" "" "$(state_label_from_body '### State

_No response_')"
eq "CRLF body" "state:parked" "$(state_label_from_body "$(printf '### State\r\n\r\nparked\r\n')")"

printf '\n# spec_check_reason\n'
eq "src with its spec is fine" "" "$(spec_check_reason 'src/auth.ts
specs/sign-in/spec.md')"
eq "src without a spec is missing" "missing" "$(spec_check_reason 'src/auth.ts
README.md')"
eq "the constitution does not count" "missing" "$(spec_check_reason 'src/auth.ts
specs/constitution.md')"
eq "no src, nothing to check" "" "$(spec_check_reason 'docs/a.md
specs/constitution.md')"
eq "many spec folders warns" "many 2" "$(spec_check_reason 'src/a.ts
specs/sign-in/spec.md
specs/billing/spec.md')"
eq "src that names its spec in the body is fine" "" "$(spec_check_reason 'src/auth.ts' 'Adds the sign-in form.

Spec: specs/sign-in')"
eq "a spec path mentioned in the body counts" "" "$(spec_check_reason 'src/auth.ts' 'See specs/sign-in/spec.md for the flow.')"
eq "a body that names no spec is still missing" "missing" "$(spec_check_reason 'src/auth.ts' 'Adds the sign-in form. Closes #12')"
eq "the constitution named in the body does not count" "missing" "$(spec_check_reason 'src/auth.ts' 'per specs/constitution.md')"

printf '\n# rerun-free classes\n'
eq "the directive names the classes" "docs specs status" "$(rerun_free_classes "$rules")"
eq "no directive, nothing" "" "$(rerun_free_classes 'app src/*')"
eq "the directive is not a class" "app" "$(classify_paths 'src/a.ts' '!rerun-free docs
app src/*')"
eq "main moved only in a free class, no re-run" "no" "$(needs_rerun 'app specs' 'specs docs' 'docs specs status')"
eq "main moved in a free class and the app, re-run" "yes" "$(needs_rerun 'app specs' 'specs app' 'docs specs status')"
eq "ci on main still re-runs" "yes" "$(needs_rerun 'app' 'docs ci' 'docs specs status')"
eq "other on main still re-runs" "yes" "$(needs_rerun 'app' 'docs other' 'docs specs status')"
eq "a spec class" "specs" "$(classify_paths 'specs/sign-in/spec.md' "$rules")"

printf '\n# board mappings\n'
eq "label to state name" "Waiting on owner" "$(state_name_from_label state:waiting-on-owner)"
eq "ready label" "Ready" "$(state_name_from_label state:ready)"
eq "not a state label" "" "$(state_name_from_label bug)"
eq "state name to label" "state:waiting-on-a-service" "$(label_from_state_name 'Waiting on a service')"
eq "round trip" "After launch" "$(state_name_from_label "$(label_from_state_name 'After launch')")"
eq "first state label in a list" "state:parked" "$(state_label_in 'bug, state:parked,task')"
eq "no state label in a list" "" "$(state_label_in 'bug,task')"
eq "status for in progress" "In Progress" "$(status_for 'In progress' false)"
eq "status for ready" "Todo" "$(status_for Ready false)"
eq "status for parked" "Todo" "$(status_for Parked false)"
eq "status for a closed issue is Done whatever the state" "Done" "$(status_for 'In progress' true)"

printf '\n# audit helpers\n'
eq "issues without a state label" "12
15" "$(issues_without_state '12 bug,task
14 state:ready,task
15
16 task,state:parked')"
eq "issue refs, unique, in order" "4
12" "$(issue_refs 'Closes #4 and fixes #12; see #4 again')"
eq "no refs, nothing" "" "$(issue_refs 'no numbers here')"
eq "clean audit says nothing" "" "$(audit_comment '' '')"
eq "missing only" "Open issues with no State label:
- #12
- #15" "$(audit_comment '12
15' '')"
eq "stale only" "Issues still open and labeled ready after their PR merged:
- #4 (merged in #30)" "$(audit_comment '' '30 4')"
eq "both, with a blank line between" "Open issues with no State label:
- #12

Issues still open and labeled ready after their PR merged:
- #4 (merged in #30)" "$(audit_comment '12' '30 4')"
eq "red main comes first" "Main is red and the issue is still open:
- #77

Open issues with no State label:
- #12" "$(audit_comment '12' '' '77')"
eq "red only" "Main is red and the issue is still open:
- #77" "$(audit_comment '' '' '77')"

printf '\n# setup_check_reason and has_crlf\n'
setup_pats=$(cat "$root/templates/scripts/ci/setup-paths.txt")
eq "migration without SETUP.md" "migrations/0002_x.sql" "$(setup_check_reason 'src/a.ts
migrations/0002_x.sql' "$setup_pats")"
eq "migration with SETUP.md is fine" "" "$(setup_check_reason 'migrations/0002_x.sql
SETUP.md' "$setup_pats")"
eq "no setup file, nothing to check" "" "$(setup_check_reason 'src/a.ts
docs/b.md' "$setup_pats")"
eq "a workflow change is not a setup step" "" "$(setup_check_reason '.github/workflows/ci.yml' "$setup_pats")"
eq "a dependency bump is not a setup step" "" "$(setup_check_reason 'package.json' "$setup_pats")"
eq "a migration is a setup step" "migrations/002_x.sql" "$(setup_check_reason 'migrations/002_x.sql' "$setup_pats")"
own_pats="manual docs/setup.md
$setup_pats"
eq "the manual defaults to SETUP.md" "SETUP.md" "$(setup_manual "$setup_pats")"
eq "a manual line names the project's own" "docs/setup.md" "$(setup_manual "$own_pats")"
eq "the project's own manual satisfies the check" "" "$(setup_check_reason 'migrations/0002_x.sql
docs/setup.md' "$own_pats")"
eq "SETUP.md no longer counts when the manual is elsewhere" "migrations/0002_x.sql" "$(setup_check_reason 'migrations/0002_x.sql
SETUP.md' "$own_pats")"
eq "crlf found" "yes" "$(has_crlf "$(printf 'a\r\nb')")"
eq "lf only" "" "$(has_crlf "$(printf 'a\nb')")"

printf '\n# quoted text is text, and nothing waits on input\n'
eq "a multi-line --body with quotes keeps the label after it" "" "$(state_label_reason 'gh issue create --title "Fix chimes" --body "First line.
The setting says "off" here.
Last line." --label state:in-progress')"
eq "a body holding && ; | and ( ) keeps the label after it" "" "$(state_label_reason 'gh issue create --title t --body "Run a && b; then c | d (mostly)." --label state:ready')"
eq "a single-quoted multi-line body keeps the label after it" "" "$(state_label_reason "gh issue create --title t --body 'One.
Two.' --label \"state: in progress\"")"
eq "a multi-line body with no label is still refused" "gh issue create" "$(state_label_reason 'gh issue create --title t --body "One.
Two."')"
eq "an rm inside a quoted substitution is still seen" "rm" "$(delete_reason 'echo "$(rm -rf build)"')"
eq "an rm inside plain quotes is text" "" "$(delete_reason 'git commit -m "rm the old files; && done"')"
eq "a bare cat writing to /dev/null waits forever" "cat >> /dev/null" "$(stdin_wait_reason 'cat >> /dev/null')"
eq "a bare cat waits" "cat" "$(stdin_wait_reason 'cd x && cat')"
eq "read with nothing to read waits" "read answer" "$(stdin_wait_reason 'read answer')"
eq "head with no file waits" "head -5" "$(stdin_wait_reason 'head -5')"
eq "cat of a file is fine" "" "$(stdin_wait_reason 'cat a.txt >> b.txt')"
eq "cat fed by a pipe is fine" "" "$(stdin_wait_reason 'git log | cat')"
eq "cat fed by a redirect is fine" "" "$(stdin_wait_reason 'cat < in.txt')"
eq "cat fed by a heredoc is fine" "" "$(stdin_wait_reason 'cat > f.txt <<EOF
body
EOF')"
eq "tee at the end of a pipe is fine" "" "$(stdin_wait_reason 'make | tee out.log')"
eq "the word cat in a string is fine" "" "$(stdin_wait_reason 'echo "cat" && ls')"
eq "a cd chained to a commit waits for nothing" "" "$(stdin_wait_reason 'cd ../wt && git commit -m hi')"
eq "a short heredoc into a commit is fine" "" "$(stdin_wait_reason 'git -C ../wt commit -F - <<EOF
one line
EOF')"
eq "a heredoc inside a substitution is fine" "" "$(stdin_wait_reason 'gh pr create --body "$(cat <<EOF
body
EOF
)"')"

printf '\n# merging only through the queue\n'
eq "a direct merge" "gh pr merge" "$(direct_merge_reason 'gh pr merge 41 --squash')"
eq "a direct merge after cd" "gh pr merge" "$(direct_merge_reason 'cd ../wt && gh pr merge 41 --merge --delete-branch')"
eq "turning auto-merge off is allowed" "" "$(direct_merge_reason 'gh pr merge 41 --disable-auto')"
eq "the queue itself is not a direct merge" "" "$(direct_merge_reason 'sh scripts/ci/merge-queue.sh --serial 41')"
eq "viewing a pull request is not a merge" "" "$(direct_merge_reason 'gh pr view 41')"
eq "a drain names its mode" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh --drain')"
eq "a drain with more than two numbers is still named" "" "$(batch_merge_reason 'sh scripts/ci/merge-queue.sh --drain 1 2 3')"

printf '\n# drain\n'
. "$root/templates/scripts/ci/batch-lib.sh"
open='41	false	MERGEABLE	green	main
42	false	MERGEABLE	pending	main
43	true	MERGEABLE	green	main
44	false	CONFLICTING	green	main
45	false	MERGEABLE	green	release
46	false	UNKNOWN	green	main
47	false	MERGEABLE	red	main
48	false	MERGEABLE	pending	main'
eq "green, not draft, not conflicting, aimed at main" "41
46" "$(drain_candidates "$open" main)"
eq "a pull request already tried is not picked again" "46" "$(drain_candidates "$open" main '41')"
eq "running ones are counted, drafts and other bases are not" "2" "$(drain_waiting "$open" main)"
eq "nothing open, nothing picked" "" "$(drain_candidates '' main)"
eq "red pull requests get one retry" "47" "$(drain_retry "$open" main '')"
eq "a red pull request already retried is not retried again" "" "$(drain_retry "$open" main '47')"
eq "a conflict needs attention at once" "44	has conflicts with main" "$(drain_attention "$open" main '')"
eq "red again after its retry needs attention" "44	has conflicts with main
47	failed CI twice" "$(drain_attention "$open" main '47')"
eq "drafts and other bases never need attention here" "" "$(drain_attention "43	true	CONFLICTING	red	main
45	false	CONFLICTING	red	release" main '43 45')"

eq "one green with others running: hold" "yes" "$(drain_hold 1 3)"
eq "two green: batch now, never one then the other" "no" "$(drain_hold 2 1)"
eq "three green: batch now" "no" "$(drain_hold 3 4)"
eq "nothing running: merge" "no" "$(drain_hold 1 0)"
eq "nothing green: nothing to hold" "no" "$(drain_hold 0 2)"

printf '\n# check-runs and mergeable_state through REST\n'
eq "no check runs is none" "none" "$(rest_rollup '')"
eq "all success is green" "green" "$(rest_rollup 'success
skipped
neutral')"
eq "one failure is red" "red" "$(rest_rollup 'success
failure')"
eq "a run still going is pending" "pending" "$(rest_rollup 'success
in_progress')"
eq "red beats pending" "red" "$(rest_rollup 'queued
timed_out')"
eq "a cancelled job is not red" "cancelled" "$(rest_rollup 'success
cancelled')"
eq "a failure beside a cancel is red" "red" "$(rest_rollup 'cancelled
failure')"
eq "a cancel still running is pending" "pending" "$(rest_rollup 'cancelled
in_progress')"
eq "a cancelled pull request is re-run" "51" "$(drain_retry "51	false	MERGEABLE	cancelled	main" main '')"
eq "and re-run again the next round: cancelled is waiting, not failing" "51" "$(drain_retry "51	false	MERGEABLE	cancelled	main" main '51')"
eq "a cancelled pull request counts as waiting" "1" "$(drain_waiting "51	false	MERGEABLE	cancelled	main" main '51')"
eq "a cancelled pull request is never set aside" "" "$(drain_attention "51	false	MERGEABLE	cancelled	main" main '51')"
eq "the required check passed on the commit" "passed" "$(required_check "$(printf 'classify\tcompleted\tsuccess\nCI passed\tcompleted\tsuccess')")"
eq "a green run without the required check is not ready" "missing" "$(required_check "$(printf 'classify\tcompleted\tsuccess\napp\tcompleted\tsuccess')")"
eq "the required check still running" "pending" "$(required_check "$(printf 'CI passed\tin_progress\t')")"
eq "the required check failed" "failed" "$(required_check "$(printf 'CI passed\tcompleted\tfailure')")"
eq "a project's own required check" "passed" "$(required_check "$(printf 'all green\tcompleted\tsuccess')" 'all green')"
eq "the summary failing on a cancelled job is not red" "cancelled" "$(rest_rollup_named "$(printf 'app\tcancelled\nclassify\tsuccess\nCI passed\tfailure')")"
eq "a real failure beside a cancel is red" "red" "$(rest_rollup_named "$(printf 'app\tcancelled\ntests\tfailure\nCI passed\tfailure')")"
eq "the summary failing alone is red" "red" "$(rest_rollup_named "$(printf 'app\tsuccess\nCI passed\tfailure')")"
eq "a project's own summary name" "cancelled" "$(rest_rollup_named "$(printf 'web\tcancelled\nall green\tfailure')" 'all green')"
eq "an issue a member closes is carried" "Closes #64" "$(carried_refs 'An emote per title.

Closes #64')"
eq "fixes and resolves are carried as closes, once each" "Closes #12
Closes #13" "$(carried_refs 'Fixes #12, resolves #13 and closes #12')"
eq "a member's spec is carried" "Spec: specs/004-dashboard" "$(carried_refs 'Spec: specs/004-dashboard')"
eq "a member's escape lines ride along whole" "Spec: specs/004-dashboard
Parity: copy only, no logic change
Twin: web/src/a.ts mirrors app/src/a.ts" "$(carried_refs 'Spec: specs/004-dashboard
  Parity: copy only, no logic change
Twin: web/src/a.ts mirrors app/src/a.ts')"
eq "a project names its own escape keys" "Waiver: perf budget" "$(QUEUE_CARRY_KEYS='Waiver' carried_refs 'Waiver: perf budget
Parity: not carried here')"
eq "a batch body starts with the queue's marker" "<!-- merge-queue:batch -->" "$(batch_pr_body "$(printf '41\tA\n')" | head -n 1)"
eq "a batch is known by its marker" "yes" "$(is_batch_body "$(batch_pr_body "$(printf '41\tA\n')")")"
eq "and by the sentence older batches had" "yes" "$(is_batch_body 'One integration run for the pull requests below, merged in this order')"
eq "a branch named batch-something is not a batch" "" "$(is_batch_body 'Carry escape lines into batch bodies. Closes #483')"
eq "the queue finds batches by body, not branch" "0 2" "$(grep -c 'startswith("batch-")' "$root/templates/scripts/ci/merge-queue.sh") $(grep -c 'contains("<!-- merge-queue:batch -->")' "$root/templates/scripts/ci/merge-queue.sh")"
eq "each run's batch branch is its own" "batch-2026-10-15-041200" "$(batch_branch_name 2026-10-15 1 041200)"
eq "and the second that minute" "batch-2026-10-15-041200-2" "$(batch_branch_name 2026-10-15 2 041200)"
eq "a hold label holds" "held by its label" "$(held_reason "$(printf 'bug\nqueue:hold')" '')"
eq "so does the short label" "held by its label" "$(held_reason 'Hold' '')"
eq "and a Queue: hold line" 'held by its "Queue: hold" line' "$(held_reason '' "$(printf 'Fix the chime.\n  Queue: hold until #301 lands')")"
eq "a body that only mentions holding is not held" "" "$(held_reason 'bug' 'We should hold off on the cache.')"
eq "pause for two hours" "7200" "$(( $(pause_until 0 2h) ))"
eq "pause for 45 minutes" "2700" "$(pause_until 0 45m)"
eq "bare minutes" "5400" "$(pause_until 0 90)"
eq "a length it cannot read pauses nothing" "" "$(pause_until 0 soon)"
eq "the drain, a batch and --serial all honour a hold" "3" "$(grep -c 'held_reason\|pr_held "\$pr"' "$root/templates/scripts/ci/merge-queue.sh" | awk '{print ($1 >= 3) ? 3 : $1}')"
eq "the scheduled drain skips while paused or a session drains" "1" "$(grep -c 'vars.QUEUE_PAUSED_UNTIL }}" "\${{ vars.QUEUE_LOCAL_DRAIN_UNTIL' "$root/templates/.github/workflows/queue-drain.yml")"
eq "a release on workflow_run of CI is per merge" "yes" "$(. "$root/scripts/sync/sync-lib.sh"; per_merge_release "$(printf 'on:\n  workflow_run:\n    workflows: [CI]\n    types: [completed]\n    branches: [main]\n')")"
eq "quoted CI too" "yes" "$(. "$root/scripts/sync/sync-lib.sh"; per_merge_release "$(printf 'on:\n  workflow_run:\n    workflows: [\"CI\"]\n')")"
eq "a release that follows Deploy is not" "" "$(. "$root/scripts/sync/sync-lib.sh"; per_merge_release "$(printf 'on:\n  workflow_run:\n    workflows: [Deploy]\n  workflow_dispatch:\n')")"
eq "nor a workflow named CI elsewhere" "" "$(. "$root/scripts/sync/sync-lib.sh"; per_merge_release "$(printf 'name: CI\non:\n  push:\n')")"
eq "the release workflows in deploy.json" "play-internal.yml
app-distribution.yml" "$(release_workflows '{"path": "guard", "releases": ["play-internal.yml", "app-distribution.yml"]}')"
eq "none listed, none started" "" "$(release_workflows '{"path": "guard"}')"
eq "--deploy starts the listed releases when no Deploy run will" "1" "$(grep -c 'Started the release workflow' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the drain runs hosted by default" "1" "$(grep -c "runs-on: \${{ vars.QUEUE_RUNS_ON || 'ubuntu-latest' }}" "$root/templates/.github/workflows/queue-drain.yml")"
eq "and skips itself after a recent drain, or while paused" "2" "$(grep -c 'skipping this one' "$root/templates/.github/workflows/queue-drain.yml")"
eq "the batch checkout links packages only when the lockfiles match" "1" "$(grep -c 'if \[ "\$em_lock" = "\$em_main" \] && \[ -d "\$main_dir/\$d/node_modules" \]' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a stale link is removed, never the packages behind it" "1" "$(grep -c 'cmd //c rmdir' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a member that changes dependencies is installed for" "1" "$(grep -c 'package.json"\*) ensure_modules' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the project's install command can be named" "1" "$(grep -c 'QUEUE_INSTALL_COMMAND:-npm ci' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a lagging pull ref falls back to the branch" "1" "$(grep -c 'fetch -q origin "+refs/heads/$fph_branch:refs/queue/pr-$1"' "$root/templates/scripts/ci/merge-queue.sh")"
eq "and is said as lagging, never 'try again'" "0" "$(grep -c 'try again' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the gate and the batch use the same fetch" "3" "$(grep -c 'fetch_pr_head "' "$root/templates/scripts/ci/merge-queue.sh")"
# A loop whose last command is "[ test ] && cmd" returns 1 when the test is
# false; inside $(...) under set -e that ends the script without a word.
# It did, three times (worktrees.sh close, --serial, the hold scan).
tail_tests=$(cd "$root" && for f in $(git ls-files '*.sh'); do
  awk -v f="$f" '{ l[NR] = $0 } END { for (i = 1; i <= NR; i++) { if (l[i] !~ /\][ \t]*&&/ || l[i] ~ /\|\|/) continue; j = i + 1; while (j <= NR && l[j] ~ /^[ \t]*(#.*)?$/) j++; if (j <= NR && l[j] ~ /^[ \t]*done/) printf "%s:%d\n", f, i } }' "$f"
done)
eq "no loop in any script ends on a bare test" "" "$tail_tests"
eq "the queue never stops without a word, on screen and in its log" "2" "$(grep -c 'stopped (exit \$qe_rc) during: \$queue_step' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the hold scan ends on an if" "1" "$(grep -c 'if \[ -n "\$h_why" \]; then printf' "$root/templates/scripts/ci/merge-queue.sh")"
eq "--serial by hand waits for checks already running" "1" "$(grep -c 'its checks are still running; waiting for them' "$root/templates/scripts/ci/merge-queue.sh")"
eq "and for a pending required check" "1" "$(grep -c 'is still running; waiting for it, then merging' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a drain never waits on one pull request" "2" "$(grep -c '\[ -z "\$QUEUE_IN_DRAIN" \] && \[ -z "\${serial_waited:-}" \]' "$root/templates/scripts/ci/merge-queue.sh")"
eq "--serial waits once for the run its refresh started" "1" "$(grep -c 'serial_refreshed=1' "$root/templates/scripts/ci/merge-queue.sh")"
eq "an unknown mergeable state is read again" "1" "$(grep -c 'while \[ "\$o_mw" = UNKNOWN \]' "$root/templates/scripts/ci/merge-queue.sh")"
eq "CI may read pull requests" "1" "$(grep -c 'pull-requests: read' "$root/templates/.github/workflows/ci.yml")"
eq "the spec check reads the live body" "1" "$(grep -c 'SPEC_TEXT=$(gh api' "$root/templates/.github/workflows/ci.yml")"
eq "a body with neither carries nothing" "" "$(carried_refs 'Just a copy fix.')"
eq "the batch body carries its members' lines" "Carried from the members:

Closes #64
Spec: specs/004-dashboard" "$(batch_pr_body "$(printf '79\tAn emote\n')" 'Closes #64
Spec: specs/004-dashboard
Closes #64' | tail -n 4)"
eq "the Deploy workflow has no placeholder for the sync to fill" "0" "$(grep -cw 'RUNS_ON\|RUN_SHELL' "$root/templates/.github/workflows/deploy.yml")"
eq "the Deploy workflow does not need jq" "0" "$(grep -c 'jq -r\| jq ' "$root/templates/.github/workflows/deploy.yml")"
eq "the queue never reads FETCH_HEAD" "0" "$(grep -c 'rev-parse FETCH_HEAD' "$root/templates/scripts/ci/merge-queue.sh")"
eq "dirty is conflicting" "CONFLICTING" "$(mergeable_word dirty)"
eq "clean is mergeable" "MERGEABLE" "$(mergeable_word clean)"
eq "behind is still mergeable" "MERGEABLE" "$(mergeable_word behind)"
eq "unknown is unknown" "UNKNOWN" "$(mergeable_word unknown)"
eq "empty is unknown" "UNKNOWN" "$(mergeable_word '')"

printf '\n# board calls refused for a rate limit\n'
eq "gh's unknown owner type is a refusal" "yes" "$(board_refusal 'unknown owner type: Pawper')"
eq "a rate limit message is a refusal" "yes" "$(board_refusal 'GraphQL: API rate limit exceeded for user ID 1')"
eq "a secondary limit is a refusal" "yes" "$(board_refusal 'You have exceeded a secondary rate limit')"
eq "a missing field is not" "no" "$(board_refusal 'Project 3 has no State field')"
eq "empty output is not" "no" "$(board_refusal '')"

printf '\n# decisions, one file each\n'
. "$root/templates/scripts/decisions-lib.sh"
eq "table rows become number, date and text" "123	2026-10-13	Voice long lines in chunks.
124	2026-10-13	No affirmation in the meditation." "$(decision_rows '| Decision | Date | What |
|---|---|---|
| D123 | 2026-10-13 | Voice long lines in chunks. |
| D124 | 2026-10-13 | No affirmation in the meditation. |')"
eq "a row without a date" "7		Sign-in is by email link." "$(decision_rows '| D7 | Sign-in is by email link. |')"
eq "a slug from the first words" "voice-long-lines-in-sentence-chunks" "$(decision_slug 'Voice long lines in sentence chunks of about 40 tokens.')"
eq "four-digit names" "0124-no-affirmation.md" "$(decision_name 124 no-affirmation)"
eq "the table is in number order, whatever the file order" "| Decision | Date | What was decided |
|---|---|---|
| D123 | 2026-10-13 | Voice long lines in chunks. |
| D124 | 2026-10-13 | No affirmation in the meditation. |" "$(decision_table "$(decision_file 124 2026-10-13 'No affirmation in the meditation.')
@@@
$(decision_file 123 2026-10-13 'Voice long lines in chunks.')
@@@")"
dd=$(mktemp -d)
(
  cd "$dd" && mkdir -p docs .claude scripts && cp "$root/templates/scripts/decisions.sh" "$root/templates/scripts/decisions-lib.sh" scripts/
  printf '# Brief\n\nIntro.\n\n## Decisions\n\n| Decision | Date | What |\n|---|---|---|\n| D1 | 2026-10-01 | First thing. |\n| D2 | 2026-10-02 | Second thing. |\n\n## After\n\nMore.\n' > docs/product-brief.md
  printf 'migration supabase/migrations/*.sql\ndecision docs/product-brief.md D\n' > .claude/numbering.txt
  sh scripts/decisions.sh split >/dev/null
  ls docs/decisions | tr '\n' ' '; echo
  grep -c '^| D' docs/product-brief.md
  grep -c 'scripts/decisions.sh new' docs/product-brief.md
  grep -c '^## After' docs/product-brief.md
  grep '^decision' .claude/numbering.txt
  sh scripts/decisions.sh list | tail -n 1
) > "$dd.out" 2>&1
eq "split writes one file per decision" "0001-first-thing.md 0002-second-thing.md " "$(sed -n 1p "$dd.out")"
eq "split leaves no decision row in the brief" "0" "$(sed -n 2p "$dd.out")"
eq "split leaves a pointer" "1" "$(sed -n 3p "$dd.out")"
eq "split keeps the rest of the brief" "1" "$(sed -n 4p "$dd.out")"
eq "split numbers decisions by file" "decision docs/decisions/*.md" "$(sed -n 5p "$dd.out")"
eq "list reads them back" "| D2 | 2026-10-02 | Second thing. |" "$(sed -n 6p "$dd.out")"

printf '\n# batches and the drain, sharing pull requests\n'
eq "a batch body's members" "303
305" "$(batch_members "$(batch_pr_body "$(printf '303\tAI fill\n305\tHighlights\n')")")"
eq "the drain drops an open batch's members" "301	false	sha	main" "$(drop_members "$(printf '301\tfalse\tsha\tmain\n303\tfalse\tsha\tmain\n305\tfalse\tsha\tmain')" '303 305')"
eq "and the batch itself" "" "$(drop_members "$(printf '306\tfalse\tsha\tmain')" '303 305 306')"
eq "no batch open, nothing dropped" "301	false	sha	main" "$(drop_members "$(printf '301\tfalse\tsha\tmain')" '')"
eq "jobs waiting on machines are said with a rough time" "6 job(s) queued, 2 of 2 runner(s) busy; about 12 minute(s) at one job per runner. Waiting on machines, not on a failure." "$(queue_eta 6 2 2 4)"
eq "queued with no runner online" "3 job(s) queued and no runner online." "$(queue_eta 3 0 0)"
eq "nothing queued, nothing said" "" "$(queue_eta 0 2 2)"

printf '\n# a batch anchored on the earliest pull request\n'
eq "no conflicts, everyone in" "251 252 253" "$(anchored_group '251 252 253' '' | tr '\n' ' ' | sed 's/ $//')"
eq "the earliest stays in, its conflicts go" "251 254" "$(anchored_group '251 252 253 254' "$(printf '251 252\n251 253')" | tr '\n' ' ' | sed 's/ $//')"
eq "the largest set beside the earliest, not the first that fits" "251 253 254" "$(anchored_group '251 252 253 254' "$(printf '252 253\n252 254')" | tr '\n' ' ' | sed 's/ $//')"
eq "on a tie, the earlier one" "251 252" "$(anchored_group '251 252 253' "$(printf '252 253')" | tr '\n' ' ' | sed 's/ $//')"
eq "one pull request is its own batch" "251" "$(anchored_group '251' '')"
eq "the notice names the files and the fix" "yes" "$(conflict_notice "$(printf 'src/cart.ts\nsrc/a.ts')" 252 | grep -q '#252, which goes into this batch first in:' && conflict_notice 'src/cart.ts' main | grep -q 'Never rebase or force-push' && echo yes)"
eq "conflicts are noticed once per head commit" "1" "$(grep -cF 'grep -qx "$1 $nc_sha" "$nc_seen"' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the queue notices in all three places" "3" "$(grep -c '^ *notify_conflict "\$pr"' "$root/templates/scripts/ci/merge-queue.sh")"

printf '\n# when a green pull request needs a second run\n\'
eq "main moved outside its classes: merge" "merge" "$(rerun_decision no red)"
eq "main moved in its classes and main is green: merge, main's run is the gate" "merge" "$(rerun_decision yes green)"
eq "main is red: re-run" "update" "$(rerun_decision yes red)"
eq "main's newest commit has not finished its run: re-run" "update" "$(rerun_decision yes pending)"
eq "main unreadable: re-run" "update" "$(rerun_decision yes unknown)"
eq "the old rule on request" "update" "$(rerun_decision yes green classes)"

printf '\n# labels over REST, and waiting on a machine\n'
eq "the state label replaces the old one and keeps the rest" '{"labels":["bug","task","state:in-progress"]}' "$(state_labels_json 'bug
state:ready
task' 'state:in-progress')"
eq "no labels yet" '{"labels":["state:ready"]}' "$(state_labels_json '' 'state:ready')"
eq "a quote in a label survives" '{"labels":["say \"hi\"","state:ready"]}' "$(state_labels_json 'say "hi"' 'state:ready')"
eq "all queued is waiting on a machine" "yes" "$(checks_queued_only 'queued
queued
completed')"
eq "one running is waiting on tests" "no" "$(checks_queued_only 'queued
in_progress')"
eq "nothing queued is not" "no" "$(checks_queued_only 'completed')"
eq "queued with no runner online: stop" "stop" "$(runner_stall yes 0)"
eq "queued with a runner online: wait" "" "$(runner_stall yes 1)"
eq "queued and the runners unreadable: say so" "unknown" "$(runner_stall yes unknown)"
eq "running: wait" "" "$(runner_stall no 0)"

printf '\n# serial merges, enforced by the queue\n'
eq "alone with nothing else ready may go" "" "$(serial_refusal '' '')"
eq "a reason always may go" "" "$(serial_refusal '81 82 83' migration)"
eq "others ready and no reason is refused, naming them" "3 other green pull request(s) are ready to land with it (#81 #82 #83); merge them together with --drain (or --batch), or give the reason this one must land alone: --serial N --because migration|conflict|must-land-alone|\"why\"" "$(serial_refusal '81 82 83 ' '')"
eq "the reason goes in the squash title" "Fix the chime (#79) [serial: migration]" "$(serial_title 'Fix the chime' 79 migration)"
eq "no reason is alone" "Fix it (#80) [serial: alone]" "$(serial_title 'Fix it' 80 '')"
eq "three serial merges in an hour are a burst" "Main took 3 serial merges within an hour (reasons: alone, alone, migration). Pull requests that are ready together should land as one batch: sh scripts/ci/merge-queue.sh --drain." "$(serial_bursts "$(printf '3000\tC (#3) [serial: migration]\n2000\tB (#2) [serial: alone]\n1000\tA (#1) [serial: alone]\n500\tMerge pull request #9 from x/batch-1\n')")"
eq "two are not" "" "$(serial_bursts "$(printf '2000\tB (#2) [serial: alone]\n1000\tA (#1) [serial: alone]\n')")"
eq "three spread over a day are not" "" "$(serial_bursts "$(printf '20000\tC [serial: alone]\n10000\tB [serial: alone]\n1000\tA [serial: alone]\n')")"
eq "a conflict names its files" "conflicts with main in web/src/a.ts docs/product-brief.md; resolve it on the branch, then queue it again" "$(conflict_line 'web/src/a.ts
docs/product-brief.md')"
eq "a conflict with no files named still says so" "conflicts with main; resolve it on the branch, then queue it again" "$(conflict_line '')"
eq "the queue waits on the CI workflow's run, not the newest of any" "1" "$(grep -c -- '--workflow "${QUEUE_CI_WORKFLOW:-ci.yml}"' "$root/templates/scripts/ci/merge-queue.sh")"
eq "agent worktrees are a known place, not a stray folder" "Worktrees: 2 besides the main checkout, in 1 folder, and 1 made by Claude Code for dispatched agents in .claude/worktrees." "$(worktree_summary 'worktree C:/r/app
worktree C:/r/app-wt/a
worktree C:/r/app-wt/b
worktree C:/r/app/.claude/worktrees/agent-1')"

printf '\n# the API budget and one queue at a time\n'
eq "plenty left, no wait" "0" "$(rate_wait "4000	2000" 1000)"
eq "under the floor, wait until the reset" "600" "$(rate_wait "120	1600" 1000)"
eq "under the floor but the window has reset" "0" "$(rate_wait "120	900" 1000)"
eq "a custom floor" "0" "$(rate_wait "120	1600" 1000 100)"
eq "unknown budget, no wait" "0" "$(rate_wait '' 1000)"
eq "a reset a second away waits one second" "1" "$(rate_wait "0	1001" 1000)"
eq "a 403 for the rate limit is named" "yes" "$(rate_limit_hit 'HTTP 403: API rate limit exceeded for user ID 1 (https://api.github.com/repos/x/y/actions/runs)')"
eq "a secondary limit too" "yes" "$(rate_limit_hit 'You have exceeded a secondary rate limit')"
eq "another error is not" "no" "$(rate_limit_hit 'HTTP 404: Not Found')"
eq "no error is not" "no" "$(rate_limit_hit '')"
eq "a running drain refuses a second queue" "a --drain started 12 minute(s) ago is still running (pid 4242)" "$(queue_lock_reason "4242	1000	--drain" 1720 yes)"
eq "a lock whose process is gone is free" "" "$(queue_lock_reason "4242	1000	--drain" 1720 no)"
eq "a lock older than three hours is free" "" "$(queue_lock_reason "4242	1000	--batch" 20000 yes)"
eq "no lock is free" "" "$(queue_lock_reason '' 1720 yes)"

printf '\n# the package a file belongs to\n'
roots='.
web
web/packages/ui
tools'
eq "a file in the web app runs from web" "web" "$(nearest_root 'web/src/a.test.ts' "$roots")"
eq "the deepest package wins" "web/packages/ui" "$(nearest_root 'web/packages/ui/b.test.ts' "$roots")"
eq "a file outside every package runs from the root" "." "$(nearest_root 'scripts/x.test.ts' "$roots")"
eq "Windows separators are fine" "web" "$(nearest_root 'web\src\a.test.ts' "$roots")"
eq "a sibling name is not a prefix" "." "$(nearest_root 'webapp/a.test.ts' "$roots")"
eq "no root at all, nothing" "" "$(nearest_root 'a.test.ts' 'web')"

printf '\n# numbering\n'
. "$root/templates/scripts/ci/numbering-lib.sh"
eq "the glob for a kind" "supabase/migrations/*.sql" "$(numbering_glob '# note
migration supabase/migrations/*.sql
seed seed/*.json' migration)"
eq "an unknown kind" "" "$(numbering_glob 'migration m/*.sql' setup)"
eq "migrations in supabase/migrations are found" "supabase/migrations/*.sql" "$(migration_glob_guess 'web/src/a.ts
supabase/migrations/0040_x.sql
supabase/config.toml')"
eq "root migrations are found" "migrations/*.sql" "$(migration_glob_guess 'migrations/0001_init.sql')"
eq "supabase wins when both exist" "supabase/migrations/*.sql" "$(migration_glob_guess 'migrations/0001.sql
supabase/migrations/0002.sql')"
eq "no migrations, no guess" "" "$(migration_glob_guess 'src/a.ts')"
paths='supabase/migrations/0021_chime_volume.sql
supabase/migrations/0022_station_chime_volume.sql
supabase/migrations/README.md
docs/0099_not_a_migration.sql
supabase\migrations\0023_testing_program.sql'
eq "numbers of matching files, padding kept, either slash" "0021
0022
0023" "$(numbers_in "$paths" 'supabase/migrations/*.sql')"
eq "the next free number" "0024" "$(next_free_number "$(numbers_in "$paths" 'supabase/migrations/*.sql')")"
eq "the first number when there are none" "0001" "$(next_free_number '')"
eq "padding follows the widest number" "00008" "$(next_free_number '00007
3')"
eq "two files sharing a number" "0022	0022_a.sql 0022_b.sql" "$(duplicate_numbers 'm/0021_x.sql
m/0022_a.sql
m/0022_b.sql' 'm/*.sql')"
eq "22 and 0022 are the same number" "0022	22_a.sql 0022_b.sql" "$(duplicate_numbers 'm/22_a.sql
m/0022_b.sql' 'm/*.sql')"
eq "no duplicates, nothing" "" "$(duplicate_numbers 'm/0021_x.sql
m/0022_y.sql' 'm/*.sql')"
eq "running task numbers are found" "## 14. Add the exporter
- [ ] 7: Fix the chime
T12) Rename the page
7p. Run the migration" "$(running_task_lines '## 14. Add the exporter
- [ ] 7: Fix the chime
T12) Rename the page
7p. Run the migration
## #231 Add the exporter
- [ ] #232 Fix the chime
Some prose with 3. in the middle')"
eq "issue-numbered tasks pass" "" "$(running_task_lines '## #231 Add the exporter
- [x] #45 Ship it')"
manual=$(cat "$fx/setup-manual.md")
eq "a migration still not run" "0024_station_chimes_off.sql	not yet run" "$(pending_migrations "$manual" 'supabase/migrations/0024_station_chimes_off.sql
src/chimes.ts' 'supabase/migrations/*.sql')"
eq "a migration marked done passes, even with the instruction text" "" "$(pending_migrations "$manual" 'supabase/migrations/0007_schedule_versions.sql' 'supabase/migrations/*.sql')"
eq "a migration the manual never mentions" "0025_new.sql	not in the manual" "$(pending_migrations "$manual" 'supabase/migrations/0025_new.sql' 'supabase/migrations/*.sql')"
eq "no migration added, nothing" "" "$(pending_migrations "$manual" 'src/a.ts' 'supabase/migrations/*.sql')"
eq "a manual line without the extension still counts, and still blocks when not yet run" "0002_profiles.sql	not yet run" "$(pending_migrations '| 0002_profiles | Not yet run |' 'supabase/migrations/0002_profiles.sql' 'supabase/migrations/*.sql')"
eq "a manual line without the extension marked done passes" "" "$(pending_migrations '| 0002_profiles | Done 2026-10-10 |' 'supabase/migrations/0002_profiles.sql' 'supabase/migrations/*.sql')"

printf '\n# decision numbers inside a file\n'
brief='## Decisions

| ID | Decision | Date |
|---|---|---|
| D1 | Repo and board 5 are the source of truth. | 2026-09-25 |
| D2 | One-time price. | 2026-09-26 |
| D55 | Chimes per station. | 2026-10-07 |

The chime (D34) and the price (D38) are referenced here, not defined.
- **D56** Volume per station.
## D57 Wear tiles'
eq "the kind's prefix" "D" "$(numbering_prefix 'migration m/*.sql
decision docs/product-brief.md D' decision)"
eq "a file-name kind has no prefix" "" "$(numbering_prefix 'migration m/*.sql' migration)"
eq "definitions in table rows, bold and headings, not prose" "1
2
55
56
57" "$(id_definitions "$brief" D)"
eq "D10 is not a definition of D1" "10" "$(id_definitions '| D10 | x |' D)"
eq "a word that only starts with the prefix is not a definition" "" "$(id_definitions '- Done 2026-10-05' D)"
eq "no duplicates in a clean brief" "" "$(duplicate_ids "$brief" D)"
eq "two pull requests that both took D55" "D55" "$(duplicate_ids "$brief
| D55 | Another decision. | 2026-10-08 |" D)"
eq "the next free decision" "D58" "$(next_free_id "$(id_definitions "$brief" D)" D)"
eq "the first decision" "D1" "$(next_free_id '' D)"

printf '\n# env-lib\n'
. "$root/templates/scripts/env-lib.sh"
eq "a missing key is appended" "A=1
B=2" "$(env_set 'A=1' B 2)"
eq "an existing key is replaced in place" "# db
A=9
B=2" "$(env_set '# db
A=1
B=2' A 9)"
eq "an export prefix survives" "export A=9" "$(env_set 'export A=1' A 9)"
eq "a key that is a prefix of another is not touched" "AB=1
A=9" "$(env_set 'AB=1' A 9)"
eq "empty text gets the one line" "A=9" "$(env_set '' A 9)"
eq "a password is the asked length" "32" "$(random_password 32 | tr -d '\n' | wc -c | tr -d ' ')"
eq "a password is letters and digits only" "0" "$(random_password 32 | tr -d 'A-Za-z0-9\n' | wc -c | tr -d ' ')"
eq "two passwords differ" "no" "$([ "$(random_password)" = "$(random_password)" ] && echo yes || echo no)"

printf '\n# template refresh\n'
. "$root/scripts/sync/sync-lib.sh"
owned='# comment
scripts/ci/merge-queue.sh
.github/workflows/audit.yml
default scripts/ci/task-files.txt'
eq "plugin-owned paths" "scripts/ci/merge-queue.sh
.github/workflows/audit.yml" "$(owned_paths "$owned")"
eq "config with defaults" "scripts/ci/task-files.txt" "$(default_paths "$owned")"
eq "secrets and variables a workflow reads" "secrets PROJECT_TOKEN, QUEUE_TOKEN; variables BOARD_NUMBER" "$(workflow_needs 'token: ${{ secrets.QUEUE_TOKEN }}
env: ${{ secrets.PROJECT_TOKEN }} ${{ vars.BOARD_NUMBER }} ${{ secrets.QUEUE_TOKEN }}')"
eq "a workflow that reads none says nothing" "" "$(workflow_needs 'run: echo hi')"
eq "runs-on from a project workflow" "[self-hosted, windows]" "$(ci_runs_on 'jobs:
  a:
    runs-on: [self-hosted, windows]
  b:
    runs-on: ubuntu-latest')"
eq "a RUNS_ON placeholder is not a value" "" "$(ci_runs_on '    runs-on: RUNS_ON')"
eq "an expression is never copied as a runner" "[self-hosted, windows]" "$(ci_runs_on '    runs-on: ${{ fromJSON(needs.plan.outputs.runner) }}
    runs-on: [self-hosted, windows]')"
owned_txt='feature core
scripts/ci/lib.sh
feature board
scripts/state.sh
scripts/board.sh
feature deploy
scripts/deploy-setup.sh
default scripts/ci/classes.txt'
feats=$(owned_features "$owned_txt")
eq "owned paths skip feature lines" "scripts/ci/lib.sh
scripts/state.sh
scripts/board.sh
scripts/deploy-setup.sh" "$(owned_paths "$owned_txt")"
eq "a path's feature" "board" "$(feature_of "$feats" scripts/board.sh)"
eq "a feature is not used for one stray file, only its anchor" "core" "$(adopted_features "$feats" 'scripts/ci/lib.sh
scripts/board.sh')"
eq "features a project uses: their anchors are here" "core deploy" "$(adopted_features "$feats" 'scripts/ci/lib.sh
scripts/deploy-setup.sh')"
eq "a project with its own board tools has none of the plugin's: not used" "core" "$(adopted_features "$feats" 'scripts/ci/lib.sh
scripts/board-state.sh')"
eq "the shell from a project workflow, quotes kept" "'C:\\PROGRA~1\\Git\\bin\\bash.exe -eo pipefail {0}'" "$(ci_shell "defaults:
  run:
    shell: 'C:\\PROGRA~1\\Git\\bin\\bash.exe -eo pipefail {0}'")"
eq "a RUN_SHELL placeholder is not a value" "" "$(ci_shell '    shell: RUN_SHELL')"
eq "a Windows shell path is filled with its backslashes intact" "    shell: 'C:\\PROGRA~1\\Git\\bin\\bash.exe -eo pipefail {0}'" "$(fill_placeholder '    shell: RUN_SHELL' RUN_SHELL "'C:\\PROGRA~1\\Git\\bin\\bash.exe -eo pipefail {0}'")"
eq "a placeholder inside a longer name is left alone" "vars.DEPLOY_RUNS_ON and [self-hosted]" "$(fill_placeholder 'vars.DEPLOY_RUNS_ON and RUNS_ON' RUNS_ON '[self-hosted]')"
eq "an ampersand in the value is literal" "runs-on: a & b" "$(fill_placeholder 'runs-on: RUNS_ON' RUNS_ON 'a & b')"
eq "every occurrence on a line is filled" "x [self-hosted] y [self-hosted]" "$(fill_placeholder 'x RUNS_ON y RUNS_ON' RUNS_ON '[self-hosted]')"
eq "lines without the name are untouched" "a
b" "$(fill_placeholder 'a
b' RUNS_ON z)"
eq "a backspace byte is a control byte" "yes" "$(control_bytes "$(printf 'shell: C:\bin')")"
eq "tabs and newlines are not" "no" "$(control_bytes "$(printf 'a\tb\nc')")"
eq "a Windows checkout is the same text" "yes" "$(same_text "$(printf 'a\r\nb\r\n')" "$(printf 'a\nb')")"
eq "a changed line is not" "no" "$(same_text 'a
b' 'a
c')"
tplyml='name: CI
on: [push]
jobs:
  classify:
    runs-on: x
  numbering-check:
    runs-on: x
  ci-passed:
    name: CI passed
    needs: [classify]'
projyml='name: CI
jobs:
  classify:
    runs-on: x
  ci-passed:
    runs-on: x
env:
  numbering-check: not a job'
eq "jobs a workflow defines" "classify
numbering-check
ci-passed" "$(workflow_jobs "$tplyml")"
eq "jobs the project's ci.yml lacks" "numbering-check" "$(missing_jobs "$tplyml" "$projyml")"
eq "lines the project's file lacks, comments ignored" "tasks.md merge=union" "$(missing_lines '# comment
* text=auto eol=lf
tasks.md merge=union' '* text=auto eol=lf')"

eq "a ci.yml with one job per rule is reported" "classify
line-endings
status-page" "$(split_checks "$(printf 'jobs:\n  classify:\n    x: 1\n  line-endings:\n    x: 1\n  status-page:\n    x: 1\n  app:\n    x: 1\n')")"
eq "a ci.yml with one checks job is not" "" "$(split_checks "$(printf 'jobs:\n  checks:\n    x: 1\n  app:\n    x: 1\n')")"
eq "the template itself is not" "" "$(split_checks "$(cat "$root/templates/.github/workflows/ci.yml")")"
eq "sync points a split ci.yml, and one without pull-requests: read, at the migration page" "2" "$(grep -c 'plugin/CI-MIGRATION.md' "$root/scripts/sync/sync-templates.sh")"
eq "the migration page ships with the plugin" "yes" "$([ -f "$root/CI-MIGRATION.md" ] && echo yes || echo no)"

printf '\n# the CI template is three jobs on a pull request\n'
ciy=$(cat "$root/templates/.github/workflows/ci.yml")
eq "its jobs" "checks
app
ci-passed
full
report-red
report-green" "$(workflow_jobs "$ciy")"
eq "CI passed waits on checks and app" "1" "$(printf '%s\n' "$ciy" | grep -c 'needs: \[checks, app\]')"
eq "one checkout in checks, one in app, one in full" "3" "$(printf '%s\n' "$ciy" | grep -c 'uses: actions/checkout@v4')"
eq "a newer push cancels an older pull request run" "1" "$(printf '%s\n' "$ciy" | grep -c 'cancel-in-progress: true')"
eq "main pushes are each their own group" "1" "$(printf '%s\n' "$ciy" | grep -c "pull_request.number || github.sha")"
eq "every rule script still runs" "7" "$(for f in classify.sh line-endings.sh status/check.sh numbering-check.sh spec-check.sh setup-check.sh shared-check.sh; do printf '%s\n' "$ciy" | grep -q "$f" && echo x; done | grep -c x)"
eq "the env check still runs" "1" "$(printf '%s\n' "$ciy" | grep -c 'client-env-check.sh')"

printf '\n# set -e never swallows a return code\n'
eq "no bare msg=\$(f); code=\$? in the queue" "0" "$(grep -c '=\$([^)]*); *code=\$?' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a pending run says it is waiting, in both waits" "2" "$(grep -cF 'code=0; msg=$(diagnose "$run_id") || code=$?' "$root/templates/scripts/ci/merge-queue.sh")"
eq "the drain drops what settling merged or closed" "1" "$(grep -c 'drop_members "$listed" "$members $settled"' "$root/templates/scripts/ci/merge-queue.sh")"
eq "a batch skips a pull request already merged" "1" "$(grep -c '"skipped" "already merged"' "$root/templates/scripts/ci/merge-queue.sh")"
eq "settled batch and its members leave the list" "301	false	sha	main" "$(drop_members "$(printf '301\tfalse\tsha\tmain\n320\tfalse\tsha\tmain\n328\tfalse\tsha\tmain')" ' 328 320')"
eq "a batch of one merges serially" "1" "$(grep -c 'merging it serially instead of opening a batch of one' "$root/templates/scripts/ci/merge-queue.sh")"
eq "worktrees.sh never stops without a word" "1" "$(grep -c 'stopped with exit \$rc at' "$root/templates/scripts/worktrees.sh")"
eq "no loop in worktrees.sh ends on a bare test" "0" "$(grep -c '^ *\[ [^]]*\] && printf' "$root/templates/scripts/worktrees.sh")"
eq "close says a pull request was already closed" "1" "$(grep -c 'was already closed; added the reason' "$root/templates/scripts/worktrees.sh")"
eq "close reads and closes over REST" "0" "$(grep -c 'gh pr view\|gh pr close' "$root/templates/scripts/worktrees.sh")"


printf '\n# what an agent did after a refusal\n'
. "$root/hooks/scripts/resolution-lib.sh"
eq "moved the file aside: followed" "followed" "$(resolution_of block-delete Bash 'git mv a.txt aside/a.txt')"
eq "deleted it through Python: a possible workaround" "workaround" "$(resolution_of block-delete Bash "python -c 'import os; os.remove(\"a\")'")"
eq "find -delete is a workaround too" "workaround" "$(resolution_of block-delete Bash 'find . -name x -delete')"
eq "an unrelated command says nothing" "" "$(resolution_of block-delete Bash 'ls -la')"
eq "asking the person settles any refusal" "asked" "$(resolution_of block-force-push AskUserQuestion '')"
eq "a plain push after a refused force push: followed" "followed" "$(resolution_of block-force-push Bash 'git push origin feature')"
eq "a plus-refspec push: a workaround" "workaround" "$(resolution_of block-force-push Bash 'git push origin +feature')"
eq "merging over the API after a refused gh pr merge: a workaround" "workaround" "$(resolution_of require-batch-merge Bash 'gh api -X PUT repos/o/r/pulls/12/merge')"
eq "through the queue: followed" "followed" "$(resolution_of require-batch-merge Bash 'sh scripts/ci/merge-queue.sh --drain')"
eq "writing STATUS.md by redirect: a workaround" "workaround" "$(resolution_of block-generated-page Bash 'echo x >> STATUS.md')"
eq "rebuilding it: followed" "followed" "$(resolution_of block-generated-page Bash 'sh status/build.sh')"
eq "one test file after a refused sweep: followed" "followed" "$(resolution_of block-full-test-sweep Bash 'npx vitest run src/a.test.ts')"
eq "an issue made over the API without a State: a workaround" "workaround" "$(resolution_of require-state-label Bash 'gh api -X POST repos/o/r/issues -f title=x')"
eq "an agent dispatched again: followed" "followed" "$(resolution_of require-agent-model Agent '')"
eq "the feed, newest first, open while unsettled" "t3	block-delete	open
t2	block-delete	workaround
t1	block-force-push	followed" "$(resolution_feed "$(printf 't1\tblock-force-push\ts\ta\nt2\tblock-delete\ts\tb\nt3\tblock-delete\ts\tc')" "$(printf 'x\ta\tblock-force-push\ts\tfollowed\nx\tb\tblock-delete\ts\tworkaround')")"
eq "a hook line from before ids is keyed by its time" "t0	block-delete	followed" "$(resolution_feed "$(printf 't0\tblock-delete')" "$(printf 'x\tt0\tblock-delete\ts\tfollowed')")"
eq "every refusing hook logs, and the watcher is registered three times" "9 3" "$(grep -l 'refusal-log.sh' "$root"/hooks/scripts/block-*.sh "$root"/hooks/scripts/require-*.sh | wc -l | tr -d ' ') $(grep -c watch-resolution "$root/hooks/hooks.json")"
printf '\n# runner watch\n'
runs=$(printf '11\tCI\tfeature\tqueued\t1000\n12\tCI\tmain\tqueued\t1500\n13\tCI\tother\tin_progress\t100\n14\tCI\tx\tqueued\t1900\n')
eq "runs queued past ten minutes, oldest first" "11	CI	feature	16
12	CI	main	8" "$(stuck_runs "$runs" 2000 5)"
eq "nothing stuck" "" "$(stuck_runs "$runs" 1100 10)"
eq "an offline runner and a lone online one" "Runner build-2 is offline.
Only 1 of 2 self-hosted runner(s) online; one runner makes every job wait for the last." "$(runner_problems "$(printf 'build-1\tonline\tfalse\nbuild-2\toffline\tfalse\n')")"
eq "two online runners are fine" "" "$(runner_problems "$(printf 'build-1\tonline\ttrue\nbuild-2\tonline\tfalse\n')")"
eq "no runners listed, nothing said" "" "$(runner_problems '')"

printf '\n# deploys: keeping the host'"'"'s build CPU down\n'
. "$root/templates/scripts/ci/deploy-lib.sh"
eq "app code ships" "yes" "$(ships_path 'src/app/page.tsx' .)"
eq "a doc does not ship" "no" "$(ships_path 'docs/plan.md' .)"
eq "a spec does not ship" "no" "$(ships_path 'specs/001-core/spec.md' .)"
eq "Markdown anywhere does not ship" "no" "$(ships_path 'src/README.md' .)"
eq "a test file does not ship" "no" "$(ships_path 'src/ui/mark.test.tsx' .)"
eq "the tests folder does not ship" "no" "$(ships_path 'tests/unit/a.ts' .)"
eq "supabase does not ship" "no" "$(ships_path 'supabase/migrations/0004.sql' .)"
eq "workflows do not ship" "no" "$(ships_path '.github/workflows/ci.yml' .)"
eq "in a monorepo, the app folder ships" "yes" "$(ships_path 'web/src/page.tsx' web)"
eq "in a monorepo, another folder does not" "no" "$(ships_path 'android/app/Main.kt' web)"
eq "in a monorepo, the app's own tests do not" "no" "$(ships_path 'web/tests/a.test.ts' web)"
eq "a sibling folder with the same prefix does not" "no" "$(ships_path 'webapp/src/a.ts' web)"
eq "the app's package file ships" "yes" "$(ships_path 'package.json' .)"
eq "only docs and specs changed: skip" "skip" "$(deploy_skip 'docs/a.md
specs/x/spec.md
STATUS.md' .)"
eq "one app file among docs: build" "build" "$(deploy_skip 'docs/a.md
src/lib/x.ts' .)"
eq "nothing changed: skip" "skip" "$(deploy_skip '' .)"
eq "an unknown last deploy builds" "build" "$(deploy_throttle '' 5000 60)"
eq "an hour after the last deploy builds" "build" "$(deploy_throttle 1000 4600 60)"
eq "twenty minutes after waits forty" "wait 40" "$(deploy_throttle 1000 2200 60)"
eq "a custom interval" "wait 10" "$(deploy_throttle 1000 1600 20)"
eq "runner and secrets: the runner path" "runner" "$(deploy_path yes yes yes)"
eq "secrets but no runner: a Vercel build on a schedule" "vercel" "$(deploy_path yes no yes)"
eq "no secrets: the guard" "guard" "$(deploy_path yes yes no)"
eq "not on Vercel: none" "none" "$(deploy_path no yes yes)"
eq "only Windows runners, hosted minutes: a Vercel build on a schedule" "vercel" "$(deploy_path yes no yes yes)"
eq "only Windows runners, no hosted minutes: the guard, which needs no workflow" "guard" "$(deploy_path yes no yes no)"
eq "a Linux runner and no hosted minutes: the runner path" "runner" "$(deploy_path yes yes yes no)"
eq "the first runner that is not Windows" '["self-hosted","Linux"]' "$(runner_os_pick "$(printf 'Windows\tself-hosted,Windows\nLinux\tself-hosted,Linux')")"
eq "macOS counts" '["self-hosted","macOS"]' "$(runner_os_pick "$(printf 'macOS\tself-hosted')")"
eq "only Windows runners, no pick" "" "$(runner_os_pick "$(printf 'Windows\ta\nWindows\tb')")"
eq "no runners, no pick" "" "$(runner_os_pick '')"
eq "a project's own never-ships folder" "no" "$(ships_path 'packs/level-1.json' . 'packs scripts')"
eq "its nested files too" "no" "$(ships_path 'scripts/gen/x.mjs' . 'packs scripts/')"
eq "a folder that only starts the same still ships" "yes" "$(ships_path 'packsize/a.ts' . 'packs')"
eq "the extra folders apply inside the app's folder" "no" "$(ships_path 'web/packs/a.json' web 'packs')"
eq "the skip decision passes them on" "skip" "$(deploy_skip 'packs/a.json
docs/b.md' . 'packs')"
eq "a JSON array's words" "packs scripts" "$(json_words '{"path": "guard", "neverShips": ["packs", "scripts"]}' neverShips)"
eq "an empty array" "" "$(json_words '{"neverShips": []}' neverShips)"
eq "a missing key" "" "$(json_words '{"path": "guard"}' neverShips)"
eq "a string" "web" "$(json_string '{"path": "runner", "appRoot": "web"}' appRoot)"
eq "a number" "90" "$(json_number '{"intervalMinutes": 90}' intervalMinutes)"
eq "a zero interval still waits half an hour before calling main behind" "" "$(deploy_health guard abc def 1000 3000 0 '')"
eq "a fallback to a Vercel build is said, even with main deployed" "Deploys: the last deploy fell back to a build on Vercel because the runner build failed, so it billed Vercel build minutes. Open the Deploy workflow's last run, job build-on-runner." "$(deploy_health runner abc abc '' 9000 60 fellback)"
eq "and then says so" "Deploys: main has changes waiting 65 minutes that are not in production (the interval is 0); check the Deploy workflow and the runner." "$(deploy_health guard abc def 1000 4900 0 '')"
eq "hourly" "17 * * * *" "$(interval_cron 60)"
eq "every three hours" "17 */3 * * *" "$(interval_cron 180)"
eq "every thirty minutes" "*/30 * * * *" "$(interval_cron 30)"
eq "never more often than five minutes" "*/5 * * * *" "$(interval_cron 1)"
eq "from the root, no way back" "" "$(rel_to_root .)"
eq "from web, one level" "../" "$(rel_to_root web)"
eq "from apps/web, two" "../../" "$(rel_to_root apps/web/)"
eq "Git deploys off is scheduled" "scheduled" "$(guard_kind '{"git": {"deploymentEnabled": false}}')"
eq "the plugin's ignore step" "plugin" "$(guard_kind '{"ignoreCommand": "sh ../scripts/ci/vercel-ignore.sh"}')"
eq "a HEAD^ diff is hand-written" "handwritten" "$(guard_kind '{"git": {"deploymentEnabled": {"main": true}}, "ignoreCommand": "git diff --quiet HEAD^ HEAD -- ."}')"
eq "crons only is no guard" "none" "$(guard_kind '{"crons": [{"path": "/api/x"}]}')"
eq "in step, nothing to say" "" "$(deploy_health runner abc abc '' 9000 60 success)"
eq "a failed scheduled deploy is said" "Deploys: the last scheduled deploy failed; main is not reaching production. Open the Deploy workflow's last run." "$(deploy_health runner abc def 1000 9000 60 failure)"
eq "nothing recorded on a scheduled path is said" "Deploys: no deploy is recorded yet; run the Deploy workflow once from the Actions tab." "$(deploy_health vercel abc '' '' 9000 60 '')"
eq "nothing recorded on the guard is silent" "" "$(deploy_health guard abc '' '' 9000 60 '')"
eq "changes waiting past twice the interval are said" "Deploys: main has changes waiting 150 minutes that are not in production (the interval is 60); check the Deploy workflow and the runner." "$(deploy_health runner abc def 1000 10000 60 success)"
eq "changes waiting under twice the interval are not" "" "$(deploy_health runner abc def 1000 5000 60 success)"
eq "no deploy path, nothing" "" "$(deploy_health none abc def 1000 99999 60 failure)"

# The ignore step and the setup, run for real in a throwaway repository.
dt=$(mktemp -d)
(
  cd "$dt" && git init -q -b main && git config user.email t@t && git config user.name t && git config core.autocrlf false && git config core.safecrlf false
  mkdir -p scripts/ci web/src docs && cp "$root/templates/scripts/ci/deploy-lib.sh" "$root/templates/scripts/ci/vercel-ignore.sh" scripts/ci/
  echo a > web/src/a.ts && echo d > docs/d.md && git add -A && GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' git commit -q -m one
  first=$(git rev-parse HEAD)
  echo d2 > docs/d.md && git commit -qam docs
  cd web
  VERCEL_GIT_COMMIT_REF=main VERCEL_GIT_PREVIOUS_SHA=$first sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "docs:$?"
  echo b > src/a.ts && git commit -qam app
  VERCEL_GIT_COMMIT_REF=main VERCEL_GIT_PREVIOUS_SHA=$first sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "app:$?"
  VERCEL_GIT_COMMIT_REF=feature VERCEL_GIT_PREVIOUS_SHA=$first sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "branch:$?"
  now=$(git rev-parse HEAD)
  VERCEL_GIT_COMMIT_REF=main VERCEL_GIT_PREVIOUS_SHA=$now sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "same:$?"
  echo c > src/a.ts && git commit -qam app2
  VERCEL_GIT_COMMIT_REF=main VERCEL_GIT_PREVIOUS_SHA=$now DEPLOY_INTERVAL_MINUTES=60 sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "throttled:$?"
  VERCEL_GIT_COMMIT_REF=main VERCEL_GIT_PREVIOUS_SHA=$now sh ../scripts/ci/vercel-ignore.sh >/dev/null; echo "no-throttle:$?"
) 2>/dev/null | grep -E "^[a-z-]+:[0-9]$" > "$dt.out"
eq "the ignore step skips docs-only since the last deploy" "docs:0" "$(sed -n 1p "$dt.out")"
eq "the ignore step builds an app change since the last deploy, not only the last commit" "app:1" "$(sed -n 2p "$dt.out")"
eq "the ignore step skips any branch but main" "branch:0" "$(sed -n 3p "$dt.out")"
eq "the ignore step skips when nothing changed" "same:0" "$(sed -n 4p "$dt.out")"
eq "with DEPLOY_INTERVAL_MINUTES=60 the ignore step throttles a deploy under an hour after the last" "throttled:0" "$(sed -n 5p "$dt.out")"
eq "by default there is no throttle, so the day's last merge ships" "no-throttle:1" "$(sed -n 6p "$dt.out")"
if command -v node >/dev/null 2>&1; then
  (
    cd "$dt" && mkdir -p .github/workflows && cp "$root/templates/.github/workflows/deploy.yml" .github/workflows/ && mkdir -p scripts && cp "$root/templates/scripts/deploy-setup.sh" scripts/
    printf '{\n  "crons": [{"path": "/api/cron/cleanup", "schedule": "17 10 * * *"}]\n}\n' > web/vercel.json
    PATH_SAVE=$PATH; sh scripts/deploy-setup.sh guard web 90 >/dev/null 2>&1; echo "guard:$?"
    node -e 'const j=require("./web/vercel.json"); console.log(JSON.stringify([j.crons.length, j.git.deploymentEnabled.main, j.git.deploymentEnabled["*"], j.ignoreCommand]))'
    DEPLOY_NEVER_SHIPS="packs scripts" DEPLOY_HOSTED=yes sh scripts/deploy-setup.sh runner web 180 >/dev/null 2>&1; echo "runner:$?"
    node -e 'const j=require("./web/vercel.json"); console.log(JSON.stringify([j.crons.length, j.git.deploymentEnabled, j.ignoreCommand === undefined]))'
    grep -o 'cron: "[^"]*"' .github/workflows/deploy.yml
    tr -d ' \n' < .claude/deploy.json | sed 's/"_comment":"[^"]*",//'; echo
  ) 2>/dev/null > "$dt.setup"
  eq "the setup writes the guard and keeps the crons" "guard:0
[1,true,false,\"sh ../scripts/ci/vercel-ignore.sh\"]" "$(sed -n 1,2p "$dt.setup")"
  eq "the setup turns Git deploys off for the runner path and drops the ignore step" "runner:0
[1,false,true]" "$(sed -n 3,4p "$dt.setup")"
  eq "the setup never edits the Deploy workflow" 'cron: "17 * * * *"' "$(sed -n 5p "$dt.setup")"
  eq "the setup records the path, the folder, the interval and the never-ships folders" '{"path":"runner","appRoot":"web","intervalMinutes":180,"neverShips":["packs","scripts"]}' "$(sed -n 6p "$dt.setup")"
fi
mv "$dt" "$dt.done" 2>/dev/null || true

printf '\n# owner console (node)\n'
if command -v node >/dev/null 2>&1; then
  if node --test --test-reporter tap "$root"/console/test/*.test.js >"$root/tests/console.log" 2>&1; then
    node_count=$(sed -n 's/^# pass \([0-9]*\).*/\1/p' "$root/tests/console.log" | tr -d '\r')
    pass=$((pass + ${node_count:-0}))
    printf 'ok    %s console tests\n' "${node_count:-0}"
  else
    fail=$((fail + 1))
    printf 'FAIL  console tests, see tests/console.log\n'
    grep -E '^not ok|^# (fail|pass)' "$root/tests/console.log"
  fi
  mv "$root/tests/console.log" "$root/tests/console.log.last"
else
  printf 'skip  node is not installed, so the console tests did not run\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
