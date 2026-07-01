#!/usr/bin/env bash
#
# install.sh — install (or upgrade) the Touchstone methodology payload in a host repo.
#
# Copies `.touchstone/methodology/` into <target-repo-root>/.touchstone/methodology/ and,
# by DEFAULT, manages the host's `.gitignore` with a two-line negation block so the host
# COMMITS the vendored methodology and ignores only the mutable runtime artifacts:
#
#     /.touchstone/*
#     !/.touchstone/methodology/
#
# After a first install or an upgrade the host commits the result:
#     git add .gitignore .touchstone/methodology && git commit
# The installer NEVER stages or commits for you, and never auto-edits a host's own files
# (CLAUDE.md / AGENTS.md / README.md) or user-local runtime config. It only PRINTS
# the agent-file stanzas, local cross-model runtime setup snippets, and an optional
# README pointer to paste.
#
# Usage: ./install.sh <target-repo-root> [--force] [--discard-local] [--ignore-all]
#   --force          replace an existing, DIFFERING methodology payload (a vendor bump).
#                    Refuses if the host's .touchstone/methodology/ has uncommitted local
#                    changes (including ignored-untracked), to avoid destroying them.
#   --discard-local  modifier of --force ONLY: bypass the dirty-methodology guard and let
#                    --force overwrite local changes. Does nothing on its own.
#   --ignore-all     opt OUT of vendoring: write the blanket `/.touchstone/` rule instead
#                    of the negation block (the host ignores the whole namespace, commits
#                    nothing of Touchstone).
#
# Upgrade flow: ./install.sh <host> --force → review `git diff .touchstone/methodology`
#               → `git add .gitignore .touchstone/methodology && git commit`.
#
set -euo pipefail

usage() {
  echo "Usage: ./install.sh <target-repo-root> [--force] [--discard-local] [--ignore-all]" >&2
  echo "  --force          replace an existing, DIFFERING methodology payload (vendor bump)." >&2
  echo "  --discard-local  modifier of --force only: bypass the dirty-methodology guard." >&2
  echo "  --ignore-all     opt out of vendoring; write the blanket /.touchstone/ rule." >&2
  exit 2
}

# Resolve the payload from THIS script's own dir, never from cwd (callers may invoke
# us from a different working directory).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/.touchstone/methodology"

# --- A0 step 1: parse args; resolve SRC/DEST. ---
TARGET=""
FORCE=0
DISCARD_LOCAL=0
IGNORE_ALL=0
for arg in "$@"; do
  case "$arg" in
    --force)         FORCE=1 ;;
    --discard-local) DISCARD_LOCAL=1 ;;
    --ignore-all)    IGNORE_ALL=1 ;;
    -*)              echo "Unknown option: $arg" >&2; usage ;;
    *)
      if [ -z "$TARGET" ]; then TARGET="$arg"; else echo "Too many arguments." >&2; usage; fi
      ;;
  esac
done

[ -n "$TARGET" ] || usage

if [ ! -d "$SRC" ]; then
  echo "ERROR: payload not found at $SRC" >&2
  exit 2
fi
if [ ! -d "$TARGET" ]; then
  echo "ERROR: target repo root '$TARGET' is not a directory." >&2
  exit 2
fi
TARGET_ABS="$(cd "$TARGET" && pwd -P)"
TARGET="$TARGET_ABS"

DEST="$TARGET/.touchstone/methodology"
GITIGNORE="$TARGET/.gitignore"
REVERSE_WRAPPER_ABS="$DEST/scripts/external-review/external-review-claude.sh"
REVERSE_WRAPPER_RULE_LITERAL="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$REVERSE_WRAPPER_ABS")"

# Canonical two-line negation block (ORDER load-bearing: the `*` line then the `!` line —
# a `!` before the `*`, or appended after a whole-dir `/.touchstone/`, is a silent no-op).
BLOCK_LINE1='/.touchstone/*'
BLOCK_LINE2='!/.touchstone/methodology/'

print_block_instructions() {
  echo "  Add these two lines to your host's .gitignore, in THIS order" >&2
  echo "  (the '!' line MUST come after the '/.touchstone/*' line):" >&2
  echo "" >&2
  echo "    $BLOCK_LINE1" >&2
  echo "    $BLOCK_LINE2" >&2
  echo "" >&2
}

