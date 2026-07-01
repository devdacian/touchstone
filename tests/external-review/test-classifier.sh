#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ER_DIR="$ROOT_DIR/.touchstone/methodology/scripts/external-review"
CLASSIFIER="$ER_DIR/classify_external_review_failure.py"

fail() {
  echo "test-classifier: $*" >&2
  exit 1
}

run_case() {
  python3 "$CLASSIFIER"
}

assert_json_field() {
  json="$1"
  expr="$2"
  python3 - "$expr" "$json" <<'PY'
import json
import sys

expr = sys.argv[1]
data = json.loads(sys.argv[2])
if not eval(expr, {"__builtins__": {}}, {"data": data}):
    raise SystemExit(1)
PY
}

base_envelope='{
  "type": "result",
  "subtype": "success",
  "is_error": true,
  "api_error_status": 401,
  "result": "Failed to authenticate. API Error: 401 Invalid authentication credentials",
  "total_cost_usd": 0,
  "usage": {
    "input_tokens": 0,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0,
    "output_tokens": 0
  },
  "modelUsage": {}
}'

positive="$(
  python3 -c 'import json,sys; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "argv":["external-review-claude.sh","--repo","."],
    "read_root_flag":"--repo",
    "diff_inlined":True,
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max) -- first-party subscription, proceeding",
    "result_envelope":json.loads(sys.stdin.read()),
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$positive" 'data["classification"] == "reverse_wrapper_post_preflight_auth_transient"' || fail "positive case did not classify"
assert_json_field "$positive" 'data["prompt_exports_repo_diff"] is True' || fail "positive case did not mark repo/diff export"
assert_json_field "$positive" 'data["allow_unsandboxed_retry"] is False' || fail "positive case allowed unsandboxed retry"

missing_auth="$(
  python3 -c 'import json,sys; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: UNHEALTHY -- inspect log",
    "result_envelope":json.loads(sys.stdin.read()),
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$missing_auth" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "missing AUTH OK classified"

ambiguous_stderr="$(
  python3 -c 'import json,sys; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "result_envelope":json.loads(sys.stdin.read()),
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$ambiguous_stderr" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "generic stderr classified as wrapper stderr"

auth_in_reviewer_stderr="$(
  python3 -c 'import json,sys; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"",
    "reviewer_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "result_envelope":json.loads(sys.stdin.read()),
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$auth_in_reviewer_stderr" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "AUTH OK from reviewer stderr classified"

truncated_excerpt="$(
  python3 -c 'import json; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "log_excerpt":"{\"api_error_status\": 401"
  }))' | run_case
)"
assert_json_field "$truncated_excerpt" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "truncated excerpt classified"

wording_drift="$(
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); d["result"]="401 credentials rejected"; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "result_envelope":d,
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$wording_drift" 'data["classification"] == "reverse_wrapper_post_preflight_auth_transient"' || fail "wording drift blocked structured classification"

for mutation in input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens; do
  nonzero="$(
    python3 -c 'import json,sys; key=sys.argv[1]; d=json.loads(sys.stdin.read()); d["usage"][key]=1; print(json.dumps({
      "runtime":"codex-cli",
      "attempted_wrapper":"external-review-claude.sh",
      "exit_code":1,
      "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
      "result_envelope":d,
    }))' "$mutation" <<<"$base_envelope" | run_case
  )"
  assert_json_field "$nonzero" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "nonzero $mutation classified"
done

bool_counter="$(
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); d["usage"]["input_tokens"]=False; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "result_envelope":d,
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$bool_counter" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "bool counter classified"

missing_usage="$(
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); d.pop("usage"); print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "result_envelope":d,
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$missing_usage" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "missing usage classified"

nonempty_model_usage="$(
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); d["modelUsage"]={"claude-opus-4-8":{"inputTokens":1}}; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "result_envelope":d,
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$nonempty_model_usage" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "non-empty modelUsage classified"

wrong_wrapper="$(printf '%s\n' '{"runtime":"codex-cli","attempted_wrapper":"external-review-codex.sh","exit_code":1}' | run_case)"
assert_json_field "$wrong_wrapper" 'data["classification"] == "wrong_wrapper_local_init"' || fail "wrong wrapper not classified"
assert_json_field "$wrong_wrapper" 'data["recommended_wrapper"] == "external-review-claude.sh"' || fail "wrong wrapper did not recommend reverse wrapper"
assert_json_field "$wrong_wrapper" 'data["allow_unsandboxed_retry"] is False' || fail "wrong wrapper allowed unsandboxed retry"

