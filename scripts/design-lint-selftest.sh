# design-lint-selftest.sh — self-test fixtures and runner for design-lint.sh
# Sourced by design-lint.sh --self-test

run_self_test() {
  echo "Running self-test..."
  
  local tmpdir=$(mktemp -d)
  cd "$tmpdir"
  git init -q
  git config user.email "test@test"
  git config user.name "Test"
  mkdir -p Sources Tests

  cat > Sources/Rule1.swift <<'EOF'
.font(.system(size: 12))
.font(.system(size: 14)) // design-lint: allow font-size test
// comment .font(.system(size: 16))
EOF

  cat > Sources/Rule2.swift <<'EOF'
.padding(8)
.padding(.horizontal, 12) // design-lint: allow padding-literal test
.padding()
EOF

  cat > Sources/Rule3.swift <<'EOF'
spacing: 8
spacing: 4 // design-lint: allow spacing-literal test
// comment spacing: 12
EOF

  cat > Sources/Rule4.swift <<'EOF'
cornerRadius: 8
.cornerRadius(12) // design-lint: allow radius-literal test
.radius: 0
EOF

  cat > Sources/Rule5.swift <<'EOF'
Color(hex: "FF0000")
Color(hex: 0xFF0000)
"#FF0000"
Color(hex: "00FF00") // design-lint: allow hex-color test
NSColor(hex: "0000FF")
EOF

  cat > Sources/Rule6.swift <<'EOF'
Color(red: 1, green: 0, blue: 0)
Color.blue
.foregroundStyle(.red)
.fill(.blue)
.background(.green)
.stroke(.orange)
.tint(.purple)
.border(.gray)
Color(white: 0.5) // design-lint: allow raw-color test
EOF

  cat > Sources/Rule7.swift <<'EOF'
Button("Test") {}
Toggle("Test", isOn: .constant(true))
TextField("Test", text: .constant(""))
SecureField("Test", text: .constant(""))
Picker("Test", selection: .constant(0)) {}
.sheet(isPresented: .constant(true)) {}
.popover(isPresented: .constant(true)) {}
.contextMenu {} // design-lint: allow raw-control test
AinkradButton("Test") {}
ColorPicker("Test", selection: .constant(.red))
AinkradTextField("Test", text: .constant(""))
EOF

  cat > Sources/Rule13.swift <<'EOF'
.opacity(0.5)
.opacity(on ? 0.6 : 1)
.opacity(0)
.opacity(1)
.opacity(1.0)
.opacity(on ? 1 : 0)
.opacity(skin.opacity.dim)
.opacity(.4) // design-lint: allow opacity-literal test
// comment .opacity(0.3)
EOF

  cat > Sources/Rule14.swift <<'EOF'
.frame(maxWidth: .infinity, minHeight: 28)
.frame(width: 100)
.frame(maxWidth: .infinity)
.frame(width: 0)
.frame(width: size)
.frame(height: 50) // design-lint: allow frame-literal test
// comment .frame(height: 50)
EOF

  cat > Sources/Rule15.swift <<'EOF'
ChamferShape(cut: size * 0.3)
.cornerBrackets(length: 8, inset: -2)
ChamferShape(cut: AinkradRadius.md)
.cornerBrackets(length: 4, inset: 1) // design-lint: allow chamfer-literal test
// comment ChamferShape(cut: 4)
EOF

  cat > Sources/Rule16.swift <<'EOF'
.spring(response: 0.3, dampingFraction: 0.8)
.delay(0.1)
withAnimation(.easeInOut)
withAnimation(skin.motion.quick)
Task.sleep(for: .seconds(2))
.spring(response: 0.5) // design-lint: allow motion-literal test
// comment .spring(response: 0.5)
EOF

  cat > Sources/Rule17.swift <<'EOF'
ChamferShape(cut: radius, corners: .all)
ChamferShape()
skin.shape(cut: radius)
AinkradSkinShape(token: tile.shape)
ChamferCorners.diagonal
ChamferShape(cut: radius) // design-lint: allow chamfer-direct test
// comment ChamferShape(cut: radius)
EOF

  cat > Sources/Rule9.swift <<'EOF'
let a = try! decode(data)
let b = try! parse(text) // design-lint: allow try-bang test
// comment try! decode(data)
EOF

  cat > Sources/Rule10.swift <<'EOF'
let c = obj as! Widget
let d = ref as! Service // design-lint: allow force-cast test
// comment x as! Widget
EOF

  cat > Sources/Rule11.swift <<'EOF'
let a = value!.count
let b = foo()!
let c = x!
let d = dict["k"]!
var s: URLSession!
let f = store[key]! // design-lint: allow force-unwrap test
if a != b {}
let g = !flag
// comment x!
EOF

  cat > Sources/Rule12.swift <<'EOF'
print("hello")
debugPrint(state)
NSLog("n") // design-lint: allow print test
logger.print("x")
blueprint("y")
// comment print("z")
EOF

  cat > Sources/CommentSkip.swift <<'EOF'
/// COMMENT-MUST-NOT-COUNT font-size .font(.system(size: 99))
/// COMMENT-MUST-NOT-COUNT hex-color project stored `#FF0000`
/// COMMENT-MUST-NOT-COUNT chamfer There were two — `ChamferShape(cut: 6)`
   /// COMMENT-MUST-NOT-COUNT raw-control Button("X") {}
// COMMENT-MUST-NOT-COUNT raw-color Theme surface, not `Color.gray`
// COMMENT-MUST-NOT-COUNT opacity .opacity(0.5)
// COMMENT-MUST-NOT-COUNT frame .frame(width: 99)
// COMMENT-MUST-NOT-COUNT motion .delay(0.1)
// COMMENT-MUST-NOT-COUNT radius .cornerRadius(12)
// COMMENT-MUST-NOT-COUNT padding .padding(8)
// COMMENT-MUST-NOT-COUNT spacing spacing: 8
/* COMMENT-MUST-NOT-COUNT raw-control Toggle("X", isOn: .constant(true)) */
/* COMMENT-MUST-NOT-COUNT opacity .opacity(0.7) */
   * COMMENT-MUST-NOT-COUNT frame .frame(height: 50)
   * COMMENT-MUST-NOT-COUNT motion .spring(response: 0.5)
 // COMMENT-MUST-NOT-COUNT try-bang try! decode(data)
 // COMMENT-MUST-NOT-COUNT force-cast x as! Widget
 // COMMENT-MUST-NOT-COUNT force-unwrap let h = maybe[key]!
 // COMMENT-MUST-NOT-COUNT print print("z")
EOF

  cat > Sources/AllowFile.swift <<'EOF'
// design-lint: allow-file font-size,padding-literal theme layer
.font(.system(size: 12))
.padding(8)
EOF

  for i in {1..500}; do echo "line $i"; done > Tests/FileLength500.swift
  for i in {1..501}; do echo "line $i"; done > Tests/FileLength501.swift
  echo '// design-lint: allow-file file-length over-long test fixture' > Tests/FileLengthAllowed.swift
  for i in {1..501}; do echo "line $i"; done >> Tests/FileLengthAllowed.swift

  git add -A
  git commit -q -m "fixtures"

  local real_script="$SELF_TEST_DIR/design-lint.sh"
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(collect_files 0)
  
  local counts=()
  local allowed_counts=()
  local i=0
  while [ $i -lt ${#rule_names[@]} ]; do
    counts+=("0")
    allowed_counts+=("0")
    i=$((i + 1))
  done

  local bad_allows=()

  # try!/as! precedence (mirrors the engine): resolve the two rules' patterns
  # once; a line hitting either is never a force-unwrap hit.
  local try_pat="" cast_pat=""
  local pi=0
  while [ $pi -lt ${#rule_names[@]} ]; do
    [ "${rule_names[$pi]}" = "try-bang" ] && try_pat="${rule_patterns[$pi]}"
    [ "${rule_names[$pi]}" = "force-cast" ] && cast_pat="${rule_patterns[$pi]}"
    pi=$((pi + 1))
  done
    
  for file in "${files[@]}"; do
    local file_allows=()
    local lineno=0
    while IFS= read -r line; do
      lineno=$((lineno + 1))
      [ $lineno -gt 10 ] && break
      if [[ "$line" =~ //[[:space:]]*design-lint:[[:space:]]*allow-file[[:space:]]+([^[:space:]]+)[[:space:]]+(.+) ]]; then
        local rule_list="${BASH_REMATCH[1]}" reason="${BASH_REMATCH[2]}"
        IFS=',' read -ra rules <<< "$rule_list"
        for rule in "${rules[@]}"; do
          rule=$(echo "$rule" | xargs)
          local found=0
          local i=0
          while [ $i -lt ${#rule_names[@]} ]; do
            [ "${rule_names[$i]}" = "$rule" ] && found=1 && break
            i=$((i + 1))
          done
          if [ $found -eq 1 ]; then
            file_allows+=("$rule")
          else
            CHECK_BAD_ALLOWS+=("bad allow: $file:$lineno (unknown rule: $rule)")
          fi
        done
        [ -z "${reason// }" ] && CHECK_BAD_ALLOWS+=("bad allow: $file:$lineno (empty reason)")
      fi
    done < "$file"

    lineno=0
    while IFS= read -r line; do
      lineno=$((lineno + 1))
      
      is_comment_line "$line" && continue
      
      local ri=0
      while [ $ri -lt ${#rule_names[@]} ]; do
        local rname="${rule_names[$ri]}"
        local scope="${rule_scopes[$ri]}"
        local pattern="${rule_patterns[$ri]}"
        [ "$scope" = "Sources" ] && [[ "$file" != Sources/* ]] && { ri=$((ri + 1)); continue; }
        # file-length has no line pattern (one wc -l over the array); its
        # count is asserted through the real engine below.
        [ "$rname" = "file-length" ] && { ri=$((ri + 1)); continue; }
        # try!/as! precedence (mirrors the engine): a line hitting either of
        # those rules is never a force-unwrap hit.
        if [ "$rname" = "force-unwrap" ]; then
          if echo "$line" | grep -qE "$try_pat" || echo "$line" | grep -qE "$cast_pat"; then
            ri=$((ri + 1)); continue
          fi
        fi
        
        if echo "$line" | grep -qE "$pattern"; then
          local is_allowed=0
          if [[ "$line" =~ //[[:space:]]*design-lint:[[:space:]]*allow[[:space:]]+([^[:space:]]+)[[:space:]]+(.+) ]]; then
            local rule_list="${BASH_REMATCH[1]}" reason="${BASH_REMATCH[2]}"
            IFS=',' read -ra rules <<< "$rule_list"
            for rule in "${rules[@]}"; do
              rule=$(echo "$rule" | xargs)
              if [ "$rule" = "$rname" ]; then
                is_allowed=1
                break
              fi
            done
          fi
          if [ $is_allowed -eq 0 ]; then
            for a in "${file_allows[@]}"; do [ "$a" = "$rname" ] && is_allowed=1 && break; done
          fi
          
          if [ $is_allowed -eq 1 ]; then
            allowed_counts[$ri]=$((${allowed_counts[$ri]} + 1))
          else
            counts[$ri]=$((${counts[$ri]} + 1))
          fi
        fi
        ri=$((ri + 1))
      done
    done < "$file"
  done

  local failed=0
  local ri=0
  while [ $ri -lt ${#rule_names[@]} ]; do
    local rname="${rule_names[$ri]}"
    local count=${counts[$ri]:-0}
    local allowed=${allowed_counts[$ri]:-0}
    local expected=1
    local expected_allowed=1
    
    case "$rname" in
      # file-length is skipped in the loop above (wc-based); its count is
      # asserted through the real engine below.
      "file-length") expected=0; expected_allowed=0 ;;
      "font-size") expected=1; expected_allowed=2 ;;
      "padding-literal") expected=1; expected_allowed=2 ;;
      "spacing-literal") expected=1; expected_allowed=1 ;;
      "radius-literal") expected=2; expected_allowed=1 ;;
      "hex-color") expected=4; expected_allowed=1 ;;
      "raw-color") expected=8; expected_allowed=1 ;;
      "raw-control") expected=7; expected_allowed=1 ;;
      "try-bang") expected=1; expected_allowed=1 ;;
      "force-cast") expected=1; expected_allowed=1 ;;
      # force-unwrap: the five must-match lines counted, the Rule11 allow
      # line allowed; Rule9/Rule10 try!/as! lines are excluded by precedence
      # (try! and as! are must-not-match for this rule).
      "force-unwrap") expected=5; expected_allowed=1 ;;
      "print") expected=2; expected_allowed=1 ;;
      "opacity-literal") expected=2; expected_allowed=1 ;;
      "frame-literal") expected=2; expected_allowed=1 ;;
      "chamfer-literal") expected=2; expected_allowed=1 ;;
      "motion-literal") expected=2; expected_allowed=1 ;;
      # chamfer-direct: Rule17's two bare ChamferShape( lines plus Rule15's two.
      "chamfer-direct") expected=4; expected_allowed=1 ;;
    esac
    
    if [ $count -ne $expected ]; then
      echo "FAIL: $rname count=$count expected=$expected" >&2
      failed=1
    fi
    if [ $allowed -ne $expected_allowed ]; then
      echo "FAIL: $rname allowed=$allowed expected=$expected_allowed" >&2
      failed=1
    fi
    ri=$((ri + 1))
  done

  if [ ${#CHECK_BAD_ALLOWS[@]} -gt 0 ]; then
    for ba in "${CHECK_BAD_ALLOWS[@]}"; do echo "$ba" >&2; done
  fi

  local fl500=0 fl501=0
  for file in "${files[@]}"; do
    local lines=$(wc -l < "$file")
    [ $lines -gt 500 ] && fl501=$((fl501 + 1)) || fl500=$((fl500 + 1))
  done
  [ $fl501 -eq 2 ] || { echo "FAIL: file-length should catch 2 files (501 lines), got $fl501" >&2; failed=1; }
  [ $fl500 -ge 1 ] || { echo "FAIL: file-length should not catch 500-line file" >&2; failed=1; }

  # file-length through the REAL engine: --list shows the 501-line file only
  # (the 500-line and the allow-file ones absent), with file:lines shape.
  local fllist
  fllist=$(bash "$real_script" --list file-length 2>/dev/null || true)
  echo "$fllist" | grep -q "Tests/FileLength501.swift:501:" || { echo "FAIL: --list file-length misses Tests/FileLength501.swift:501" >&2; failed=1; }
  echo "$fllist" | grep -q "FileLength500" && { echo "FAIL: --list file-length shows the 500-line file" >&2; failed=1; }
  echo "$fllist" | grep -q "FileLengthAllowed" && { echo "FAIL: --list file-length shows the allow-file fixture" >&2; failed=1; }
  [ "$(echo "$fllist" | grep -c .)" -eq 1 ] || { echo "FAIL: --list file-length lists $fllist, want 1 line" >&2; failed=1; }

  # Hygiene counts through the REAL engine: rebaseline the fixture repo, then
  # read count/allowed off the table for each new rule.
  (bash "$real_script" --rebaseline >/dev/null 2>&1)
  local hrule hwant hgot
  for hrule in "file-length 1 1" "try-bang 1 1" "force-cast 1 1" "force-unwrap 5 1" "print 2 1"; do
    set -- $hrule
    hwant="$2 $3"
    hgot=$(bash "$real_script" 2>/dev/null | awk -v r="$1" '$1==r {print $2, $4}')
    [ "$hgot" = "$hwant" ] || { echo "FAIL: real-engine $1 table got [$hgot] want [$hwant]" >&2; failed=1; }
  done

  # Bugs 1+2 regression: exercise the REAL grep+awk engine (not the loop
  # above) on these fixtures. (1) No comment-only fixture line may be
  # listed or counted — covers ///, //, /* and * prefixes. (2) Every
  # --list line must be <file>:<line>: shaped, never <rule>:0:.
  local r
  for r in "${rule_names[@]}"; do
    local out
    out=$(bash "$real_script" --list "$r" 2>/dev/null || true)
    if echo "$out" | grep -q "COMMENT-MUST-NOT-COUNT"; then
      echo "FAIL: --list $r leaks comment lines" >&2
      failed=1
    fi
    while IFS= read -r l; do
      [ -z "$l" ] && continue
      case "$l" in
        Sources/*:[1-9]*:*) ;;
        Tests/*:[1-9]*:*) ;; # file-length scope covers Tests/
        *) echo "FAIL: --list $r bad shape: $l" >&2; failed=1 ;;
      esac
      case "$l" in
        "$r":*) echo "FAIL: --list $r prints rule instead of file: $l" >&2; failed=1 ;;
      esac
      case "$l" in
        *:0:*) echo "FAIL: --list $r prints lineno 0: $l" >&2; failed=1 ;;
      esac
    done <<< "$out"
  done
  if ! bash "$real_script" --list raw-control 2>/dev/null | grep -q 'Sources/Rule7.swift:.*Button'; then
    echo "FAIL: --list raw-control misses the real Rule7 Button hit" >&2
    failed=1
  fi

  # Allows regression: the exact repro plus multi-rule and allow-file
  # variants, all through the REAL engine, asserting count/allowed numbers.
  # Single-rule line allow: one hit suppressed, one counted.
  local repro1=$(mktemp -d)
  mkdir -p "$repro1/Sources"
  cat > "$repro1/Sources/A.swift" <<'EOF'
import SwiftUI
struct V: View { var body: some View {
  Text("x").font(.system(size: 10)) // design-lint: allow font-size test reason
  Text("y").font(.system(size: 11))
} }
EOF
  (cd "$repro1" && git init -q && git add -A)
  (cd "$repro1" && bash "$real_script" --rebaseline >/dev/null 2>&1)
  local got
  got=$(cd "$repro1" && bash "$real_script" 2>/dev/null | awk '$1=="font-size" {print $2, $4}')
  [ "$got" = "1 1" ] || { echo "FAIL: repro font-size table got [$got] want [1 1]" >&2; failed=1; }
  local lst
  lst=$(cd "$repro1" && bash "$real_script" --list font-size 2>/dev/null)
  if echo "$lst" | grep -q ":3:"; then
    echo "FAIL: --list font-size still shows the allowed line 3" >&2
    failed=1
  fi
  if ! echo "$lst" | grep -q "Sources/A.swift:4:"; then
    echo "FAIL: --list font-size misses the counted line 4" >&2
    failed=1
  fi

  # Multi-rule line allow: one line suppressed under both rules, controls counted.
  local repro2=$(mktemp -d)
  mkdir -p "$repro2/Sources"
  cat > "$repro2/Sources/B.swift" <<'EOF'
import SwiftUI
struct W: View { var body: some View {
  V().padding(8).opacity(0.5) // design-lint: allow padding-literal,opacity-literal test reason
  V().padding(4)
  V().opacity(0.6)
} }
EOF
  (cd "$repro2" && git init -q && git add -A)
  (cd "$repro2" && bash "$real_script" --rebaseline >/dev/null 2>&1)
  got=$(cd "$repro2" && bash "$real_script" 2>/dev/null | awk '$1=="padding-literal" {print $2, $4}')
  [ "$got" = "1 1" ] || { echo "FAIL: multi-rule padding table got [$got] want [1 1]" >&2; failed=1; }
  got=$(cd "$repro2" && bash "$real_script" 2>/dev/null | awk '$1=="opacity-literal" {print $2, $4}')
  [ "$got" = "1 1" ] || { echo "FAIL: multi-rule opacity table got [$got] want [1 1]" >&2; failed=1; }
  lst=$(cd "$repro2" && bash "$real_script" --list padding-literal 2>/dev/null)
  if echo "$lst" | grep -q ":3:"; then
    echo "FAIL: --list padding-literal still shows the allowed line 3" >&2
    failed=1
  fi
  if ! echo "$lst" | grep -q "Sources/B.swift:4:"; then
    echo "FAIL: --list padding-literal misses the counted line 4" >&2
    failed=1
  fi

  # Allow-file: whole file suppressed for that rule only; --list is empty, not one blank line.
  local repro3=$(mktemp -d)
  mkdir -p "$repro3/Sources"
  cat > "$repro3/Sources/C.swift" <<'EOF'
// design-lint: allow-file font-size theme layer
.font(.system(size: 12))
.font(.system(size: 13))
.padding(8)
EOF
  (cd "$repro3" && git init -q && git add -A)
  (cd "$repro3" && bash "$real_script" --rebaseline >/dev/null 2>&1)
  got=$(cd "$repro3" && bash "$real_script" 2>/dev/null | awk '$1=="font-size" {print $2, $4}')
  [ "$got" = "0 2" ] || { echo "FAIL: allow-file font-size table got [$got] want [0 2]" >&2; failed=1; }
  got=$(cd "$repro3" && bash "$real_script" 2>/dev/null | awk '$1=="padding-literal" {print $2, $4}')
  [ "$got" = "1 0" ] || { echo "FAIL: allow-file padding table got [$got] want [1 0]" >&2; failed=1; }
  lst=$(cd "$repro3" && bash "$real_script" --list font-size 2>/dev/null)
  [ -z "$lst" ] || { echo "FAIL: --list font-size not empty under allow-file: [$lst]" >&2; failed=1; }
  if ! (cd "$repro3" && bash "$real_script" --list-allows 2>/dev/null | grep -q "Sources/C.swift:1: allow-file font-size"); then
    echo "FAIL: --list-allows misses the allow-file entry" >&2
    failed=1
  fi
  rm -rf "$repro1" "$repro2" "$repro3"

  run_ratchet_self_test

  cd - >/dev/null
  rm -rf "$tmpdir"
  
  [ $failed -eq 0 ] && echo "self-test: PASS" || echo "self-test: FAIL" >&2
  return $failed
}