# Count whole-line occurrences (fixed-string) of a pattern in the host .gitignore.
count_line() {  # $1 = exact line
  [ -f "$GITIGNORE" ] || { echo 0; return; }
  grep -cxF "$1" "$GITIGNORE" 2>/dev/null || echo 0
}

# Count `.touchstone` mentions in RULE lines only (ignore `#` comment lines + blanks).
# git ignores comments, so a host's explanatory `.touchstone` comments (or this repo's
# own .gitignore comments) must NOT make the file look "ambiguous" to the classifier.
count_touchstone_rules() {
  [ -f "$GITIGNORE" ] || { echo 0; return; }
  local n
  n=$(grep -vE '^[[:space:]]*#' "$GITIGNORE" 2>/dev/null | grep -cF '.touchstone' || true)
  echo "${n:-0}"
}

# True if the file mentions `.touchstone` in a RULE line (comments excluded) — used to
# detect the "absent" tier and ambiguous mentions the classifier doesn't recognize.
has_touchstone_mention() {
  [ -f "$GITIGNORE" ] || return 1
  grep -vE '^[[:space:]]*#' "$GITIGNORE" 2>/dev/null | grep -qF '.touchstone'
}

# Ensure the host .gitignore ends with a newline BEFORE we append, so an appended rule
# never concatenates onto the host's last rule (a file with no trailing newline).
ensure_trailing_newline() {
  [ -f "$GITIGNORE" ] && [ -s "$GITIGNORE" ] || return 0
  if [ -n "$(tail -c1 "$GITIGNORE")" ]; then printf '\n' >> "$GITIGNORE"; fi
  return 0
}

# =============================================================================
# A0 step 2 — PREFLIGHT: classify the .gitignore (A2) and run the --force dirty
# guard (A3). REFUSE here, before ANY mutation, on an ambiguous .gitignore or on
# dirty-without-discard methodology.
# =============================================================================

# --- A2 classify (default / negation path) ---
# Decide the action WITHOUT mutating yet. Sets GITIGNORE_ACTION to one of:
#   noop | replace-legacy | append | ignoreall-* (set in the --ignore-all branch).
GITIGNORE_ACTION=""

classify_negation() {
  local n1 n2 n_legacy n_any
  n1=$(count_line "$BLOCK_LINE1")
  n2=$(count_line "$BLOCK_LINE2")
  n_legacy=$(count_line '/.touchstone/')

  # already-canonical: EXACTLY the two block lines (one each) in order, AND no other
  # `.touchstone` mention anywhere (an extra later rule could re-ignore methodology).
  if [ "$n1" = "1" ] && [ "$n2" = "1" ]; then
    # confirm order (line1 immediately before line2) and that those are the ONLY
    # `.touchstone` mentions in the file.
    n_any=$(count_touchstone_rules)
    if [ "$n_any" = "2" ] && grep -qzF "$BLOCK_LINE1"$'\n'"$BLOCK_LINE2" "$GITIGNORE" 2>/dev/null; then
      GITIGNORE_ACTION="noop"
      return 0
    fi
    # two block lines present but with extra `.touchstone` mentions or wrong order → ambiguous
    return 1
  fi

  # exact legacy whole-line `/.touchstone/` is the ONLY auto-migratable case:
  # it must be the sole `.touchstone` mention (exactly one such line, no others).
  if [ "$n_legacy" = "1" ]; then
    n_any=$(count_touchstone_rules)
    if [ "$n_any" = "1" ]; then
      GITIGNORE_ACTION="replace-legacy"
      return 0
    fi
    return 1
  fi

  # absent: no `.touchstone` mention at all → append.
  if ! has_touchstone_mention; then
    GITIGNORE_ACTION="append"
    return 0
  fi

  # anything else ambiguous.
  return 1
}

