#!/bin/bash
# design-lint.sh — design rules + allow syntax (Epic 2 task 2.1) + ratchet and baseline (task 2.2)
# + hygiene rules file-length/try-bang/force-cast/force-unwrap/print (task 2.3)
DESIGN_LINT_VERSION=1

set -o pipefail

[ -n "${BASH_VERSION:-}" ] || { echo "design-lint: must run under bash" >&2; exit 2; }

SELF_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_TEST_FILE="$SELF_TEST_DIR/design-lint-selftest.sh"
AWK_SCRIPT="$SELF_TEST_DIR/design-lint-awk.awk"
BASELINE_LIB="$SELF_TEST_DIR/design-lint-baseline.sh"
RATCHET_SELF_TEST_FILE="$SELF_TEST_DIR/design-lint-selftest-ratchet.sh"

COLORS="red|blue|green|orange|yellow|pink|purple|gray|grey|black|white|cyan|mint|teal|indigo|brown"

rule_names=(
  "font-size"
  "padding-literal"
  "spacing-literal"
  "radius-literal"
  "hex-color"
  "raw-color"
  "raw-control"
  "file-length"
  "try-bang"
  "force-cast"
  "force-unwrap"
  "print"
  "opacity-literal"
  "frame-literal"
  "chamfer-literal"
  "motion-literal"
  "chamfer-direct"
)

rule_scopes=(
  "Sources"
  "Sources"
  "Sources"
  "Sources"
  "Sources"
  "Sources"
  "Sources"
  "Sources+Tests"
  "Sources"
  "Sources"
  "Sources"
  "Sources"
  "Sources"
  "Sources"
  "Sources"
  "Sources"
  "Sources"
)

# Patterns use [(] and [)] for literal parens (works in both grep -E and awk)
# KEPT BYTE-FOR-BYTE FROM 2ead708 — DO NOT CHANGE
rule_patterns=(
  "\\.system\\(size:|systemFont\\(ofSize:|\\.custom\\(\"[^\"]*\", *size:"
  "\\.padding\\(([^)]*, *)?-?[0-9]"
  "spacing: *-?([1-9]|0\\.[0-9]*[1-9])"
  "(cornerRadius|radius): *[0-9]|\\.cornerRadius\\( *[0-9]"
  "Color\\(hex:|NSColor\\(hex:|0x[0-9A-Fa-f]{6}([^0-9A-Fa-f]|$)|#[0-9A-Fa-f]{6}"
  "Color\\((red|white|hue|\\.sRGB|\\.displayP3|nsColor):|Color\\.(${COLORS})([^A-Za-z0-9_]|$)|\\.(foregroundStyle|foregroundColor|fill|stroke|background|tint|border)\\(\\.(${COLORS})\\)"
  "(^|[^A-Za-z0-9_])(Button|Toggle|TextField|SecureField|Picker)[[:space:]]*[({\[]|\\.(sheet|popover|contextMenu)[[:space:]]*[({\[]"
  ""
  "try!"
  "as!"
  "[]A-Za-z0-9_)]![^=]|[]A-Za-z0-9_)]!$"
  "(^|[^A-Za-z0-9_.])(print|debugPrint|NSLog)\\("
  "\\.opacity\\(([^)]*[^0-9A-Za-z_.])?0?\\.[0-9]*[1-9]"
  "\\.frame\\(([^)]*, *)?(width|height|minWidth|maxWidth|minHeight|maxHeight|idealWidth|idealHeight): *-?([1-9]|0\\.[0-9]*[1-9])"
  "ChamferShape\\( *cut: *([^,)]*[^A-Za-z0-9_.])?[0-9]|\\.cornerBrackets\\([^)]*(length|inset): *-?[0-9]"
  "\\.(easeIn|easeOut|easeInOut|linear|spring|interactiveSpring|interpolatingSpring|snappy|smooth|bouncy|timingCurve)\\([^)]*(duration|response|dampingFraction|blendDuration|bounce|extraBounce|stiffness|damping): *[0-9.]|\\.(delay|speed)\\( *[0-9.]"
  "ChamferShape\\("
)

