#!/bin/sh
# The design check, in one CI step: the generated design files are current,
# no UI file gained a literal colour, size or font, and every screen pair
# the change touches references the same type roles on both platforms.
# Usage: sh scripts/ci/design-check.sh BASE HEAD      (CI; SPEC_TEXT or
#        PR_TEXT holds the pull request title and body)
#    or: sh scripts/ci/design-check.sh                (the working tree
#        against origin/main, by hand)
# Config: scripts/ci/design-ui.txt lists the UI file globs the literal
# check reads (default: src/**/*.tsx, *.css, android **/*.kt, ios **/*.swift);
# scripts/ci/design-allow.txt holds one regex per line of lines to allow.
# A literal that must stay says why in the body: "Design: <reason>".
here=$(dirname "$0")
. "$here/../design/design-lib.sh"
[ -f design/tokens.json ] || { echo "No design/tokens.json; nothing to check."; exit 0; }

fail=0
# 1. generated files current
if command -v node >/dev/null 2>&1; then
  node scripts/design/generate.mjs --check || fail=1
else
  echo "node is not on the PATH, so the generated design files were not checked." >&2
fi

base=${1:-origin/main}; head=${2:-}
if [ -n "$head" ]; then range="$base $head"; diff_args="$base $head"; else range="$base"; diff_args="$base"; fi

# 2. literals in UI files
ui_globs=$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' scripts/ci/design-ui.txt 2>/dev/null)
[ -n "$ui_globs" ] || ui_globs='src/**/*.tsx
src/**/*.ts
src/**/*.css
android/**/*.kt
ios/**/*.swift'
allow=$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' scripts/ci/design-allow.txt 2>/dev/null | paste -sd'|' -)
# the generated files, the token source and the fonts are never literals
gen=$(node -e 'const o=require(process.cwd()+"/design/tokens.json").outputs||{};console.log([o.ts,o.css,o.kotlin&&o.kotlin.path,typeof o.swift=="string"?o.swift:o.swift&&o.swift.path].filter(Boolean).join("\n"))' 2>/dev/null)
excl=$(printf '%s\n' "$gen" | sed '/^$/d; s/^/:(exclude)/')
# The globs go to git whole: with shell globbing on, src/**/*.tsx expanded
# two levels deep and no deeper file was ever checked (531 lines seen of
# 1276 on one project). git's pathspec reads * across folders.
set -f
# shellcheck disable=SC2086
ui_diff=$(git diff -U0 $diff_args -- $ui_globs ':(exclude)design/**' $excl 2>/dev/null)
set +f
fonts=$(token_font_names "$(cat design/tokens.json)")
hits=$(design_literals "$ui_diff" "$fonts" "${allow:-}")
if [ -n "$hits" ]; then
  why=$(design_escape "${SPEC_TEXT:-${PR_TEXT:-}}")
  if [ -n "$why" ]; then
    echo "Literal values added to UI files, allowed by the pull request: Design: $why"
    printf '%s\n' "$hits" | sed 's/^/  /'
  else
    echo "A screen uses a token or a type role by name, never a literal colour, size or font. These lines add one:" >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    echo "Move the value into design/tokens.json and regenerate, use the role's class or object, or say why it must stay with a line \"Design: <reason>\" in the pull request body." >&2
    fail=1
  fi
fi

# 3. role parity per screen pair the change touches
if [ -f scripts/ci/parity.txt ]; then
  keys=$(token_role_keys "$(cat design/tokens.json)")
  # shellcheck disable=SC2086
  changed=$(git diff --name-only $diff_args 2>/dev/null)
  mism=$(parity_pairs "$(cat scripts/ci/parity.txt)" | while IFS="$(printf '\t')" read -r name a b; do
    case "
$changed
" in *"
$a
"*|*"
$b
"*) ;; *) continue ;; esac
    ra=$(role_refs "$(git show "${head:-HEAD}:$a" 2>/dev/null || cat "$a" 2>/dev/null)" "$keys")
    rb=$(role_refs "$(git show "${head:-HEAD}:$b" 2>/dev/null || cat "$b" 2>/dev/null)" "$keys")
    role_mismatch "$name" "$(basename "$a")" "$ra" "$(basename "$b")" "$rb"
  done)
  if [ -n "$mism" ]; then
    echo "A screen pair references different type roles on its two platforms:" >&2
    printf '%s\n' "$mism" | sed 's/^/  /' >&2
    echo "Give both sides the same roles (the role is the unit; its size lives in design/tokens.json), or name the open issue that brings the other side along in a \"Parity: #N\" line." >&2
    if [ -n "$(design_escape "${SPEC_TEXT:-${PR_TEXT:-}}")" ] || printf '%s\n' "${SPEC_TEXT:-${PR_TEXT:-}}" | grep -qiE '^[[:space:]]*parity:'; then
      echo "  (allowed by the pull request's Design: or Parity: line)"
    else fail=1; fi
  fi
fi

# 4. a file under a screen folder that no pair lists
if [ -f scripts/ci/parity.txt ]; then
  # shellcheck disable=SC2086
  unp=$(parity_unpaired "$(git diff --name-only --diff-filter=AM $diff_args 2>/dev/null)" "$(cat scripts/ci/parity.txt)")
  if [ -n "$unp" ]; then
    echo "These files sit in a folder that scripts/ci/parity.txt pairs across platforms, but are in no pair themselves:" >&2
    printf '%s\n' "$unp" | sed 's/^/  /' >&2
    echo "Add each to a pair (NAME PATH_A PATH_B), or declare it one-sided with a line \"unpaired PATH\" in parity.txt." >&2
    if [ -n "$(design_escape "${SPEC_TEXT:-${PR_TEXT:-}}")" ] || printf '%s\n' "${SPEC_TEXT:-${PR_TEXT:-}}" | grep -qiE '^[[:space:]]*parity:'; then
      echo "  (allowed by the pull request's Design: or Parity: line)"
    else fail=1; fi
  fi
fi

[ "$fail" -eq 0 ] && echo "Design check passed."
exit $fail