# --- A2-ignoreall classify ---
classify_ignoreall() {
  local n1 n2 n_blanket n_any
  n1=$(count_line "$BLOCK_LINE1")
  n2=$(count_line "$BLOCK_LINE2")
  n_blanket=$(count_line '/.touchstone/')

  # canonical block present → replace it with the blanket rule.
  if [ "$n1" = "1" ] && [ "$n2" = "1" ]; then
    n_any=$(count_touchstone_rules)
    if [ "$n_any" = "2" ] && grep -qzF "$BLOCK_LINE1"$'\n'"$BLOCK_LINE2" "$GITIGNORE" 2>/dev/null; then
      GITIGNORE_ACTION="ignoreall-replace-block"
      return 0
    fi
    return 1
  fi

  # blanket already present and sole mention → idempotent no-op.
  if [ "$n_blanket" = "1" ]; then
    n_any=$(count_touchstone_rules)
    if [ "$n_any" = "1" ]; then
      GITIGNORE_ACTION="ignoreall-noop"
      return 0
    fi
    return 1
  fi

  # absent → append the blanket rule.
  if ! has_touchstone_mention; then
    GITIGNORE_ACTION="ignoreall-append"
    return 0
  fi

  return 1
}

if [ "$IGNORE_ALL" -eq 1 ]; then
  if ! classify_ignoreall; then
    echo "ERROR: the host '.gitignore' has an ambiguous '.touchstone' rule that this installer" >&2
    echo "       will not rewrite. To opt out of vendoring, ensure the blanket rule by hand:" >&2
    echo "" >&2
    echo "    /.touchstone/" >&2
    echo "" >&2
    exit 1
  fi
else
  if ! classify_negation; then
    echo "ERROR: the host '.gitignore' has an ambiguous '.touchstone' rule that this installer" >&2
    echo "       will not rewrite (it is neither the canonical block, the exact legacy line" >&2
    echo "       '/.touchstone/', nor absent)." >&2
    print_block_instructions
    exit 1
  fi
fi

# --- A3 --force dirty-guard (PREFLIGHT, before any mutation) ---
# Gate on git-repo detection first (a non-git target → no guard possible → proceed).
if [ "$FORCE" -eq 1 ] && [ "$DISCARD_LOCAL" -ne 1 ]; then
  if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
    # Dirty check MUST include ignored-untracked (a legacy `/.touchstone/` host ignores
    # methodology, so a local edit there is ignored-untracked and a plain --porcelain
    # would miss it, letting --force silently destroy it).
    DIRTY="$(git -C "$TARGET" status --porcelain --ignored=matching -- .touchstone/methodology 2>/dev/null || true)"
    if [ -n "$DIRTY" ]; then
      echo "ERROR: --force would destroy local changes under .touchstone/methodology:" >&2
      echo "$DIRTY" >&2
      echo "       Commit or stash them first, or pass --discard-local to overwrite them." >&2
      echo "       (On a legacy whole-dir '/.touchstone/' host the whole namespace reports as" >&2
      echo "        ignored, so this guard is conservative — it refuses on ANY .touchstone" >&2
      echo "        dirtiness and self-corrects once the negation un-ignores methodology.)" >&2
      exit 1
    fi
  fi
fi

# --- Existing-DIFFERING-payload refusal (PREFLIGHT, before any .gitignore mutation) ---
# A non-`--force` run on an existing DIFFERING payload must refuse with NOTHING mutated —
# not even the .gitignore — so a refused run is fully no-op (ext impl-review r2).
if [ -d "$DEST" ] && [ "$FORCE" -ne 1 ]; then
  if ! diff -r "$SRC" "$DEST" >/dev/null 2>&1; then
    echo "ERROR: an existing payload at $DEST DIFFERS from this Touchstone version." >&2
    echo "       Re-run with --force to replace it (a vendor bump); nothing was changed." >&2
    exit 1
  fi
fi

# =============================================================================
# A0 step 3 — apply the .gitignore block + VERIFY (A2-verify). On verify failure
# RESTORE the kept backup and REFUSE — still BEFORE the payload is touched.
# =============================================================================

# Keep a backup so we can restore byte-for-byte on verify failure.
GITIGNORE_BACKUP=""
GITIGNORE_EXISTED=0
if [ -f "$GITIGNORE" ]; then
  GITIGNORE_EXISTED=1
  GITIGNORE_BACKUP="$(mktemp)"
  cp "$GITIGNORE" "$GITIGNORE_BACKUP"
fi

restore_gitignore() {
  if [ "$GITIGNORE_EXISTED" -eq 1 ]; then
    cp "$GITIGNORE_BACKUP" "$GITIGNORE"
  else
    rm -f "$GITIGNORE"
  fi
}

