from pathlib import Path

path = Path("scripts/apply-stage-contract.py")
text = path.read_text(encoding="utf-8")
start_marker = '''text = replace_once(
    text,
    ''' + "'''  case \"$target\" in"
end_marker = '''    "active_name",
)
'''
start = text.find(start_marker)
if start < 0:
    raise SystemExit("active_name migration start marker not found")
end = text.find(end_marker, start)
if end < 0:
    raise SystemExit("active_name migration end marker not found")
end += len(end_marker)
replacement = r'''text = replace_function(
    text,
    "active_name",
    "assert_root_env_manageable",
    r'''active_name() {
  local root target
  root="$(repo_root)"
  [ -L "$root/.env" ] || return 0
  target="$(readlink "$root/.env")"
  case "$target" in
    env/dec/dev.env) printf 'dev\n' ;;
    env/dec/stage.env) printf 'stage\n' ;;
    env/dec/prod.env) printf 'prod\n' ;;
    *) return 0 ;;
  esac
}''',
)
'''
path.write_text(text[:start] + replacement + text[end:], encoding="utf-8")