MODE="default"
LIST_RULE=""
SELF_TEST=0
LIST_ALLOWS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --rebaseline) MODE="rebaseline" ;;
    --check-raise) MODE="check-raise"; RAISE_REF="$2"; shift ;;
    --list) MODE="list"; LIST_RULE="$2"; shift ;;
    --list-allows) MODE="list-allows" ;;
    --self-test) SELF_TEST=1 ;;
    *) echo "design-lint: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "design-lint: not a git repository" >&2; exit 2; }
cd "$repo_root" || exit 2

[ -d "Sources" ] || { echo "design-lint: not a repo root (no Sources/)" >&2; exit 2; }

collect_files() {
  local tracked_only="$1"
  local files=()
  if [ "$tracked_only" = "1" ]; then
    while IFS= read -r -d '' f; do
      case "$f" in Sources/*.swift|Tests/*.swift) files+=("$f") ;; esac
    done < <(git ls-files -z)
  else
    while IFS= read -r -d '' f; do
      case "$f" in Sources/*.swift|Tests/*.swift) files+=("$f") ;; esac
    done < <(git ls-files -z -co --exclude-standard -- Sources Tests)
  fi
  [ ${#files[@]} -gt 0 ] || { echo "design-lint: no Swift files found" >&2; exit 2; }
  printf '%s\n' "${files[@]}"
}

is_comment_line() {
  local line="$1"
  local trimmed="${line%%[![:space:]]*}"
  local rest="${line#"${trimmed}"}"
  case "$rest" in
    //*) return 0 ;;
    "/*"*) return 0 ;;
    "*"*) return 0 ;;
  esac
  return 1
}

# Ratchet and baseline (task 2.2) live in design-lint-baseline.sh (sourced).
[ -f "$BASELINE_LIB" ] || { echo "design-lint: baseline lib missing" >&2; exit 2; }
source "$BASELINE_LIB"


[ $SELF_TEST -eq 1 ] && { source "$SELF_TEST_FILE"; source "$RATCHET_SELF_TEST_FILE"; run_self_test; rc=$?; if [ $rc -eq 0 ]; then exit 0; else exit 3; fi; }

BASELINE="$repo_root/.design-lint-baseline"

# Shared counting engine: fills globals lint_files, counts, allowed_counts,
# bad_allows, line_allows, file_allows, line_allows_str, file_allows_str,
# COMBINED_FILE (kept for failure listing; the caller deletes it).
compute_counts() {
  local tracked_only="$1"
  lint_files=()
  counts=()
  allowed_counts=()
  bad_allows=()
  file_allows=()
  line_allows=()
  local list_tmp=$(mktemp)
  collect_files "$tracked_only" > "$list_tmp" || { local rc=$?; rm -f "$list_tmp"; exit $rc; }
  while IFS= read -r f; do [ -n "$f" ] && lint_files+=("$f"); done < "$list_tmp"
  rm -f "$list_tmp"

  local i=0
  while [ $i -lt ${#rule_names[@]} ]; do
    counts+=("0")
    allowed_counts+=("0")
    i=$((i + 1))
  done
  
  # S-ERR-1: try! and as! are their own rules — a line hitting either is not
  # a force-unwrap hit. The exclusion reuses those two rules' own patterns so
  # it cannot drift from them.
  local unwrap_excl=""
  local ei=0
  while [ $ei -lt ${#rule_names[@]} ]; do
    if [ "${rule_names[$ei]}" = "try-bang" ] || [ "${rule_names[$ei]}" = "force-cast" ]; then
      unwrap_excl="${unwrap_excl}|${rule_patterns[$ei]}"
    fi
    ei=$((ei + 1))
  done
  unwrap_excl="${unwrap_excl#|}"
  unwrap_excl="${unwrap_excl//\\\\/\\}"

  # Single parallel grep phase: one grep -nHE per rule over the file array.
  # Each outfile carries exactly ONE "rule:" prefix: rule:file:lineno:content.
  # (Do NOT re-prefix when combining — the file/line parse and the comment
  # skip in the awk pass depend on the single-prefix shape.)
  local tmpdir=$(mktemp -d)
  local pids=()
  local ri=0
  while [ $ri -lt ${#rule_names[@]} ]; do
    local rname="${rule_names[$ri]}"
    local scope="${rule_scopes[$ri]}"
    local pattern="${rule_patterns[$ri]}"

    local grep_files=()
    for file in "${lint_files[@]}"; do
      [ "$scope" = "Sources" ] && [[ "$file" != Sources/* ]] && continue
      grep_files+=("$file")
    done

    if [ ${#grep_files[@]} -eq 0 ]; then
      ri=$((ri + 1))
      continue
    fi

    local grep_pattern="${pattern//\\\\/\\}"
    local outfile="$tmpdir/grep_$ri.out"

    if [ "$rname" = "file-length" ]; then
      # S-SIZE-1: not a grep rule. One wc -l over the array; each file over
      # 500 lines counts once (counts FILES). Pseudo-hits use the same
      # rule:file:lineno:content shape so allows and the awk pass apply.
      wc -l "${grep_files[@]}" 2>/dev/null | while IFS= read -r wline; do
        wtrimmed="${wline#"${wline%%[![:space:]]*}"}"
        wcount="${wtrimmed%%[[:space:]]*}"
        wfile="${wtrimmed#*[[:space:]]}"
        wfile="${wfile#"${wfile%%[![:space:]]*}"}"
        case "$wcount" in ''|*[!0-9]*) continue ;; esac
        [ "$wfile" = "total" ] && continue
        [ "$wcount" -gt 500 ] && echo "file-length:$wfile:$wcount: $wcount lines"
      done > "$outfile"
      echo "$rname:$outfile" >> "$tmpdir/rule_files.txt"
      ri=$((ri + 1))
      continue
    fi

    # Run grep in background
    if [ "$rname" = "force-unwrap" ]; then
      grep -nHE "$grep_pattern" "${grep_files[@]}" 2>/dev/null | grep -vE "$unwrap_excl" | sed "s/^/${rname}:/" > "$outfile" &
    else
      grep -nHE "$grep_pattern" "${grep_files[@]}" 2>/dev/null | sed "s/^/${rname}:/" > "$outfile" &
    fi
    pids+=($!)
    echo "$rname:$outfile" >> "$tmpdir/rule_files.txt"

    ri=$((ri + 1))
  done

  # Wait for all greps to complete
  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  # Scan for allows: every file that can affect the output — files with
  # matches (field 2 of rule:file:lineno:content) plus every file mentioning
  # design-lint: (line/file allows and bad allows only live there).
  local matched_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && matched_files+=("$f")
  done < <(cat "$tmpdir"/grep_*.out 2>/dev/null | cut -d: -f2 | sort -u)

  local allow_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && allow_files+=("$f")
  done < <(grep -l 'design-lint:' "${lint_files[@]}" 2>/dev/null || true)

  local scan_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && scan_files+=("$f")
  done < <({ for f in "${matched_files[@]}" "${allow_files[@]}"; do echo "$f"; done; } | sort -u)

  # Scan only matched files for allows
  for file in "${scan_files[@]}"; do
    local fa=()
    local lineno=0
    # Scan first 10 lines for allow-file. A directive with no "<rules>
    # <reason>" reports an empty reason and suppresses nothing (2.2 fix:
    # the old full-match-only regex never fired this check).
    while IFS= read -r line && [ $lineno -lt 10 ]; do
      lineno=$((lineno + 1))
      if [[ "$line" =~ //[[:space:]]*design-lint:[[:space:]]*allow-file([[:space:]]|$) ]]; then
        if [[ "$line" =~ //[[:space:]]*design-lint:[[:space:]]*allow-file[[:space:]]+([^[:space:]]+)[[:space:]]+(.+) ]]; then
          validate_allow_rules "${BASH_REMATCH[1]}" "$file" "$lineno"
          local reason="${BASH_REMATCH[2]}"
          if is_blank "$reason"; then
            bad_allows+=("bad allow: $file:$lineno (empty reason)")
          else
            local r
            for r in $VALID_RULES; do fa+=("$r"); done
          fi
        else
          if [[ "$line" =~ //[[:space:]]*design-lint:[[:space:]]*allow-file[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
            validate_allow_rules "${BASH_REMATCH[1]}" "$file" "$lineno"
          fi
          bad_allows+=("bad allow: $file:$lineno (empty reason)")
        fi
      fi
    done < "$file"
    file_allows+=("$file|${fa[*]}")

    lineno=0
    while IFS= read -r line; do
      lineno=$((lineno + 1))
      if [[ "$line" =~ //[[:space:]]*design-lint:[[:space:]]*allow-file([[:space:]]|$) ]]; then
        continue
      fi
      if [[ "$line" =~ //[[:space:]]*design-lint:[[:space:]]*allow([[:space:]]|$) ]]; then
        local la=()
        if [[ "$line" =~ //[[:space:]]*design-lint:[[:space:]]*allow[[:space:]]+([^[:space:]]+)[[:space:]]+(.+) ]]; then
          validate_allow_rules "${BASH_REMATCH[1]}" "$file" "$lineno"
          local reason="${BASH_REMATCH[2]}"
          if is_blank "$reason"; then
            bad_allows+=("bad allow: $file:$lineno (empty reason)")
          else
            local r
            for r in $VALID_RULES; do la+=("$r"); done
          fi
        else
          if [[ "$line" =~ //[[:space:]]*design-lint:[[:space:]]*allow[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
            validate_allow_rules "${BASH_REMATCH[1]}" "$file" "$lineno"
          fi
          bad_allows+=("bad allow: $file:$lineno (empty reason)")
        fi
        if [ ${#la[@]} -gt 0 ]; then
          line_allows+=("$file|$lineno|${la[*]}")
        fi
      fi
    done < "$file"
  done
  
  # Combine results to file in rule order (avoid huge bash string).
  # Outfiles already carry their single "rule:" prefix — concatenate as-is.
  COMBINED_FILE=$(mktemp)
  if [ -f "$tmpdir/rule_files.txt" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local outfile="${line#*:}"
      [ -f "$outfile" ] && cat "$outfile" >> "$COMBINED_FILE"
    done < "$tmpdir/rule_files.txt"
  fi

  # Cleanup tmpdir
  rm -rf "$tmpdir"

  # Single awk pass to process all matches, filter comments, apply allows
  line_allows_str=$(IFS=$'\x01'; echo "${line_allows[*]}")
  file_allows_str=$(IFS=$'\x01'; echo "${file_allows[*]}")

  local awk_out
  awk_out=$(AWK_MODE="$MODE" AWK_LIST_RULE="$LIST_RULE" \
    awk -v line_allows="$line_allows_str" -v file_allows="$file_allows_str" -f "$AWK_SCRIPT" "$COMBINED_FILE" 2>/dev/null || true)

  # Parse results
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local rname="${line%%:*}"
    local rest="${line#*:}"
    local count="${rest%%:*}"
    local allowed="${rest#*:}"
    local ri=0
    while [ $ri -lt ${#rule_names[@]} ]; do
      if [ "${rule_names[$ri]}" = "$rname" ]; then
        counts[$ri]="$count"
        allowed_counts[$ri]="$allowed"
        break
      fi
      ri=$((ri + 1))
    done
  done <<< "$awk_out"
}


# Hits for one rule ("file:line: content") from the current compute pass.


run_list_modes() {
  compute_counts 0
  print_bad_allows
  if [ "$MODE" = "list-allows" ]; then
    local entry
    for entry in "${file_allows[@]}"; do
      local efile="${entry%%|*}"
      local erules="${entry#*|}"
      local rule
      for rule in $erules; do
        echo "$efile:1: allow-file $rule"
      done
    done
    for entry in "${line_allows[@]}"; do
      local efile="${entry%%|*}"
      local erest="${entry#*|}"
      local elineno="${erest%%|*}"
      local erules="${erest#*|}"
      local rule
      for rule in $erules; do
        echo "$efile:$elineno: allow $rule"
      done
    done
    rm -f "$COMBINED_FILE"
    return
  fi
  rule_index "$LIST_RULE" || { echo "design-lint: unknown rule '$LIST_RULE'" >&2; rm -f "$COMBINED_FILE"; exit 2; }
  list_hits_for_rule "$LIST_RULE"
  rm -f "$COMBINED_FILE"
}


if [ "$MODE" = "default" ]; then
  run_default
elif [ "$MODE" = "check" ]; then
  run_check
elif [ "$MODE" = "rebaseline" ]; then
  run_rebaseline
elif [ "$MODE" = "check-raise" ]; then
  run_check_raise
elif [ "$MODE" = "list" ] || [ "$MODE" = "list-allows" ]; then
  run_list_modes
else
  echo "design-lint: unknown mode: $MODE" >&2
  exit 2
fi