apply_negation() {
  case "$GITIGNORE_ACTION" in
    noop)
      echo ".gitignore already has the canonical Touchstone block — no change."
      ;;
    replace-legacy)
      # Replace the single exact legacy whole-line `/.touchstone/` with the two-line block,
      # in place, order preserved. Use awk for a precise whole-line match (not a sed glob).
      local tmp
      tmp="$(mktemp)"
      awk -v l1="$BLOCK_LINE1" -v l2="$BLOCK_LINE2" '
        $0 == "/.touchstone/" { print l1; print l2; next }
        { print }
      ' "$GITIGNORE" > "$tmp"
      mv "$tmp" "$GITIGNORE"
      echo "Migrated legacy '/.touchstone/' to the two-line negation block in $GITIGNORE."
      ;;
    append)
      ensure_trailing_newline
      printf '%s\n%s\n' "$BLOCK_LINE1" "$BLOCK_LINE2" >> "$GITIGNORE"
      echo "Appended the two-line negation block to $GITIGNORE."
      ;;
  esac
}

apply_ignoreall() {
  case "$GITIGNORE_ACTION" in
    ignoreall-noop)
      echo ".gitignore already blanket-ignores /.touchstone/ — no change."
      ;;
    ignoreall-replace-block)
      local tmp
      tmp="$(mktemp)"
      # Drop both block lines, then ensure a single blanket line in their place.
      awk -v l1="$BLOCK_LINE1" -v l2="$BLOCK_LINE2" '
        $0 == l1 { print "/.touchstone/"; next }
        $0 == l2 { next }
        { print }
      ' "$GITIGNORE" > "$tmp"
      mv "$tmp" "$GITIGNORE"
      echo "Replaced the negation block with the blanket '/.touchstone/' rule in $GITIGNORE."
      ;;
    ignoreall-append)
      ensure_trailing_newline
      printf '/.touchstone/\n' >> "$GITIGNORE"
      echo "Appended the blanket '/.touchstone/' rule to $GITIGNORE."
      ;;
  esac
}

# A2-verify: EXHAUSTIVE git check-ignore probes for EVERY accepted git-repo state
# (incl. the no-op). check-ignore --no-index is pattern-only, so DEST need not exist —
# correct, since this runs before the payload swap.
#   - every shipped payload file mapped to its dest path → MUST be NOT ignored.
#   - artifact subtrees + ALL THREE root markers → MUST be ignored.
verify_negation() {
  # check-ignore needs a git repo to consult the .gitignore; if the target isn't a
  # git repo there is nothing to verify (the ignore rules only matter under git).
  git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || return 0

  local rel dest f
  # Shipped payload files: enumerate the SRC tree, map to dest, each MUST be tracked.
  while IFS= read -r f; do
    rel="${f#"$SRC"/}"
    dest=".touchstone/methodology/$rel"
    if git -C "$TARGET" check-ignore -q --no-index "$dest" 2>/dev/null; then
      echo "ERROR: .gitignore verification FAILED — a shipped payload file would be IGNORED:" >&2
      echo "         $dest" >&2
      return 1
    fi
  done < <(find "$SRC" -type f)

  # Artifact / marker side: ALL of these MUST be ignored.
  local probe
  for probe in \
    ".touchstone/plans/__verify_probe__.md" \
    ".touchstone/logs/__verify_probe__/x.log" \
    ".touchstone/ext-review/__verify_probe__/x.json" \
    ".touchstone/.session-state.md" \
    ".touchstone/.open-dilemmas.md" \
    ".touchstone/.consult-evidence.md"; do
    if ! git -C "$TARGET" check-ignore -q --no-index "$probe" 2>/dev/null; then
      echo "ERROR: .gitignore verification FAILED — a working artifact/marker is NOT ignored:" >&2
      echo "         $probe" >&2
      return 1
    fi
  done
  return 0
}

# --ignore-all verify: the blanket rule must actually take effect (a host negation could
# defeat it, or an ineffective write could leave the namespace tracked). Confirm a
# methodology file AND a marker are BOTH ignored.
verify_ignoreall() {
  git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local probe
  for probe in \
    ".touchstone/methodology/TOUCHSTONE.md" \
    ".touchstone/.session-state.md"; do
    if ! git -C "$TARGET" check-ignore -q --no-index "$probe" 2>/dev/null; then
      echo "ERROR: --ignore-all verification FAILED — Touchstone is NOT fully ignored:" >&2
      echo "         $probe" >&2
      return 1
    fi
  done
  return 0
}