for payload in \
  '{"runtime":"codex-cli","attempted_wrapper":"external-review-claude.sh","read_root_flag":"--cd","diff_inlined":false}' \
  '{"runtime":"codex-cli","attempted_wrapper":"external-review-claude.sh","read_root_flag":"--mystery-root","diff_inlined":false}' \
  '{"runtime":"codex-cli","attempted_wrapper":"external-review-claude.sh","read_root_flag":"none","diff_inlined":true}' \
  '{"runtime":"codex-cli","attempted_wrapper":"external-review-claude.sh","argv":["external-review-claude.sh","--repo","."],"diff_inlined":false}'
do
  out="$(printf '%s\n' "$payload" | run_case)"
  assert_json_field "$out" 'data["prompt_exports_repo_diff"] is True' || fail "repo/diff export not detected for $payload"
  assert_json_field "$out" 'data["allow_unsandboxed_retry"] is False' || fail "unsandboxed retry allowed for $payload"
done

# --- api_error_status prong negative (the 401 prong of the zero-usage-401 AND-predicate) ---
status_negative="$(
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); d["api_error_status"]=403; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "result_envelope":d,
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$status_negative" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "non-401 status classified transient"

# float 401.0 — the case the prong-2 type-strict fix actually closes (401.0 == 401 is True in Python,
# but type(401.0) is int is False). The inline `assert ... is float` is the non-vacuity guard: it fails
# loudly if the literal is ever written as int 401, which would silently make this a no-op.
status_float_negative="$(
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); d["api_error_status"]=401.0; assert type(d["api_error_status"]) is float, "non-vacuity: api_error_status must be float 401.0"; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "result_envelope":d,
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$status_float_negative" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "float 401.0 status classified transient"
assert_json_field "$status_float_negative" 'data["allow_unsandboxed_retry"] is False' || fail "float 401.0 status allowed unsandboxed retry"

# --- result_envelope supplied as a JSON string (exercises the string branch positively) ---
string_envelope="$(
  python3 -c 'import json,sys; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "result_envelope":sys.stdin.read(),
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$string_envelope" 'data["classification"] == "reverse_wrapper_post_preflight_auth_transient"' || fail "string result_envelope did not classify transient"
assert_json_field "$string_envelope" 'data["allow_unsandboxed_retry"] is False' || fail "string envelope allowed unsandboxed retry"

# --- log_path file-read channel (touchstone-specific affordance retained under B-keep) ---
TMP_T="$(mktemp -d)"
trap 'rm -rf "$TMP_T"' EXIT

printf '%s' "$base_envelope" > "$TMP_T/envelope.json"
log_path_positive="$(
  python3 -c 'import json,sys; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "log_path":sys.argv[1],
  }))' "$TMP_T/envelope.json" | run_case
)"
assert_json_field "$log_path_positive" 'data["classification"] == "reverse_wrapper_post_preflight_auth_transient"' || fail "log_path envelope did not classify transient"
assert_json_field "$log_path_positive" 'data["allow_unsandboxed_retry"] is False' || fail "log_path positive allowed unsandboxed retry"

missing_log_path="$(
  python3 -c 'import json; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "log_path":"/nonexistent/touchstone-test/does-not-exist.json",
  }))' | run_case
)"
assert_json_field "$missing_log_path" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "non-existent log_path classified transient"

printf 'not json at all {' > "$TMP_T/garbage.json"
garbage_log_path="$(
  python3 -c 'import json,sys; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":1,
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "log_path":sys.argv[1],
  }))' "$TMP_T/garbage.json" | run_case
)"
assert_json_field "$garbage_log_path" 'data["classification"] != "reverse_wrapper_post_preflight_auth_transient"' || fail "non-JSON log_path file classified transient"

# --- exit_code branches (3 -> auth_unavailable, 2 -> local_config_failure) + the safety invariant ---
exit3="$(printf '%s\n' '{"runtime":"codex-cli","attempted_wrapper":"external-review-claude.sh","exit_code":3}' | run_case)"
assert_json_field "$exit3" 'data["classification"] == "reverse_wrapper_auth_unavailable"' || fail "exit 3 not auth_unavailable"
assert_json_field "$exit3" 'data["allow_unsandboxed_retry"] is False' || fail "exit 3 allowed unsandboxed retry"

