# design-lint-selftest-ratchet.sh — ratchet cases for design-lint.sh --self-test (task 2.2)
# Sourced by design-lint.sh alongside design-lint-selftest.sh; not run directly.
# run_ratchet_self_test runs inside run_self_test and shares its locals
# (failed, real_script) through bash dynamic scoping.

run_ratchet_self_test() {
  # Every rule in the rule array must have a hitting fixture: --list on
  # the fixture repo must be non-empty for each rule, through the REAL engine.
  for r in "${rule_names[@]}"; do
    out=$(bash "$real_script" --list "$r" 2>/dev/null || true)
    [ -n "$out" ] || { echo "FAIL: rule $r has no fixture hit" >&2; failed=1; }
  done

  # ---- Ratchet (§5/§7), through the REAL engine ----
  local rdir=$(mktemp -d)
  mkdir -p "$rdir/Sources"
  cat > "$rdir/Sources/A.swift" <<'EOF'
import SwiftUI
struct V: View { var body: some View {
  Text("x").font(.system(size: 10))
  Text("y").font(.system(size: 11))
} }
EOF
  (cd "$rdir" && git init -q && git config user.email "test@test" && git config user.name "Test" && git add -A && git commit -qm fixtures)
  local rc
  (cd "$rdir" && bash "$real_script" >/dev/null 2>&1); rc=$?
  [ $rc -eq 2 ] || { echo "FAIL: ratchet default without baseline exit=$rc want 2" >&2; failed=1; }
  (cd "$rdir" && bash "$real_script" --check >/dev/null 2>&1); rc=$?
  [ $rc -eq 2 ] || { echo "FAIL: ratchet --check without baseline exit=$rc want 2" >&2; failed=1; }
  out=$(cd "$rdir" && bash "$real_script" --rebaseline 2>/dev/null); rc=$?
  [ $rc -eq 0 ] || { echo "FAIL: ratchet --rebaseline exit=$rc want 0" >&2; failed=1; }
  echo "$out" | grep -q "font-size new -> 2" || { echo "FAIL: ratchet --rebaseline did not print [font-size new -> 2]: [$out]" >&2; failed=1; }
  grep -qx "version 1" "$rdir/.design-lint-baseline" || { echo "FAIL: ratchet baseline lacks [version 1]" >&2; failed=1; }
  grep -qx "format off" "$rdir/.design-lint-baseline" || { echo "FAIL: ratchet baseline lacks [format off]" >&2; failed=1; }
  grep -qx "font-size 2" "$rdir/.design-lint-baseline" || { echo "FAIL: ratchet baseline lacks [font-size 2]" >&2; failed=1; }
  prev=0
  for r in "${rule_names[@]}"; do
    n=$(grep -nx "$r [0-9]*" "$rdir/.design-lint-baseline" | cut -d: -f1)
    [ -n "$n" ] && [ "$n" -gt "$prev" ] || { echo "FAIL: ratchet baseline rule $r out of table order" >&2; failed=1; }
    prev=$n
  done
  (cd "$rdir" && bash "$real_script" --check >/dev/null 2>&1); rc=$?
  [ $rc -eq 0 ] || { echo "FAIL: ratchet --check after --rebaseline exit=$rc want 0" >&2; failed=1; }
  # adding a hit -> --check exit 1 naming file:line (--check reads tracked
  # files only, so stage the new file as a push would have it committed)
  printf '%s\n' 'import SwiftUI' 'struct W: View { var body: some View {' '  Text("z").font(.system(size: 9))' '} }' > "$rdir/Sources/B.swift"
  (cd "$rdir" && git add -A)
  out=$(cd "$rdir" && bash "$real_script" --check 2>&1); rc=$?
  [ $rc -eq 1 ] || { echo "FAIL: ratchet --check after adding a hit exit=$rc want 1" >&2; failed=1; }
  echo "$out" | grep -q "Sources/B.swift:3" || { echo "FAIL: ratchet --check does not name Sources/B.swift:3: [$out]" >&2; failed=1; }
  # removing two (the added file plus one original hit) -> default lowers the file
  rm "$rdir/Sources/B.swift"
  printf '%s\n' 'import SwiftUI' 'struct V: View { var body: some View {' '  Text("x").font(.system(size: 10))' '} }' > "$rdir/Sources/A.swift"
  (cd "$rdir" && git add -A)
  out=$(cd "$rdir" && bash "$real_script" 2>/dev/null); rc=$?
  [ $rc -eq 0 ] || { echo "FAIL: ratchet default after removing two exit=$rc want 0" >&2; failed=1; }
  echo "$out" | grep -q "font-size lowered 2->1" || { echo "FAIL: ratchet default did not print [font-size lowered 2->1]: [$out]" >&2; failed=1; }
  grep -qx "font-size 1" "$rdir/.design-lint-baseline" || { echo "FAIL: ratchet baseline was not lowered to [font-size 1]" >&2; failed=1; }
  # stale: hand-raise the baseline, --check stays 0 and rewrites nothing
  printf '%s\n' 'version 1' 'format off' 'font-size 4' > "$rdir/.design-lint-baseline.tmp"
  for r in "${rule_names[@]}"; do
    [ "$r" = "font-size" ] && continue
    echo "$r 0" >> "$rdir/.design-lint-baseline.tmp"
  done
  mv "$rdir/.design-lint-baseline.tmp" "$rdir/.design-lint-baseline"
  out=$(cd "$rdir" && bash "$real_script" --check 2>/dev/null); rc=$?
  [ $rc -eq 0 ] || { echo "FAIL: ratchet stale --check exit=$rc want 0" >&2; failed=1; }
  echo "$out" | grep -q "stale (baseline 4)" || { echo "FAIL: ratchet stale --check did not print stale: [$out]" >&2; failed=1; }
  grep -qx "font-size 4" "$rdir/.design-lint-baseline" || { echo "FAIL: ratchet stale --check rewrote the baseline" >&2; failed=1; }
  (cd "$rdir" && bash "$real_script" --rebaseline >/dev/null 2>&1)
  grep -qx "font-size 1" "$rdir/.design-lint-baseline" || { echo "FAIL: ratchet --rebaseline did not restore [font-size 1]" >&2; failed=1; }
  # --check-raise against the committed lower baseline after a raise
  (cd "$rdir" && git add -A && git commit -qm baseline)
  printf '%s\n' 'version 1' 'format off' 'font-size 5' > "$rdir/.design-lint-baseline.tmp"
  for r in "${rule_names[@]}"; do
    [ "$r" = "font-size" ] && continue
    echo "$r 0" >> "$rdir/.design-lint-baseline.tmp"
  done
  mv "$rdir/.design-lint-baseline.tmp" "$rdir/.design-lint-baseline"
  (cd "$rdir" && bash "$real_script" --check-raise HEAD >/dev/null 2>&1); rc=$?
  [ $rc -eq 1 ] || { echo "FAIL: ratchet --check-raise after raise exit=$rc want 1" >&2; failed=1; }
  out=$(cd "$rdir" && DESIGN_LINT_ALLOW_RAISE=1 bash "$real_script" --check-raise HEAD 2>&1); rc=$?
  [ $rc -eq 0 ] || { echo "FAIL: ratchet --check-raise with ALLOW_RAISE exit=$rc want 0" >&2; failed=1; }
  echo "$out" | grep -q "BASELINE RAISED" || { echo "FAIL: ratchet --check-raise with ALLOW_RAISE printed no banner: [$out]" >&2; failed=1; }
  out=$(cd "$rdir" && bash "$real_script" --check-raise "" 2>&1); rc=$?
  [ $rc -eq 0 ] || { echo "FAIL: ratchet --check-raise empty ref exit=$rc want 0" >&2; failed=1; }
  echo "$out" | grep -q "raise check skipped" || { echo "FAIL: ratchet --check-raise empty ref printed no skip notice: [$out]" >&2; failed=1; }
  # off and format survive a rebaseline; off rules are not evaluated
  printf '%s\n' 'version 1' 'format on' 'font-size 1' > "$rdir/.design-lint-baseline.tmp"
  for r in "${rule_names[@]}"; do
    [ "$r" = "font-size" ] && continue
    if [ "$r" = "raw-control" ]; then
      echo "raw-control off AppKit implements the kit controls" >> "$rdir/.design-lint-baseline.tmp"
    else
      echo "$r 0" >> "$rdir/.design-lint-baseline.tmp"
    fi
  done
  mv "$rdir/.design-lint-baseline.tmp" "$rdir/.design-lint-baseline"
  (cd "$rdir" && bash "$real_script" --rebaseline >/dev/null 2>&1)
  grep -qx "format on" "$rdir/.design-lint-baseline" || { echo "FAIL: ratchet --rebaseline did not preserve [format on]" >&2; failed=1; }
  grep -qx "raw-control off AppKit implements the kit controls" "$rdir/.design-lint-baseline" || { echo "FAIL: ratchet --rebaseline did not preserve the off line" >&2; failed=1; }
  rm -rf "$rdir"

  # ---- Strict baseline reader: unknown keys are exit 2 ----
  local sdir=$(mktemp -d)
  mkdir -p "$sdir/Sources"
  printf '%s\n' 'struct X {' '  let a = 1' '}' > "$sdir/Sources/X.swift"
  (cd "$sdir" && git init -q && git add -A && bash "$real_script" --rebaseline >/dev/null 2>&1)
  (cd "$sdir" && printf '%s\n' 'bogus-key 1' >> .design-lint-baseline && bash "$real_script" >/dev/null 2>&1); rc=$?
  [ $rc -eq 2 ] || { echo "FAIL: strict reader unknown key exit=$rc want 2" >&2; failed=1; }
  (cd "$sdir" && git checkout -q -- .design-lint-baseline 2>/dev/null || true)
  (cd "$sdir" && bash "$real_script" --rebaseline >/dev/null 2>&1)
  python3 - "$sdir/.design-lint-baseline" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
with open(p, "w") as f:
    for line in lines:
        if line.startswith("padding-literal "):
            f.write("padding-literal off\n")
        else:
            f.write(line)
PYEOF
  (cd "$sdir" && bash "$real_script" >/dev/null 2>&1); rc=$?
  [ $rc -eq 2 ] || { echo "FAIL: strict reader off-without-reason exit=$rc want 2" >&2; failed=1; }
  (cd "$sdir" && bash "$real_script" --rebaseline >/dev/null 2>&1)
  python3 - "$sdir/.design-lint-baseline" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
with open(p, "w") as f:
    for line in lines:
        if line.startswith("padding-literal "):
            f.write("bogus-rule 3\n")
        else:
            f.write(line)
PYEOF
  (cd "$sdir" && bash "$real_script" >/dev/null 2>&1); rc=$?
  [ $rc -eq 2 ] || { echo "FAIL: strict reader unknown rule exit=$rc want 2" >&2; failed=1; }
  rm -rf "$sdir"

  # ---- Empty-reason allows (2.1 review carry-over), through the REAL engine ----
  local edir=$(mktemp -d)
  mkdir -p "$edir/Sources"
  cat > "$edir/Sources/E.swift" <<'EOF'
import SwiftUI
struct V: View { var body: some View {
  Text("x").font(.system(size: 10)) // design-lint: allow font-size
  Text("y").font(.system(size: 11))
} }
EOF
  cat > "$edir/Sources/F.swift" <<'EOF'
// design-lint: allow-file padding-literal
import SwiftUI
struct W: View { var body: some View {
  Text("x").padding(8)
} }
EOF
  (cd "$edir" && git init -q && git add -A)
  out=$(cd "$edir" && bash "$real_script" --list font-size 2>/dev/null)
  echo "$out" | grep -q "Sources/E.swift:3:" || { echo "FAIL: empty-reason allow suppressed its line: [$out]" >&2; failed=1; }
  out=$(cd "$edir" && bash "$real_script" 2>&1 >/dev/null)
  echo "$out" | grep -q "bad allow: Sources/E.swift:3 (empty reason)" || { echo "FAIL: empty-reason line allow not reported: [$out]" >&2; failed=1; }
  echo "$out" | grep -q "bad allow: Sources/F.swift:1 (empty reason)" || { echo "FAIL: empty-reason allow-file not reported: [$out]" >&2; failed=1; }
  out=$(cd "$edir" && bash "$real_script" --list padding-literal 2>/dev/null)
  echo "$out" | grep -q "Sources/F.swift:4:" || { echo "FAIL: empty-reason allow-file suppressed its file: [$out]" >&2; failed=1; }
  rm -rf "$edir"

  # ---- Zero Swift files -> exit 2 ----
  local zdir=$(mktemp -d)
  mkdir -p "$zdir/Sources"
  (cd "$zdir" && git init -q && git add -A 2>/dev/null; bash "$real_script" >/dev/null 2>&1); rc=$?
  [ $rc -eq 2 ] || { echo "FAIL: zero-file repo exit=$rc want 2" >&2; failed=1; }
  rm -rf "$zdir"
}