if [ "$IGNORE_ALL" -eq 1 ]; then
  apply_ignoreall
  if ! verify_ignoreall; then
    restore_gitignore
    echo "       Restored the original .gitignore (unchanged) and made NO payload changes." >&2
    exit 1
  fi
  # --ignore-all: if methodology is already TRACKED, gitignoring it does not untrack it —
  # print the follow-up (the installer never runs git).
  if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git -C "$TARGET" ls-files -- .touchstone/methodology 2>/dev/null)" ]; then
      echo ""
      echo "NOTE: .touchstone/methodology is already tracked. To make --ignore-all effective,"
      echo "      untrack it (the installer never runs git):"
      echo ""
      echo "    git -C \"$TARGET\" rm -r --cached .touchstone/methodology"
      echo ""
    fi
  fi
else
  apply_negation
  if ! verify_negation; then
    restore_gitignore
    echo "       Restored the original .gitignore (unchanged) and made NO payload changes." >&2
    print_block_instructions
    exit 1
  fi
fi

# =============================================================================
# A0 step 4 — mutate the payload LAST. Nothing fail-able follows, so no path can
# leave a swapped payload behind a failed/restored .gitignore.
# (SAFE contents-copy: trailing /. into a pre-made dir, so an existing DEST never
# yields a nested methodology/methodology.)
# =============================================================================
if [ -d "$DEST" ]; then
  if diff -r "$SRC" "$DEST" >/dev/null 2>&1; then
    echo "Payload already installed and identical at $DEST — no change."
  elif [ "$FORCE" -ne 1 ]; then
    echo "ERROR: an existing payload at $DEST DIFFERS from this Touchstone version." >&2
    echo "       Re-run with --force to replace it (a vendor bump)." >&2
    exit 1
  else
    # Stage into a temp dir, then atomically swap, so a partial copy can't corrupt the install.
    TMP="$TARGET/.touchstone/.methodology.tmp"
    rm -rf "$TMP"
    mkdir -p "$TMP"
    cp -R "$SRC/." "$TMP/"
    rm -rf "$DEST"
    mv "$TMP" "$DEST"
    echo "Payload replaced (--force) at $DEST."
  fi
else
  mkdir -p "$DEST"
  cp -R "$SRC/." "$DEST/"
  echo "Payload installed at $DEST."
fi

# --- PRINT (never write) the host agent-file stanzas, runtime setup snippets, and commit follow-up. ---
if [ "$IGNORE_ALL" -ne 1 ]; then
  cat <<'COMMITNOTE'

--------------------------------------------------------------------------------
Default model: the host COMMITS the vendored methodology and ignores only the
mutable runtime artifacts. Finish the install (or the upgrade) by committing —
the installer never stages or commits for you:

    git add .gitignore .touchstone/methodology && git commit

To upgrade later: ./install.sh <host> --force → review `git diff .touchstone/methodology`
→ commit as above. --force refuses if your methodology has uncommitted local changes
(commit/stash first, or pass --discard-local to overwrite them).
--------------------------------------------------------------------------------
COMMITNOTE
fi

cat <<'STANZA'

================================================================================
Touchstone payload is installed. Touchstone did NOT modify your agent files.
Paste the stanzas below into your host repo's OWN CLAUDE.md and AGENTS.md
(create them if absent). Touchstone never auto-edits a host's agent files.
================================================================================

----- paste into your host's CLAUDE.md (Claude Code) -----------------------------
This repo has Touchstone installed under `.touchstone/methodology/`. When doing
skill / methodology / Touchstone / consult / review-loop / external-review work,
read `.touchstone/methodology/TOUCHSTONE.md` (the runtime-neutral process) and
`.touchstone/methodology/TOUCHSTONE-claude.md` (the Claude Code binding).

Optional — always-on eager load: to pull the methodology into EVERY Claude session
(~96 KiB; worth it only if Touchstone is used often), add the two lines shown in the
fenced block below to the TOP of your CLAUDE.md, OUTSIDE the fence. An @import inside
a fenced code block is intentionally inert, so these stay OFF until you move them out:

```
@.touchstone/methodology/TOUCHSTONE.md
@.touchstone/methodology/TOUCHSTONE-claude.md
```
----------------------------------------------------------------------------------