exit2="$(printf '%s\n' '{"runtime":"codex-cli","attempted_wrapper":"external-review-claude.sh","exit_code":2}' | run_case)"
assert_json_field "$exit2" 'data["classification"] == "reverse_wrapper_local_config_failure"' || fail "exit 2 not local_config_failure"
assert_json_field "$exit2" 'data["allow_unsandboxed_retry"] is False' || fail "exit 2 allowed unsandboxed retry"

# --- shell-string exit codes normalize via _int_or_none ---
exit3_str="$(printf '%s\n' '{"runtime":"codex-cli","attempted_wrapper":"external-review-claude.sh","exit_code":"3"}' | run_case)"
assert_json_field "$exit3_str" 'data["classification"] == "reverse_wrapper_auth_unavailable"' || fail "string exit 3 not auth_unavailable"
assert_json_field "$exit3_str" 'data["allow_unsandboxed_retry"] is False' || fail "string exit 3 allowed unsandboxed retry"

exit1_str="$(
  python3 -c 'import json,sys; print(json.dumps({
    "runtime":"codex-cli",
    "attempted_wrapper":"external-review-claude.sh",
    "exit_code":"1",
    "wrapper_stderr":"external-review-claude: AUTH OK (OK subscription=max)",
    "result_envelope":json.loads(sys.stdin.read()),
  }))' <<<"$base_envelope" | run_case
)"
assert_json_field "$exit1_str" 'data["classification"] == "reverse_wrapper_post_preflight_auth_transient"' || fail "string exit 1 did not classify transient"

# --- unclassified/default branch: the safety invariant holds even on an empty payload ---
unclassified="$(printf '%s\n' '{}' | run_case)"
assert_json_field "$unclassified" 'data["classification"] == "unclassified_external_review_failure"' || fail "empty payload not unclassified"
assert_json_field "$unclassified" 'data["allow_unsandboxed_retry"] is False' || fail "unclassified branch allowed unsandboxed retry"

# --- string-form argv (prompt-export derivation handles both list and shell-string argv) ---
argv_string="$(printf '%s\n' '{"runtime":"codex-cli","attempted_wrapper":"external-review-claude.sh","argv":"external-review-claude.sh --repo .","diff_inlined":false}' | run_case)"
assert_json_field "$argv_string" 'data["prompt_exports_repo_diff"] is True' || fail "string-form argv repo/diff export not detected"
assert_json_field "$argv_string" 'data["allow_unsandboxed_retry"] is False' || fail "string-form argv allowed unsandboxed retry"

# --- main() malformed-input boundary: non-dict JSON and non-JSON stdin must exit 2 ---
rc=0; printf '%s' '[]' | python3 "$CLASSIFIER" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "non-dict top-level JSON did not exit 2 (got $rc)"
rc=0; printf '%s' '"a string"' | python3 "$CLASSIFIER" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "non-object JSON scalar did not exit 2 (got $rc)"
rc=0; printf '%s' 'not json at all' | python3 "$CLASSIFIER" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "non-JSON stdin did not exit 2 (got $rc)"

for marker in \
  "reverse_wrapper_post_preflight_auth_transient" \
  "wrapper process stderr" \
  "--wrapper-stderr-log" \
  "durable per-round artifact" \
  "sterile no-repo smoke" \
  'fresh `--findings`/`--log`' \
  "unsandboxed repo/diff rerun" \
  "classify_external_review_failure.py"
do
  if ! rg -n -F -- "$marker" "$ROOT_DIR/.touchstone/methodology/TOUCHSTONE.md" >/dev/null; then
    fail "TOUCHSTONE.md missing route-policy marker: $marker"
  fi
done

for marker in "AUTH OK" "zero-usage 401" "smoke probes" "fresh output paths"; do
  if ! rg -n -F -- "$marker" "$ROOT_DIR/README.md" >/dev/null; then
    fail "README.md missing troubleshooting marker: $marker"
  fi
done

if ! rg -n -F -- "external-review-claude: AUTH OK" "$ER_DIR/external-review-claude.sh" >/dev/null; then
  fail "reverse wrapper no longer emits the AUTH OK marker the classifier recognizes"
fi

if rg -n -F -- 'external-review-claude.sh ... 2> "$WRAPPER_STDERR"' "$ROOT_DIR/.touchstone/methodology/TOUCHSTONE.md" >/dev/null; then
  fail "TOUCHSTONE.md still documents shell redirection as the reverse wrapper stderr source"
fi

echo "test-classifier: ok"
