from pathlib import Path
import re

path = Path("ores-sops")
text = path.read_text(encoding="utf-8")

pattern = re.compile(r"(?ms)^count_exact_sops_rule\(\) \{.*?^\}\n\n(?=stage_rule_present\(\) \{)")
replacement = r'''count_exact_sops_rule() {
  local environment="$1" root
  need_env "$environment"
  root="$(repo_root)"
  [ -f "$root/.sops.yaml" ] || { printf '0\n'; return; }
  awk -v environment="$environment" '
    BEGIN {
      expected = "path_regex: ^env/enc/" environment "\\.env\\.enc$"
    }
    {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/^[[:space:]]*/, "", line)
      if (line == expected) count++
    }
    END { print count + 0 }
  ' "$root/.sops.yaml"
}

'''
text, count = pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit(f"count_exact_sops_rule replacement count: {count}")

old = "# The default local recipient scope is `all` for backward-compatible recovery."
new = "# The default local recipient scope is all for backward-compatible recovery."
if text.count(old) != 1:
    raise SystemExit(f"heredoc comment replacement count: {text.count(old)}")
text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