----- paste into your host's AGENTS.md (Codex / OpenCode) ------------------------
This repo has Touchstone installed under `.touchstone/methodology/`. Before any
skill / methodology / Touchstone / consult / review-loop / external-review work,
FIRST read `.touchstone/methodology/TOUCHSTONE.md` — the COMPLETE runtime-neutral
process, self-sufficient for a Codex orchestrator (it includes the pinned reverse
cross-model wrapper for running a Claude reviewer). Under Claude Code, ALSO read
`.touchstone/methodology/TOUCHSTONE-claude.md` for the Claude-specific mechanisms.
----------------------------------------------------------------------------------

STANZA

cat <<RUNTIME
================================================================================
LOCAL RUNTIME SETUP FOR EXTERNAL REVIEW — printed only; never auto-edited
================================================================================

Touchstone does NOT edit your local Claude settings, Codex config, Codex rules,
or host README. To make cross-model external review work unattended, configure
the runtime(s) you plan to use.

Claude Code orchestrates -> GPT/Codex reviews:

1. Install and authenticate the Codex CLI.
2. In this host repo, create or edit the local, uncommitted file
   .claude/settings.local.json and grant ONLY the Touchstone wrapper path:

   {
     "permissions": {
       "allow": [
         "Bash(./.touchstone/methodology/scripts/external-review/external-review-codex.sh:*)"
       ]
     }
   }

   Grant the wrapper path, not "codex exec:*". Never commit settings.local.json.

Codex/GPT orchestrates -> Claude reviews:

1. Install Claude Code and sign in with a Claude Pro/Max subscription.
2. For Codex auto_review, add a narrow rule to ~/.codex/rules/default.rules,
   then restart Codex:

   prefix_rule(
       pattern = [$REVERSE_WRAPPER_RULE_LITERAL],
       decision = "allow",
       justification = "Allow Touchstone's reverse external-review wrapper from this trusted repo. The wrapper enforces first-party Claude subscription auth, sterile settings, no write-capable tools, schema output, and bounded budget.",
   )

   This rule trusts the exact vendored wrapper file at this host path. If the
   repo moves, regenerate the rule. Review methodology bumps before committing
   them.

   Do NOT allowlist "claude", "bash", "zsh", "env", directories, repo-relative
   paths, wildcard paths, generic external-review prefixes, or shell-wrapped
   commands. Invoke the reverse wrapper directly as the top-level command.

   The reverse wrapper is billing/auth fail-closed: if first-party Claude
   subscription auth is unavailable, it exits 3 and the Touchstone loop proceeds
   internal-only with a logged skip.

See the installed methodology and Touchstone README sections "Setting up
cross-model review" and "Running unattended" for the full setup and smoke tests.
----------------------------------------------------------------------------------

RUNTIME

cat <<'README'
================================================================================
OPTIONAL — README pointer. Touchstone does NOT touch your README. If you want
contributors to DISCOVER the workflow (the agent files above are for the agent;
this is for humans browsing the repo), paste a section like this into your
project's README and localize the <placeholders> to your own tools/skills:
================================================================================

----- paste into your README.md (then edit the <placeholders>) -------------------
## Improving this project (it's built with Touchstone)

This repo is developed with [Touchstone](https://github.com/devdacian/touchstone) —
an adversarial, cross-model plan/implementation review process — vendored under
`.touchstone/methodology/`. To improve a skill or fix a bug with the same review
loop, launch your runtime in auto mode and paste a prompt like:

    claude --permission-mode auto       # Claude Code
    # or
    codex                               # Codex CLI

> Fix a bug in `<file>`: <describe the bug, or the improvement>. Follow the Touchstone
> process in `.touchstone/methodology/TOUCHSTONE.md` — gather context, run the
> expert consult, then the review loop(s) scaled to the change's risk, and keep the
> test suite green. Stay in auto mode; keep the plan as a file under
> `.touchstone/plans/`, not a runtime plan mode.

Under Claude Code the agent also reads `.touchstone/methodology/TOUCHSTONE-claude.md`
automatically; under Codex CLI the runtime-neutral core is self-sufficient.
----------------------------------------------------------------------------------

This pointer cites only STABLE methodology paths, so it does NOT need re-pasting
when you upgrade Touchstone — a version bump changes the payload, not these paths.

README
