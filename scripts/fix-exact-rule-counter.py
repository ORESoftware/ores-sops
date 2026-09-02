from pathlib import Path

path = Path("ores-sops")
text = path.read_text(encoding="utf-8")
start_marker = "count_exact_sops_rule() {\n"
end_marker = "stage_rule_present() {\n"
start = text.find(start_marker)
if start < 0:
    raise SystemExit("count_exact_sops_rule start not found")
end = text.find(end_marker, start)
if end < 0:
    raise SystemExit("stage_rule_present boundary not found")
replacement = r'''count_exact_sops_rule() {
  local environment="$1" root expected line trimmed count=0
  need_env "$environment"
  root="$(repo_root)"
  [ -f "$root/.sops.yaml" ] || { printf '0\n'; return; }
  expected="path_regex: ^env/enc/${environment}\\.env\\.enc\$"

  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '- '*) trimmed="${trimmed#- }" ;;
    esac
    [ "$trimmed" = "$expected" ] && count=$((count + 1))
  done <"$root/.sops.yaml"

  printf '%s\n' "$count"
}

'''
path.write_text(text[:start] + replacement + text[end:], encoding="utf-8")
