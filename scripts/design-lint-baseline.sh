# design-lint-baseline.sh — ratchet and baseline for design-lint.sh (Epic 2 task 2.2)
# Sourced by design-lint.sh; not run directly. Needs rule_names from the caller.

is_blank() {
  [[ "$1" =~ ^[[:space:]]*$ ]]
}

# Validate a comma-separated allow rule list. Appends an
# "unknown rule" bad allow per unknown entry; sets VALID_RULES to the
# space-joined known ones. Never suppresses anything by itself.
validate_allow_rules() {
  local rule_list="$1" file="$2" lineno="$3"
  VALID_RULES=""
  local rules=()
  IFS=',' read -ra rules <<< "$rule_list"
  local rule
  for rule in "${rules[@]}"; do
    rule=$(echo "$rule" | xargs)
    [ -z "$rule" ] && continue
    local found=0
    local i=0
    while [ $i -lt ${#rule_names[@]} ]; do
      [ "${rule_names[$i]}" = "$rule" ] && found=1 && break
      i=$((i + 1))
    done
    if [ $found -eq 1 ]; then
      VALID_RULES="$VALID_RULES $rule"
    else
      bad_allows+=("bad allow: $file:$lineno (unknown rule: $rule)")
    fi
  done
  VALID_RULES="${VALID_RULES# }"
}

baseline_init() {
  base_counts=()
  base_present=()
  base_off=()
  base_off_reason=()
  base_format=""
  base_version=""
  local i=0
  while [ $i -lt ${#rule_names[@]} ]; do
    base_counts+=("0")
    base_present+=("0")
    base_off+=("0")
    base_off_reason+=("")
    i=$((i + 1))
  done
}

rule_index() {
  RULE_INDEX=-1
  local i=0
  while [ $i -lt ${#rule_names[@]} ]; do
    if [ "${rule_names[$i]}" = "$1" ]; then RULE_INDEX=$i; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# Strict baseline reader: unknown keys, bad values and duplicates exit 2.
read_baseline() {
  [ -f "$BASELINE" ] || { echo "design-lint: no baseline — run scripts/design-lint.sh --rebaseline" >&2; exit 2; }
  baseline_init
  local n=0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    set -- $line
    if [ "$1" = "version" ]; then
      { [ $# -eq 2 ] && [ "$2" = "1" ]; } || { echo "design-lint: bad baseline line $n: $line" >&2; exit 2; }
      [ -z "$base_version" ] || { echo "design-lint: bad baseline line $n: duplicate version" >&2; exit 2; }
      base_version="$2"
    elif [ "$1" = "format" ]; then
      { [ $# -eq 2 ] && { [ "$2" = "on" ] || [ "$2" = "off" ]; }; } || { echo "design-lint: bad baseline line $n: $line" >&2; exit 2; }
      [ -z "$base_format" ] || { echo "design-lint: bad baseline line $n: duplicate format" >&2; exit 2; }
      base_format="$2"
    else
      rule_index "$1" || { echo "design-lint: bad baseline line $n: unknown rule '$1'" >&2; exit 2; }
      local ri=$RULE_INDEX
      [ "${base_present[$ri]}" = "0" ] || { echo "design-lint: bad baseline line $n: duplicate rule '$1'" >&2; exit 2; }
      if [ "$2" = "off" ]; then
        [ $# -ge 3 ] || { echo "design-lint: bad baseline: '$1 off' needs a reason" >&2; exit 2; }
        base_off[$ri]=1
        base_present[$ri]=1
        base_off_reason[$ri]="${line#* off }"
      else
        [ $# -eq 2 ] || { echo "design-lint: bad baseline line $n: $line" >&2; exit 2; }
        case "$2" in ''|*[!0-9]*) echo "design-lint: bad baseline line $n: not a count: $line" >&2; exit 2 ;; esac
        base_counts[$ri]="$2"
        base_present[$ri]=1
      fi
    fi
  done < "$BASELINE"
  [ -n "$base_version" ] || { echo "design-lint: bad baseline: missing 'version 1'" >&2; exit 2; }
  [ -n "$base_format" ] || { echo "design-lint: bad baseline: missing 'format on|off'" >&2; exit 2; }
}

# Baseline writer: table order, keeps `off` lines and the `format` value.
# $1: "full" (rebaseline: every non-off rule takes the current count) or
# "lower" (default ratchet: only lower counts and append missing rules).
write_baseline() {
  local wmode="$1"
  {
    echo "# design-lint baseline. Counts only go down: \`make lint\` lowers them."
    echo "# Raising one needs \`make lint-rebaseline\`, DESIGN_LINT_ALLOW_RAISE=1 on push, and a PR note."
    echo "version 1"
    echo "format $base_format"
    local i=0
    while [ $i -lt ${#rule_names[@]} ]; do
      if [ "${base_off[$i]}" = "1" ]; then
        echo "${rule_names[$i]} off ${base_off_reason[$i]}"
      elif [ "${base_present[$i]}" = "1" ]; then
        if [ "$wmode" = "full" ]; then
          echo "${rule_names[$i]} ${counts[$i]}"
        elif [ "${counts[$i]}" -lt "${base_counts[$i]}" ]; then
          echo "${rule_names[$i]} ${counts[$i]}"
        else
          echo "${rule_names[$i]} ${base_counts[$i]}"
        fi
      else
        echo "${rule_names[$i]} ${counts[$i]}"
      fi
      i=$((i + 1))
    done
  } > "$BASELINE.tmp" && mv "$BASELINE.tmp" "$BASELINE"
}

print_bad_allows() {
  local ba
  for ba in "${bad_allows[@]}"; do echo "$ba" >&2; done
}

list_hits_for_rule() {
  local r="$1"
  AWK_MODE="list" AWK_LIST_RULE="$r" \
    awk -v line_allows="$line_allows_str" -v file_allows="$file_allows_str" \
    -f "$AWK_SCRIPT" "$COMBINED_FILE" 2>/dev/null || true
}

print_table_header() {
  local repo_name=$(basename "$repo_root")
  local total_files=${#lint_files[@]}
  local source_files=0
  local f
  for f in "${lint_files[@]}"; do [[ "$f" == Sources/* ]] && source_files=$((source_files + 1)); done
  echo "design-lint v$DESIGN_LINT_VERSION · $repo_name · $source_files sources · $total_files files"
  printf "%-18s %6s %6s %6s\n" "rule" "count" "base" "allowed"
}

print_hooks_note() {
  if [ -z "$(git config core.hooksPath 2>/dev/null || true)" ]; then
    echo "note: pre-push hook not installed — make hooks"
  fi
}

# Failure listing (§6): hits for files changed since merge-base with
# origin/development (fallback origin/main) plus modified/untracked files;
# when nothing intersects, all hits, capped at 50. Uses FAIL_INDEXES.
print_failures() {
  local merge_base=""
  merge_base=$(git merge-base HEAD origin/development 2>/dev/null || git merge-base HEAD origin/main 2>/dev/null || true)
  local changed_tmp=$(mktemp)
  if [ -n "$merge_base" ]; then
    git diff --name-only "$merge_base" HEAD 2>/dev/null >> "$changed_tmp" || true
  fi
  git diff --name-only HEAD 2>/dev/null >> "$changed_tmp" || true
  git ls-files -o --exclude-standard 2>/dev/null >> "$changed_tmp" || true
  local changed_list=$(sort -u "$changed_tmp" | grep '\.swift$' || true)
  rm -f "$changed_tmp"
  local ri
  for ri in $FAIL_INDEXES; do
    local rname="${rule_names[$ri]}"
    echo "FAIL $rname: ${counts[$ri]} > baseline ${base_counts[$ri]}"
    local hits
    hits=$(list_hits_for_rule "$rname")
    local shown=""
    if [ -n "$changed_list" ] && [ -n "$hits" ]; then
      shown=$(echo "$hits" | while IFS= read -r h; do
        [ -z "$h" ] && continue
        local hf="${h%%:*}"
        echo "$changed_list" | grep -qxF "$hf" && echo "$h"
      done | head -n 50)
    fi
    if [ -n "$shown" ]; then
      echo "$shown" | sed 's/^/  /'
      echo "  (hits in files changed since origin/development; \`scripts/design-lint.sh --list $rname\` for all)"
    else
      echo "$hits" | head -n 50 | sed 's/^/  /'
      echo "  (no hits in changed files - all hits, capped at 50; \`scripts/design-lint.sh --list $rname\` for all)"
    fi
  done
}

run_default() {
  compute_counts 0
  print_bad_allows
  read_baseline
  FAIL_INDEXES=""
  local lowered_msgs=()
  local new_msgs=()
  local failed=0
  local ri=0
  while [ $ri -lt ${#rule_names[@]} ]; do
    if [ "${base_off[$ri]}" = "1" ]; then
      :
    elif [ "${base_present[$ri]}" = "0" ]; then
      new_msgs+=("${rule_names[$ri]} new -> ${counts[$ri]}")
    elif [ "${counts[$ri]}" -gt "${base_counts[$ri]}" ]; then
      FAIL_INDEXES="$FAIL_INDEXES $ri"
      failed=$((failed + 1))
    elif [ "${counts[$ri]}" -lt "${base_counts[$ri]}" ]; then
      lowered_msgs+=("${rule_names[$ri]} lowered ${base_counts[$ri]}->${counts[$ri]}")
    fi
    ri=$((ri + 1))
  done
  print_table_header
  ri=0
  while [ $ri -lt ${#rule_names[@]} ]; do
    local rname="${rule_names[$ri]}"
    local count=${counts[$ri]:-0}
    local allowed=${allowed_counts[$ri]:-0}
    local base status
    if [ "${base_off[$ri]}" = "1" ]; then
      base="off"; status="ok"
    elif [ "${base_present[$ri]}" = "0" ]; then
      base="new"; status="new"
    elif [ "$count" -gt "${base_counts[$ri]}" ]; then
      base="${base_counts[$ri]}"; status="FAIL +$((count - base_counts[$ri]))"
    elif [ "$count" -lt "${base_counts[$ri]}" ]; then
      base="${base_counts[$ri]}"; status="lowered ${base_counts[$ri]}->${count}"
    else
      base="${base_counts[$ri]}"; status="ok"
    fi
    printf "%-18s %6s %6s %6s  %s\n" "$rname" "$count" "$base" "$allowed" "$status"
    ri=$((ri + 1))
  done
  local m
  for m in "${lowered_msgs[@]}" "${new_msgs[@]}"; do echo "$m"; done
  print_hooks_note
  if [ $failed -gt 0 ]; then
    print_failures
    rm -f "$COMBINED_FILE"
    if [ $failed -eq 1 ]; then
      echo "design-lint: FAIL — 1 rule over baseline" >&2
    else
      echo "design-lint: FAIL — $failed rules over baseline" >&2
    fi
    exit 1
  fi
  if [ ${#lowered_msgs[@]} -gt 0 ] || [ ${#new_msgs[@]} -gt 0 ]; then
    write_baseline lower
  fi
  rm -f "$COMBINED_FILE"
}

run_check() {
  compute_counts 1
  print_bad_allows
  read_baseline
  local ri=0
  while [ $ri -lt ${#rule_names[@]} ]; do
    [ "${base_present[$ri]}" = "1" ] || [ "${base_off[$ri]}" = "1" ] || { echo "design-lint: baseline lacks ${rule_names[$ri]}" >&2; rm -f "$COMBINED_FILE"; exit 2; }
    ri=$((ri + 1))
  done
  FAIL_INDEXES=""
  local failed=0
  print_table_header
  ri=0
  while [ $ri -lt ${#rule_names[@]} ]; do
    local rname="${rule_names[$ri]}"
    local count=${counts[$ri]:-0}
    local allowed=${allowed_counts[$ri]:-0}
    local base status
    if [ "${base_off[$ri]}" = "1" ]; then
      base="off"; status="ok"
    elif [ "$count" -gt "${base_counts[$ri]}" ]; then
      base="${base_counts[$ri]}"; status="FAIL +$((count - base_counts[$ri]))"
      FAIL_INDEXES="$FAIL_INDEXES $ri"
      failed=$((failed + 1))
    elif [ "$count" -lt "${base_counts[$ri]}" ]; then
      base="${base_counts[$ri]}"; status="stale (baseline ${base_counts[$ri]}) - run make lint, commit the baseline"
    else
      base="${base_counts[$ri]}"; status="ok"
    fi
    printf "%-18s %6s %6s %6s  %s\n" "$rname" "$count" "$base" "$allowed" "$status"
    ri=$((ri + 1))
  done
  print_hooks_note
  if [ $failed -gt 0 ]; then
    print_failures
    rm -f "$COMBINED_FILE"
    if [ $failed -eq 1 ]; then
      echo "design-lint: FAIL — 1 rule over baseline" >&2
    else
      echo "design-lint: FAIL — $failed rules over baseline" >&2
    fi
    exit 1
  fi
  rm -f "$COMBINED_FILE"
}

run_rebaseline() {
  compute_counts 0
  print_bad_allows
  if [ -f "$BASELINE" ]; then
    read_baseline
  else
    baseline_init
    base_format="off"
  fi
  local changed=0
  local ri=0
  while [ $ri -lt ${#rule_names[@]} ]; do
    local rname="${rule_names[$ri]}"
    if [ "${base_off[$ri]}" = "1" ]; then
      :
    elif [ "${base_present[$ri]}" = "0" ]; then
      echo "$rname new -> ${counts[$ri]}"
      changed=1
    elif [ "${counts[$ri]}" != "${base_counts[$ri]}" ]; then
      local d=$((counts[$ri] - base_counts[$ri]))
      if [ $d -gt 0 ]; then
        echo "$rname ${base_counts[$ri]} -> ${counts[$ri]} (+$d)"
      else
        echo "$rname ${base_counts[$ri]} -> ${counts[$ri]} ($d)"
      fi
      changed=1
    fi
    ri=$((ri + 1))
  done
  write_baseline full
  [ $changed -eq 1 ] || echo "design-lint: baseline unchanged"
  rm -f "$COMBINED_FILE"
}

run_check_raise() {
  local ref="${RAISE_REF:-}"
  if [ -z "$ref" ]; then
    echo "design-lint: raise check skipped (no upstream ref)"
    return 0
  fi
  local ref_tmp=$(mktemp)
  git show "$ref:.design-lint-baseline" > "$ref_tmp" 2>/dev/null || {
    rm -f "$ref_tmp"
    echo "design-lint: raise check skipped (no baseline at $ref)"
    return 0
  }
  [ -f "$BASELINE" ] || { echo "design-lint: no baseline — run scripts/design-lint.sh --rebaseline" >&2; rm -f "$ref_tmp"; exit 2; }
  read_baseline
  local wt_format="$base_format"
  local wt_counts=() wt_present=() wt_off=()
  local i=0
  while [ $i -lt ${#rule_names[@]} ]; do
    wt_counts+=("${base_counts[$i]}")
    wt_present+=("${base_present[$i]}")
    wt_off+=("${base_off[$i]}")
    i=$((i + 1))
  done
  local saved_baseline="$BASELINE"
  BASELINE="$ref_tmp"
  read_baseline
  local ref_format="$base_format"
  local ref_counts=() ref_present=() ref_off=()
  i=0
  while [ $i -lt ${#rule_names[@]} ]; do
    ref_counts+=("${base_counts[$i]}")
    ref_present+=("${base_present[$i]}")
    ref_off+=("${base_off[$i]}")
    i=$((i + 1))
  done
  BASELINE="$saved_baseline"
  rm -f "$ref_tmp"
  local raises=()
  i=0
  while [ $i -lt ${#rule_names[@]} ]; do
    if [ "${wt_off[$i]}" = "1" ] && [ "${ref_off[$i]}" = "0" ]; then
      raises+=("RAISE ${rule_names[$i]}: turned off")
    elif [ "${wt_off[$i]}" = "0" ] && [ "${ref_off[$i]}" = "0" ] \
      && [ "${wt_present[$i]}" = "1" ] && [ "${ref_present[$i]}" = "1" ] \
      && [ "${wt_counts[$i]}" -gt "${ref_counts[$i]}" ]; then
      raises+=("RAISE ${rule_names[$i]}: ${ref_counts[$i]} -> ${wt_counts[$i]}")
    fi
    i=$((i + 1))
  done
  if [ "$wt_format" = "off" ] && [ "$ref_format" = "on" ]; then
    raises+=("RAISE format: on -> off")
  fi
  if [ ${#raises[@]} -eq 0 ]; then
    echo "design-lint: raise check ok"
    return 0
  fi
  local r
  if [ "${DESIGN_LINT_ALLOW_RAISE:-0}" = "1" ]; then
    echo "=================================================="
    echo "  BASELINE RAISED — justify it in the PR"
    echo "=================================================="
    for r in "${raises[@]}"; do echo "$r"; done
    return 0
  fi
  for r in "${raises[@]}"; do echo "$r" >&2; done
  echo "design-lint: FAIL — baseline raised" >&2
  exit 1
}

