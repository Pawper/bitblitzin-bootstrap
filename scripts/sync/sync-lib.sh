#!/bin/sh
# Pure helpers for the template refresh. Text in, text out.

# owned_paths OWNED
# OWNED is the text of templates/OWNED.txt. Print the plugin-owned paths,
# one per line.
owned_paths() {
  printf '%s\n' "$1" | tr -d '\r' | awk 'NF && $1 !~ /^#/ && $1 != "default" { print $1 }'
}

# default_paths OWNED
# The config files with defaults: added when missing, never replaced.
default_paths() {
  printf '%s\n' "$1" | tr -d '\r' | awk '$1 == "default" && NF >= 2 { print $2 }'
}

# same_text A B
# "yes" when two texts are equal ignoring carriage returns and a trailing
# newline, "no" otherwise. A Windows checkout is not a change.
same_text() {
  st_a=$(printf '%s' "$1" | tr -d '\r')
  st_b=$(printf '%s' "$2" | tr -d '\r')
  if [ "$st_a" = "$st_b" ]; then echo yes; else echo no; fi
}

# workflow_jobs YAML
# The job names a workflow defines: keys indented two spaces under "jobs:".
workflow_jobs() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^jobs:[ \t]*$/ { in_jobs = 1; next }
    /^[^ \t#]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[ \t]*$/ { k = $1; sub(/:$/, "", k); print k }'
}

# missing_jobs TEMPLATE_YAML PROJECT_YAML
# Jobs the template workflow has that the project's copy does not. The
# project owns its ci.yml, so these are reported, not added.
missing_jobs() {
  mj_have=$(workflow_jobs "$2")
  workflow_jobs "$1" | while IFS= read -r mj_j; do
    printf '%s\n' "$mj_have" | grep -qxF "$mj_j" || printf '%s\n' "$mj_j"
  done
}

# missing_lines TEMPLATE PROJECT
# Lines of a template file (not comments, not blank) that the project's
# copy lacks, such as an attribute in .gitattributes or a path in
# .gitignore. Reported, not added.
missing_lines() {
  ml_have=$(printf '%s\n' "$2" | tr -d '\r')
  printf '%s\n' "$1" | tr -d '\r' | awk 'NF && $0 !~ /^[ \t]*#/' | while IFS= read -r ml_l; do
    printf '%s\n' "$ml_have" | grep -qxF "$ml_l" || printf '%s\n' "$ml_l"
  done
}

# workflow_needs TEXT
# The secrets and variables a workflow reads, from its ${{ secrets.X }} and
# ${{ vars.X }} expressions: one line, "secrets A, B; variables C", or
# nothing when it reads none. The sync prints it for each workflow it
# adds, so the owner knows what to set before the first run.
workflow_needs() {
  wn_s=$(printf '%s\n' "$1" | grep -o 'secrets\.[A-Z0-9_]*' | sed 's/secrets\.//' | sort -u | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
  wn_v=$(printf '%s\n' "$1" | grep -o 'vars\.[A-Z0-9_]*' | sed 's/vars\.//' | sort -u | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
  [ -n "$wn_s" ] && printf 'secrets %s' "$wn_s"
  [ -n "$wn_s" ] && [ -n "$wn_v" ] && printf '; '
  [ -n "$wn_v" ] && printf 'variables %s' "$wn_v"
  { [ -n "$wn_s" ] || [ -n "$wn_v" ]; } && echo
  return 0
}

# ci_runs_on TEXT
# The first "runs-on:" value in a workflow, as written ("ubuntu-latest" or
# "[self-hosted, windows]"), or nothing when it is absent or still the
# RUNS_ON placeholder. The sync copies it into a workflow it adds.
ci_runs_on() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^[ \t]*runs-on:[ \t]*//p' | sed 's/[ \t]*#.*//; s/[ \t]*$//' | awk '$0 != "" && $0 != "RUNS_ON" { print; exit }'
}

# ci_shell TEXT
# The first "shell:" value in a workflow, quotes kept, or nothing when it
# is absent or still the RUN_SHELL placeholder.
ci_shell() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^[ \t]*shell:[ \t]*//p' | sed 's/[ \t]*$//' | awk '$0 != "" && $0 != "RUN_SHELL" { print; exit }'
}

# fill_placeholder TEXT NAME VALUE
# TEXT with every occurrence of NAME replaced by VALUE, literally: VALUE
# goes in through the environment, never through awk -v or a format
# string, which both turn "\b" into a backspace byte; and the replacement
# is by position, never gsub, so "&" and backslashes in VALUE are kept.
# A Windows shell path once lost its backslashes this way and GitHub
# refused the workflow.
fill_placeholder() {
  FP_NAME=$2 FP_VALUE=$3 awk '
    BEGIN { name = ENVIRON["FP_NAME"]; val = ENVIRON["FP_VALUE"]; n = length(name) }
    {
      line = $0; out = ""
      while (n > 0 && (i = index(line, name)) > 0) { out = out substr(line, 1, i - 1) val; line = substr(line, i + n) }
      print out line
    }' <<FPEOF
$1
FPEOF
}

# control_bytes TEXT
# Print "yes" when TEXT holds a control character other than tab or
# newline, which no workflow file should; "no" otherwise. The sync checks
# a workflow it wrote before committing it.
control_bytes() {
  if printf '%s' "$1" | LC_ALL=C tr -d '\011\012\015' | LC_ALL=C grep -q '[[:cntrl:]]'; then echo yes; else echo no; fi
}
