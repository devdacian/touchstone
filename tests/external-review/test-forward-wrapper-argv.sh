#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ER_DIR="$ROOT_DIR/.touchstone/methodology/scripts/external-review"
WRAPPER="$ER_DIR/external-review-codex.sh"

fail() {
  echo "test-forward-wrapper-argv: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" > "$CODEX_ARGV_CAPTURE"

out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    out="$arg"
    break
  fi
  prev="$arg"
done

if [ -n "$out" ]; then
  printf '{"verdict":"no actionable findings","findings":[]}\n' > "$out"
fi

printf '{"type":"turn.completed","usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}\n'
FAKE
chmod +x "$TMP_DIR/codex"

PROMPT="$TMP_DIR/prompt.md"
SCHEMA="$TMP_DIR/schema.json"
printf 'review prompt\n' > "$PROMPT"
printf '{"type":"object"}\n' > "$SCHEMA"

run_success() {
  label="$1"
  shift
  local capture="$TMP_DIR/$label.argv"
  local findings="$TMP_DIR/$label.findings.json"
  local log="$TMP_DIR/$label.log"
  CODEX_ARGV_CAPTURE="$capture" PATH="$TMP_DIR:$PATH" "$WRAPPER" \
    --prompt "$PROMPT" \
    --schema "$SCHEMA" \
    --findings "$findings" \
    --log "$log" \
    --cd "$ROOT_DIR" \
    "$@" >/dev/null 2>&1
  [ -s "$capture" ] || fail "$label: fake codex was not invoked"
}

assert_no_capture_match() {
  label="$1"
  needle="$2"
  capture="$TMP_DIR/$label.argv"
  if grep -F -- "$needle" "$capture" >/dev/null; then
    fail "$label: unexpected argv token containing $needle"
  fi
}

assert_capture_match() {
  label="$1"
  needle="$2"
  capture="$TMP_DIR/$label.argv"
  if ! grep -F -- "$needle" "$capture" >/dev/null; then
    fail "$label: expected argv token containing $needle"
  fi
}

assert_search_before_exec() {
  label="$1"
  capture="$TMP_DIR/$label.argv"
  search_line="$(grep -n -F -- "--search" "$capture" | head -n 1 | cut -d: -f1 || true)"
  exec_line="$(grep -n -F -- "exec" "$capture" | head -n 1 | cut -d: -f1 || true)"
  [ -n "$search_line" ] || fail "$label: missing top-level --search"
  [ -n "$exec_line" ] || fail "$label: missing exec subcommand"
  [ "$search_line" -lt "$exec_line" ] || fail "$label: --search must appear before exec"
}

expect_config_error_without_invocation() {
  label="$1"
  shift
  local capture="$TMP_DIR/$label.argv"
  local findings="$TMP_DIR/$label.findings.json"
  local log="$TMP_DIR/$label.log"
  set +e
  CODEX_ARGV_CAPTURE="$capture" PATH="$TMP_DIR:$PATH" "$WRAPPER" \
    --prompt "$PROMPT" \
    --schema "$SCHEMA" \
    --findings "$findings" \
    --log "$log" \
    --cd "$ROOT_DIR" \
    "$@" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "$label: expected exit 2, got $status"
  [ ! -e "$capture" ] || fail "$label: fake codex should not be invoked"
}

stale_key="tools.web""_search"
stale_exact="--strict-config -c ${stale_key}=true"
web_disabled="web_search=disabled"

run_success default
assert_no_capture_match default "--search"
assert_no_capture_match default "--strict-config"
assert_no_capture_match default "$stale_key"
assert_capture_match default "$web_disabled"

run_success off --web-search off
assert_no_capture_match off "--search"
assert_no_capture_match off "--strict-config"
assert_no_capture_match off "$stale_key"
assert_capture_match off "$web_disabled"

run_success on --web-search on
assert_search_before_exec on
assert_no_capture_match on "--strict-config"
assert_no_capture_match on "$stale_key"
assert_no_capture_match on "$web_disabled"

expect_config_error_without_invocation invalid --web-search maybe
expect_config_error_without_invocation missing --web-search

if grep -R -n -F -- "$stale_exact" "$ROOT_DIR/.touchstone/methodology"; then
  fail "methodology contains stale exact forward web-search config"
fi

if grep -R -n -F -- "$stale_key" "$ROOT_DIR/.touchstone/methodology"; then
  fail "methodology contains stale forward web-search config key"
fi

echo "test-forward-wrapper-argv: ok"
