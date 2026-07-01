#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ER_DIR="$ROOT_DIR/.touchstone/methodology/scripts/external-review"
WRAPPER="$ER_DIR/external-review-claude.sh"

fail() {
  echo "test-reverse-wrapper-argv: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

python3 - "$CLAUDE_ARGV_CAPTURE" "$@" <<'PY'
import json
import sys

with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(sys.argv[2:]) + "\n")
PY

if [ "$*" = "--setting-sources  auth status --json" ]; then
  printf 'fake auth child stderr\n' >&2
  if [ "${FAKE_CLAUDE_MODE:-success}" = "auth_fail" ]; then
    printf '{"loggedIn":false,"authMethod":"none","apiProvider":"none","subscriptionType":null}\n'
  else
    printf '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}\n'
  fi
  exit 0
fi

if [ "${1:-}" = "-p" ]; then
  printf 'fake review child stderr\n' >&2
  case "${FAKE_CLAUDE_MODE:-success}" in
    unhealthy)
      printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0,"usage":{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":1},"modelUsage":{},"structured_output":{"verdict":"no actionable findings","findings":[]}}\n'
      ;;
    *)
      printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0,"usage":{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":1},"modelUsage":{"claude-opus-4-8":{"inputTokens":1}},"structured_output":{"verdict":"no actionable findings","findings":[]}}\n'
      ;;
  esac
  exit 0
fi

printf 'unexpected claude argv: %s\n' "$*" >&2
exit 64
FAKE
chmod +x "$TMP_DIR/claude"

PROMPT="$TMP_DIR/prompt.md"
SCHEMA="$TMP_DIR/schema.json"
printf 'review prompt\n' > "$PROMPT"
printf '{"type":"object"}\n' > "$SCHEMA"

run_wrapper() {
  label="$1"
  shift
  local mode="${1:-success}"
  shift || true
  local capture="$TMP_DIR/$label.argv.jsonl"
  local findings="$TMP_DIR/$label.findings.json"
  local log="$TMP_DIR/$label.log"
  local wrapper_stderr="$TMP_DIR/$label.wrapper-stderr"
  local process_stderr="$TMP_DIR/$label.process-stderr"

  printf 'stale findings\n' > "$findings"
  printf 'stale log\n' > "$log"
  printf 'stale child stderr\n' > "$log.stderr"
  printf 'stale wrapper stderr\n' > "$wrapper_stderr"

  set +e
  CLAUDE_ARGV_CAPTURE="$capture" FAKE_CLAUDE_MODE="$mode" PATH="$TMP_DIR:$PATH" "$WRAPPER" \
    --prompt "$PROMPT" \
    --schema "$SCHEMA" \
    --findings "$findings" \
    --log "$log" \
    --wrapper-stderr-log "$wrapper_stderr" \
    "$@" > "$TMP_DIR/$label.stdout" 2> "$process_stderr"
  status=$?
  set -e

  printf '%s\n' "$status" > "$TMP_DIR/$label.status"
}

assert_file_contains() {
  file="$1"
  needle="$2"
  grep -F -- "$needle" "$file" >/dev/null || fail "$file missing $needle"
}

assert_file_not_contains() {
  file="$1"
  needle="$2"
  if grep -F -- "$needle" "$file" >/dev/null; then
    fail "$file unexpectedly contains $needle"
  fi
}

assert_argv_contains() {
  capture="$1"
  expr="$2"
  python3 - "$capture" "$expr" <<'PY' || fail "argv assertion failed: $expr"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    calls = [json.loads(line) for line in fh if line.strip()]
expr = sys.argv[2]
if not eval(expr, {"__builtins__": {}}, {"calls": calls, "any": any, "len": len}):
    raise SystemExit(1)
PY
}

run_wrapper success success
[ "$(cat "$TMP_DIR/success.status")" = "0" ] || fail "success run did not exit 0"
assert_file_contains "$TMP_DIR/success.wrapper-stderr" "external-review-claude: AUTH OK"
assert_file_contains "$TMP_DIR/success.wrapper-stderr" "external-review-claude: USAGE"
assert_file_contains "$TMP_DIR/success.wrapper-stderr" "external-review-claude: HEALTHY"
assert_file_contains "$TMP_DIR/success.process-stderr" "external-review-claude: HEALTHY"
assert_file_contains "$TMP_DIR/success.log.stderr" "fake auth child stderr"
assert_file_contains "$TMP_DIR/success.log.stderr" "fake review child stderr"
assert_file_not_contains "$TMP_DIR/success.log.stderr" "external-review-claude: AUTH OK"
assert_file_not_contains "$TMP_DIR/success.log.stderr" "external-review-claude: HEALTHY"
assert_file_not_contains "$TMP_DIR/success.findings.json" "stale findings"
assert_file_not_contains "$TMP_DIR/success.log" "stale log"
assert_file_not_contains "$TMP_DIR/success.log.stderr" "stale child stderr"
assert_file_not_contains "$TMP_DIR/success.wrapper-stderr" "stale wrapper stderr"
assert_file_contains "$TMP_DIR/success.findings.json" '"verdict": "no actionable findings"'
assert_argv_contains "$TMP_DIR/success.argv.jsonl" 'any("-p" in call and "--tools" in call and "" in call for call in calls)'
assert_argv_contains "$TMP_DIR/success.argv.jsonl" 'not any("--add-dir" in call for call in calls)'

run_wrapper repo_web success --repo "$ROOT_DIR" --web-search on
[ "$(cat "$TMP_DIR/repo_web.status")" = "0" ] || fail "repo/web run did not exit 0"
assert_argv_contains "$TMP_DIR/repo_web.argv.jsonl" 'any("-p" in call and "Read,Grep,Glob,WebSearch,WebFetch" in call for call in calls)'
assert_argv_contains "$TMP_DIR/repo_web.argv.jsonl" 'any("-p" in call and "--permission-mode" in call and "auto" in call for call in calls)'
assert_argv_contains "$TMP_DIR/repo_web.argv.jsonl" 'not any("-p" in call and ("Bash" in ",".join(call) or "Write" in ",".join(call) or "Edit" in ",".join(call)) for call in calls)'

run_wrapper auth_fail auth_fail
[ "$(cat "$TMP_DIR/auth_fail.status")" = "3" ] || fail "auth failure did not exit 3"
assert_file_contains "$TMP_DIR/auth_fail.wrapper-stderr" "external-review-claude: AUTH PREFLIGHT FAILED"
assert_argv_contains "$TMP_DIR/auth_fail.argv.jsonl" 'len(calls) == 1 and not any("-p" in call for call in calls)'

run_wrapper unhealthy unhealthy
[ "$(cat "$TMP_DIR/unhealthy.status")" = "1" ] || fail "unhealthy run did not exit 1"
assert_file_contains "$TMP_DIR/unhealthy.wrapper-stderr" "external-review-claude: USAGE"
assert_file_contains "$TMP_DIR/unhealthy.wrapper-stderr" "external-review-claude: UNHEALTHY requested model"
assert_file_contains "$TMP_DIR/unhealthy.wrapper-stderr" "external-review-claude: UNHEALTHY -- inspect"

# Collision before touch: nonexistent outputs remain nonexistent.
collision_log="$TMP_DIR/collision.log"
collision_findings="$TMP_DIR/collision.findings.json"
set +e
CLAUDE_ARGV_CAPTURE="$TMP_DIR/collision.argv.jsonl" PATH="$TMP_DIR:$PATH" "$WRAPPER" \
  --prompt "$PROMPT" \
  --schema "$SCHEMA" \
  --findings "$collision_findings" \
  --log "$collision_log" \
  --wrapper-stderr-log "$collision_findings" > "$TMP_DIR/collision.stdout" 2> "$TMP_DIR/collision.stderr"
collision_status=$?
set -e
[ "$collision_status" -eq 2 ] || fail "collision did not exit 2"
[ ! -e "$collision_log" ] || fail "collision created log before failing"
[ ! -e "$collision_log.stderr" ] || fail "collision created child stderr before failing"
[ ! -e "$collision_findings" ] || fail "collision created shared findings/wrapper stderr before failing"

# Collision before touch: existing outputs keep content.
preserve_log="$TMP_DIR/preserve.log"
preserve_findings="$TMP_DIR/preserve.findings.json"
preserve_wrapper="$TMP_DIR/preserve.wrapper-stderr"
printf 'old log\n' > "$preserve_log"
printf 'old findings\n' > "$preserve_findings"
printf 'old wrapper\n' > "$preserve_wrapper"
set +e
CLAUDE_ARGV_CAPTURE="$TMP_DIR/preserve.argv.jsonl" PATH="$TMP_DIR:$PATH" "$WRAPPER" \
  --prompt "$PROMPT" \
  --schema "$SCHEMA" \
  --findings "$preserve_findings" \
  --log "$preserve_log" \
  --wrapper-stderr-log "$preserve_findings" > "$TMP_DIR/preserve.stdout" 2> "$TMP_DIR/preserve.stderr"
preserve_status=$?
set -e
[ "$preserve_status" -eq 2 ] || fail "preserve collision did not exit 2"
[ "$(cat "$preserve_log")" = "old log" ] || fail "collision changed existing log"
[ "$(cat "$preserve_findings")" = "old findings" ] || fail "collision changed existing findings"
[ "$(cat "$preserve_wrapper")" = "old wrapper" ] || fail "collision changed unrelated wrapper file"

echo "test-reverse-wrapper-argv: ok"
