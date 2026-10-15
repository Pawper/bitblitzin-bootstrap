#!/bin/sh
# Pure helpers for the design checks. Nothing here reads a file or touches
# the network, so every function can be tested by feeding it strings.

# token_font_names TOKENS_JSON
# The font family names tokens.json declares, one per line.
token_font_names() {
  json_list "$1" families | grep -o '"name"[ \t]*:[ \t]*"[^"]*"' | sed 's/.*:[ \t]*"\([^"]*\)"/\1/'
}

# json_list JSON NAME: the text of the array "NAME": [ ... ], its own
# brackets balanced, so a list later in the file is never read into it.
json_list() {
  printf '%s' "$1" | tr -d '\r\n' | awk -v name="\"$2\"" '
    { i = index($0, name); if (!i) exit
      s = substr($0, i); j = index(s, "["); if (!j) exit
      depth = 0
      for (k = j; k <= length(s); k++) { c = substr(s, k, 1); if (c == "[") depth++; if (c == "]") { depth--; if (depth == 0) { print substr(s, j + 1, k - j - 1); exit } } } }'
}

# token_role_keys TOKENS_JSON
# The type role keys tokens.json declares, one per line.
token_role_keys() {
  json_list "$1" roles | grep -o '"key"[ \t]*:[ \t]*"[^"]*"' | sed 's/.*:[ \t]*"\([^"]*\)"/\1/'
}

