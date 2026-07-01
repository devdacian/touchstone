#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL="$ROOT_DIR/install.sh"

fail() {
  echo "test-install-output: $*" >&2
  exit 1
}

assert_contains() {
  file="$1"
  needle="$2"
  grep -F -- "$needle" "$file" >/dev/null || fail "$file missing: $needle"
}

assert_not_contains() {
  file="$1"
  needle="$2"
  if grep -F -- "$needle" "$file" >/dev/null; then
    fail "$file unexpectedly contains: $needle"
  fi
}

assert_absent() {
  path="$1"
  [ ! -e "$path" ] || fail "unexpected file/dir created: $path"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HOST_PARENT="$TMP_DIR/hosts"
HOST="$HOST_PARENT/host"
HOME_DIR="$TMP_DIR/home"
mkdir -p "$HOST" "$HOME_DIR"
mkdir -p "$HOST/.claude"
printf 'existing claude\n' > "$HOST/CLAUDE.md"
printf 'existing agents\n' > "$HOST/AGENTS.md"
printf 'existing readme\n' > "$HOST/README.md"
printf 'existing local settings\n' > "$HOST/.claude/settings.local.json"
HOST_ABS="$(cd "$HOST" && pwd -P)"
EXPECTED_REVERSE="$HOST_ABS/.touchstone/methodology/scripts/external-review/external-review-claude.sh"

(
  cd "$HOST_PARENT"
  HOME="$HOME_DIR" "$INSTALL" host > "$TMP_DIR/install.out" 2> "$TMP_DIR/install.err"
)

assert_contains "$TMP_DIR/install.out" "LOCAL RUNTIME SETUP FOR EXTERNAL REVIEW"
assert_contains "$TMP_DIR/install.out" ".claude/settings.local.json"
assert_contains "$TMP_DIR/install.out" "Bash(./.touchstone/methodology/scripts/external-review/external-review-codex.sh:*)"
assert_contains "$TMP_DIR/install.out" "prefix_rule("
assert_contains "$TMP_DIR/install.out" "pattern = [\"$EXPECTED_REVERSE\"]"
assert_not_contains "$TMP_DIR/install.out" "/absolute/path/to/repo"
assert_contains "$TMP_DIR/install.out" "Do NOT allowlist \"claude\", \"bash\", \"zsh\", \"env\""
assert_contains "$TMP_DIR/install.out" "repo-relative"
assert_contains "$TMP_DIR/install.out" "wildcard"
assert_contains "$TMP_DIR/install.out" "shell-wrapped"
assert_contains "$TMP_DIR/install.out" "exits 3"

test "$(cat "$HOST/CLAUDE.md")" = "existing claude" || fail "CLAUDE.md was modified"
test "$(cat "$HOST/AGENTS.md")" = "existing agents" || fail "AGENTS.md was modified"
test "$(cat "$HOST/README.md")" = "existing readme" || fail "README.md was modified"
test "$(cat "$HOST/.claude/settings.local.json")" = "existing local settings" || fail ".claude/settings.local.json was modified"
assert_absent "$HOST/.codex"
assert_absent "$HOME_DIR/.codex/config.toml"
assert_absent "$HOME_DIR/.codex/rules/default.rules"

IGNORE_HOST="$HOST_PARENT/ignore-host"
mkdir -p "$IGNORE_HOST"
HOME="$HOME_DIR" "$INSTALL" "$IGNORE_HOST" --ignore-all > "$TMP_DIR/ignore.out" 2> "$TMP_DIR/ignore.err"
assert_contains "$TMP_DIR/ignore.out" "LOCAL RUNTIME SETUP FOR EXTERNAL REVIEW"
assert_contains "$TMP_DIR/ignore.out" "prefix_rule("

QUOTED_HOST="$HOST_PARENT/host \"quoted"
mkdir -p "$QUOTED_HOST"
QUOTED_ABS="$(cd "$QUOTED_HOST" && pwd -P)"
QUOTED_REVERSE="$QUOTED_ABS/.touchstone/methodology/scripts/external-review/external-review-claude.sh"
HOME="$HOME_DIR" "$INSTALL" "$QUOTED_HOST" > "$TMP_DIR/quoted.out" 2> "$TMP_DIR/quoted.err"
assert_contains "$TMP_DIR/quoted.out" 'host \"quoted'

python3 - "$TMP_DIR/quoted.out" "$TMP_DIR/quoted.rules" <<'PY'
import sys

text = open(sys.argv[1], "r", encoding="utf-8").read().splitlines()
start = None
for idx, line in enumerate(text):
    if line.strip() == "prefix_rule(":
        start = idx
        break
if start is None:
    raise SystemExit("prefix_rule block missing")
block = []
for line in text[start:]:
    block.append(line.lstrip())
    if line.strip() == ")":
        break
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(block) + "\n")
PY

check_out="$(codex execpolicy check --rules "$TMP_DIR/quoted.rules" "$QUOTED_REVERSE" --prompt x --schema y --findings z --log l 2>/dev/null)"
printf '%s\n' "$check_out" > "$TMP_DIR/quoted.check"
assert_contains "$TMP_DIR/quoted.check" '"decision":"allow"'

echo "test-install-output: ok"
