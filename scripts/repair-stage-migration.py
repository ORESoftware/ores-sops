from pathlib import Path

path = Path("scripts/apply-stage-contract.py")
text = path.read_text(encoding="utf-8")


def replace_script_block(start_marker: str, end_marker: str, replacement: str, label: str) -> None:
    global text
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f"{label} migration start marker not found")
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f"{label} migration end marker not found")
    end += len(end_marker)
    text = text[:start] + replacement + text[end:]


replace_script_block(
    "text = replace_once(\n    text,\n    '''  case \"$target\" in",
    '    "active_name",\n)\n',
    """text = replace_function(
    text,
    \"active_name\",
    \"assert_root_env_manageable\",
    r'''active_name() {
  local root target
  root=\"$(repo_root)\"
  [ -L \"$root/.env\" ] || return 0
  target=\"$(readlink \"$root/.env\")\"
  case \"$target\" in
    env/dec/dev.env) printf 'dev\\n' ;;
    env/dec/stage.env) printf 'stage\\n' ;;
    env/dec/prod.env) printf 'prod\\n' ;;
    *) return 0 ;;
  esac
}''',
)
""",
    "active_name",
)

replace_script_block(
    "text = replace_once(\n    text,\n    '      env/dec/dev.env|env/dec/prod.env) ;;',",
    '    "root env allowlist",\n)\n',
    """text = replace_function(
    text,
    \"assert_root_env_manageable\",
    \"write_plaintext\",
    r'''assert_root_env_manageable() {
  local root target
  root=\"$(repo_root)\"
  if [ -e \"$root/.env\" ] || [ -L \"$root/.env\" ]; then
    [ -L \"$root/.env\" ] || fail \"refusing to overwrite unmanaged root .env\"
    target=\"$(readlink \"$root/.env\")\"
    case \"$target\" in
      env/dec/dev.env|env/dec/stage.env|env/dec/prod.env) ;;
      *) fail \"refusing to replace unmanaged .env symlink -> $target\" ;;
    esac
  fi
}''',
)
""",
    "root env allowlist",
)

path.write_text(text, encoding="utf-8")