# design_literals DIFF FONT_NAMES [ALLOW_RE]
# DIFF is a unified diff with zero context (git diff -U0) over UI files.
# Print each added line that carries a raw hex colour (#abc, #aabbcc,
# 0xFFaabbcc), a px, dp or sp number for type or spacing (0, 0.5 and 1
# are hairlines and pass), or a font name from FONT_NAMES (one per line),
# as "path:line: text". Lines matching ALLOW_RE (a regex, default: comment
# lines and @media) are skipped. Every drift one project fixed was a
# literal on one side; a screen says a token or a role by name.
design_literals() {
  dl_fonts=$(printf '%s\n' "$2" | sed '/^[[:space:]]*$/d' | sed 's/[][\.*^$]/\\&/g' | paste -sd'|' -)
  # awk -v strips one backslash, so the pattern carries two
  dl_allow='^[[:space:]]*(//|/\\*|\\*|#)|@media'
  [ -z "$3" ] || dl_allow="$dl_allow|$3"
  printf '%s\n' "$1" | tr -d '\r' | awk -v fonts="$dl_fonts" -v allow="$dl_allow" '
    /^\+\+\+ / { f = $0; sub(/^\+\+\+ b\//, "", f); sub(/^\+\+\+ /, "", f); next }
    /^@@/ { n = $0; sub(/^@@ -[0-9,]+ \+/, "", n); sub(/[ ,].*/, "", n); line = n + 0; next }
    /^\+/ {
      t = substr($0, 2); cur = line; line++
      if (t ~ allow) next
      hit = 0
      if (t ~ /#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])?([0-9a-fA-F][0-9a-fA-F])?([^0-9a-zA-Z_-]|$)/) hit = 1
      if (t ~ /0[xX][fF][fF][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/) hit = 1
      s = t
      while (match(s, /[0-9]+(\.[0-9]+)?\.?(px|dp|sp)([^a-zA-Z0-9_]|$)/)) {
        m = substr(s, RSTART, RLENGTH); num = m; sub(/\.?(px|dp|sp).*/, "", num)
        before = (RSTART > 1) ? substr(s, RSTART - 1, 1) : " "
        if (before !~ /[a-zA-Z0-9_.-]/ && num + 0 != 0 && num + 0 != 0.5 && num + 0 != 1) hit = 1
        s = substr(s, RSTART + RLENGTH)
      }
      if (fonts != "" && t ~ ("[\"\x27](" fonts ")[\"\x27]")) hit = 1
      if (hit) printf "%s:%d: %s\n", f, cur, t
    }'
}

# design_escape TEXT
# Print the reason when a pull request body carries "Design: <reason>",
# nothing otherwise. A literal that must stay says why.
design_escape() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^[[:space:]]*[Dd]esign:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' | head -n 1
}

# role_refs TEXT ROLE_KEYS
# The type roles TEXT references, one key per line, found as the key in
# any spelling a platform uses (rowClaim, type-row-claim, RowClaim,
# row_claim) as a whole word.
role_refs() {
  # hyphens and underscores become spaces, so type-row-claim reads as
  # "type row claim" and a key matches as "rowclaim" or "row claim"
  rr_text=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr '_-' '  ')
  printf '%s\n' "$2" | sed '/^[[:space:]]*$/d' | while IFS= read -r rr_k; do
    rr_l=$(printf '%s' "$rr_k" | tr 'A-Z' 'a-z' | tr -d '_-')
    rr_s=$(printf '%s' "$rr_k" | sed 's/\([A-Z]\)/ \1/g; s/[_-]/ /g; s/  */ /g; s/^ //' | tr 'A-Z' 'a-z')
    if printf '%s' "$rr_text" | grep -qE "(^|[^a-z0-9])($rr_l|$rr_s)([^a-z0-9]|$)"; then printf '%s\n' "$rr_k"; fi
  done
}

# role_mismatch NAME SIDE_A REFS_A SIDE_B REFS_B
# Print one line per role one side references and the other does not,
# "NAME: SIDE_A uses rowClaim, SIDE_B does not"; nothing when they agree.
role_mismatch() {
  rm_a=$(printf '%s\n' "$3" | sed '/^$/d' | sort -u); rm_b=$(printf '%s\n' "$5" | sed '/^$/d' | sort -u)
  printf '%s\n' "$rm_a" | while IFS= read -r k; do [ -n "$k" ] || continue; printf '%s\n' "$rm_b" | grep -qx "$k" || printf '%s: %s uses %s, %s does not\n' "$1" "$2" "$k" "$4"; done
  printf '%s\n' "$rm_b" | while IFS= read -r k; do [ -n "$k" ] || continue; printf '%s\n' "$rm_a" | grep -qx "$k" || printf '%s: %s uses %s, %s does not\n' "$1" "$4" "$k" "$2"; done
}

# parity_pairs PARITY_TXT
# The screen pairs of scripts/ci/parity.txt, "NAME<TAB>PATH_A<TAB>PATH_B".
parity_pairs() {
  printf '%s\n' "$1" | tr -d '\r' | awk '!/^[[:space:]]*(#|$)/ && NF >= 3 { printf "%s\t%s\t%s\n", $1, $2, $3 }'
}

# day_number YYYY-MM-DD: days since 1970-01-01, in awk, for dates kept as
# the owner's local day (no clock, no zone).
day_number() {
  printf '%s\n' "$1" | awk -F- '{
    y = $1 + 0; m = $2 + 0; d = $3 + 0
    if (m <= 2) { y--; m += 12 }
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m - 3) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    print era * 146097 + doe - 719468 }'
}

# stale_screens PAIRS RECORDS TODAY [DAYS]
# PAIRS is parity_pairs output; RECORDS the lines of design/screens.txt
# ("NAME DATE BY"); TODAY the owner's day. Print each pair never compared,
# or compared more than DAYS (default 14) ago, as "NAME: never" or
# "NAME: N days", worst first.
stale_screens() {
  ss_today=$(day_number "$3")
  printf '%s\n' "$1" | awk -F'\t' 'NF >= 1 && $1 != "" { print $1 }' | while IFS= read -r ss_n; do
    ss_date=$(printf '%s\n' "$2" | tr -d '\r' | awk -v n="$ss_n" '!/^[[:space:]]*#/ && $1 == n { d = $2 } END { print d }')
    if [ -z "$ss_date" ]; then printf '99999\t%s: never\n' "$ss_n"
    else ss_age=$(( ss_today - $(day_number "$ss_date") )); [ "$ss_age" -gt "${4:-14}" ] && printf '%s\t%s: %s days\n' "$ss_age" "$ss_n" "$ss_age"; fi
  done | sort -t"$(printf '\t')" -k1,1nr | cut -f2
}
