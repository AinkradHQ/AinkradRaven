BEGIN {
  split(line_allows, line_allows_arr, "\x01")
  split(file_allows, file_allows_arr, "\x01")
  mode = ENVIRON["AWK_MODE"]
  list_rule = ENVIRON["AWK_LIST_RULE"]
  
  # Initialize counts for all rules
  split("font-size,padding-literal,spacing-literal,radius-literal,hex-color,raw-color,raw-control,file-length,try-bang,force-cast,force-unwrap,print,opacity-literal,frame-literal,chamfer-literal,motion-literal,chamfer-direct", rule_list, ",")
  for (i in rule_list) {
    count[rule_list[i]] = 0
    allowed_count[rule_list[i]] = 0
  }
}
{
  # Parse input: RULE:file:lineno:content
  full_line = $0
  rule_name = ""
  file = ""
  lineno = 0
  content = ""
  
  # Extract rule name (first field before first colon)
  i = index(full_line, ":")
  if (i > 0) {
    rule_name = substr(full_line, 1, i-1)
    rest = substr(full_line, i+1)
    
    # Extract file (next field before colon)
    j = index(rest, ":")
    if (j > 0) {
      file = substr(rest, 1, j-1)
      rest2 = substr(rest, j+1)
      
      # Extract lineno (next field before colon)
      k = index(rest2, ":")
      if (k > 0) {
        lineno = substr(rest2, 1, k-1) + 0
        content = substr(rest2, k+1)
      }
    }
  }
  
  # Skip comment lines: any line whose text after leading whitespace
  # starts with ///, //, /* or *. (content here is the raw source line —
  # the rule:file:lineno: prefix was stripped above — so doc comments
  # must be dropped here, not just in the bash is_comment_line path.)
  trimmed = content
  sub(/^[[:space:]]*/, "", trimmed)
  if (trimmed ~ /^\/\/\// || trimmed ~ /^\/\// || trimmed ~ /^\/\*/ || trimmed ~ /^\*/) next
  
  # Check line allows
  allowed = 0
  for (i in line_allows_arr) {
    split(line_allows_arr[i], parts, "|")
    if (parts[1] == file && parts[2] == lineno) {
      split(parts[3], rules, " ")
      for (j in rules) {
        if (rules[j] == rule_name) {
          allowed = 1
          break
        }
      }
    }
    if (allowed) break
  }
  
  if (!allowed) {
    for (i in file_allows_arr) {
      split(file_allows_arr[i], parts, "|")
      if (parts[1] == file) {
        split(parts[2], rules, " ")
        for (j in rules) {
          if (rules[j] == rule_name) {
            allowed = 1
            break
          }
        }
      }
      if (allowed) break
    }
  }
  
  # Allowed lines leave count and --list, and increment allowed.
  if (allowed) allowed_count[rule_name]++
  else {
    count[rule_name]++
    if (mode == "list" && list_rule == rule_name) {
      print file ":" lineno ": " content
    }
  }
}
END {
  if (ENVIRON["AWK_MODE"] == "list") exit 0
  for (r in count) {
    print r ":" count[r] ":" allowed_count[r]
  }
}