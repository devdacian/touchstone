# Touchstone

A lightweight, fast & automated multi-model process for rapid skill improvement.

Input an idea, new feature or bug report => get automated context gathering, initial design,
plan, implementation & reviews using multiple models equipped with a library of
proven skill-enhancement techniques & fault-tolerant of many errors, timeouts etc.

```
idea / bug report (input)
  [everything below automated]
  -> context gathering
  -> initial approach
  -> independent consult            (fresh context, optionally cross-model)
  -> plan (a file, not a chat msg)
  -> internal plan review loop      ┐ run concurrently when second
  -> external cross-model plan loop ┘ model family is available
  -> implementation
  -> internal implementation review loop             ] run concurrently when second
  -> external cross-model implementation review loop ] model family is available
  -> verified final result
```

Almost nothing to install: copy one directory into your repo, paste a short pointer
into your own `CLAUDE.md` / `AGENTS.md`, and start improving your skills FAST and
AUTOMATED. Touchstone lives entirely under a single `.touchstone/` namespace — by
default your repo commits the methodology and ignores the runtime artifacts, so a fresh
checkout has Touchstone ready while never over-writing your repo's own agent files.

## Contents

- [What's in the box](#whats-in-the-box)
- [How it works](#how-it-works)
- [How this differs from a plain cross-model reviewer](#how-this-differs-from-a-plain-cross-model-reviewer)
- [Quick start](#quick-start)
- [Upgrading Touchstone](#upgrading-touchstone)
- [Setting up cross-model review](#setting-up-cross-model-review)
- [Running unattended (automatic mode)](#running-unattended-automatic-mode)
- [Customizing](#customizing)
- [Background](#background)
- [License](#license)

## What's in the box

The installable payload is a single directory, `.touchstone/methodology/`. Its contents,
plus the two repo-root files that deliver and license it (`install.sh`, `LICENSE`):

| File | What it is |
|---|---|
| `.touchstone/methodology/TOUCHSTONE.md` | The runtime-neutral core: the full process, the failure-mode lens catalogue, the review-prompt skeleton, and the external-review contract — **including the pinned reverse cross-model wrapper**, so it is the COMPLETE process for both a Claude orchestrator and a Codex orchestrator. **Start here.** |
| `.touchstone/methodology/TOUCHSTONE-claude.md` | The Claude Code binding: how to spawn an arms-length consult/review, and how to drive the cross-model reviewer. (A Codex orchestrator needs no binding file — the core above is self-sufficient for it.) |
| `.touchstone/methodology/references/skill-improvement-strategies.md` | The "what to change" companion: a catalogue of validated strategies for fixing recurring agent-behavior failures (placement, format, structure, multi-agent framing). `TOUCHSTONE.md` tells the agent to read it whenever the task is improving a skill. |
| `.touchstone/methodology/scripts/external-review/external-review-codex.sh` | Forward wrapper: a Claude orchestrator runs a GPT reviewer via `codex exec`. |
| `.touchstone/methodology/scripts/external-review/external-review-claude.sh` | Reverse wrapper: a Codex orchestrator runs an Opus reviewer via `claude -p`. |
| `.touchstone/methodology/scripts/external-review/findings.schema.json` | The structured-output schema the external reviewer emits (severity, cited evidence, location concept, suggested fix). |
| `.touchstone/methodology/scripts/external-review/classify_external_review_failure.py` | The graceful-degradation classifier: given an unhealthy reverse-wrapper round, decides retry-vs-skip (it is the executable field-level contract for the zero-usage-401 auth predicate). |
| `install.sh` | One-shot installer/upgrader: copies the payload into a host, writes the two-line `.gitignore` negation block (so the host commits the methodology and ignores only the artifacts; `--ignore-all` opts out), and prints (never writes) the pointer stanzas, local cross-model runtime setup snippets, and optional README pointer. |
| `LICENSE` | MIT. |

> **Wrapper naming convention:** `external-review-<reviewer>.sh`, where `<reviewer>` is the CLI the wrapper invokes (`codex`, `claude`, …) — so a new reviewer CLI just gets its own `external-review-<cli>.sh`. Pick the wrapper whose reviewer is a different model family from your orchestrator; equivalently, never use the one named after your own family.

## How it works

The framework is a set of instructions an agent reads, plus two small shell
wrappers that make cross-model review deterministic and safe. There is no
service to run and no dependency to install beyond the CLIs you already use.

1. **Context, consult, evaluate.** The agent reads the relevant files, identifies
   load-bearing premises (and checks the cheap ones during planning), drafts a few
   approaches, and consults an expert in a *fresh, arms-length context* — one that
   did not build the rationale, so it re-checks premises instead of inheriting the
   framing. When a second model family is reachable, an external consult runs in
   parallel.

2. **Plan as a file.** For non-trivial changes the agent writes a plan to
   `.touchstone/plans/<topic>-plan.md`. A file can be diffed, edited, and mutated across review
   rounds; chat plans get re-emitted and blurred.

3. **Review loops with teeth.** Each round hands a *fresh reviewer* a prompt that
   names the specific failure modes to hunt (stale references, source-of-truth
   drift, sequencing bugs, cross-phase lifecycles, unestablished premises, …) — not
   a vague "any improvements?". Every finding is a **claim**: the orchestrator
   verifies the cited evidence (grep the line, run the script, check the test)
   *before* deciding to accept, reject, modify, or defer it. Dispositions carry
   forward so a later reviewer can challenge them.

4. **Cross-model review.** Concurrently (when available) a reviewer of a *different model family*
   reviews both the plan and the implementation. A different family challenges different
   seams and is wrong differently. Its findings are still claims the orchestrator verifies;
   the value is the delta, not obedience.

5. **Degrade gracefully.** Cross-model review can fail on auth, quota, provider
   errors, or watchdog timeouts. The wrappers detect that structurally and the
   process proceeds internal-only with a loud logged notice. By default it never
   uses per-token API billing — only your included subscription quota.

Read `.touchstone/methodology/TOUCHSTONE.md` for the complete process, including the
lens catalogue and the five-component review-prompt skeleton.

## How this differs from a plain cross-model reviewer

Cross-model review on its own is no longer novel: GitHub Copilot ships a "second
opinion" from a different model family, and several projects already do
Claude-writes / Codex-reviews. That kernel is common. What this framework adds is
the engineering *around* the kernel:

1. **The plan is reviewed as a first-class artifact, before code exists.** Plan
   review runs as its own loop to convergence, on a *file* that gets diffed and
   mutated across rounds — then implementation review runs as a second loop on the
   diff. Most cross-model tools are PR/code-review oriented; built-in
   second-opinion features touch plans but aren't a staged plan-loop-then-
   implementation-loop. "Many implementation bugs are planning bugs" is
   operationalized here, not just asserted.

2. **A specified evidence-verification protocol, not just "adversarial review."**
   Every finding is a claim: the orchestrator greps the cited line *before*
   disposing it, records a structured disposition (with the verification command
   and output), and carries dispositions forward so a later reviewer can challenge
   them. Anti-sycophancy gates run in **both** directions — the *three teeth*
   guard against wrongly *rejecting* a valid finding (verify-evidence-not-
   conclusion, the contested-rejection gate, severity-gated escalation), and the
   settled-design floor guards against wrongly *adopting* a finding that would
   reverse a deliberate design choice. Other tools say "findings survive
   cross-examination"; this one specifies *how* a finding is verified and disposed.

3. **A named lens catalogue.** A reusable Tier-1 / Tier-2 failure-mode taxonomy
   drives the review prompt ("don't ask 'any improvements?' — hunt these named
   categories": stale references, source-of-truth drift, cross-phase lifecycles,
   unestablished premises, …). Most reviewers rely on the model's general judgment;
   this ships the checklist.

4. **It's purpose-built for authoring skills and methodology** — artifacts that are
   *upstream of future agent behavior*, where a bad instruction becomes part of the
   machine that creates later bugs. That focus shows up as skill-authoring guidance
   and a mandatory arms-length **consult** step (distinct from review). The
   alternatives are general code-review tools.

5. **It's runtime-neutral instructions plus deliberately dumb wrappers, not an
   app/MCP/tool.** `TOUCHSTONE.md` and `TOUCHSTONE-claude.md` are read by any runtime
   (your repo's own `CLAUDE.md` / `AGENTS.md` just point at them); the shell wrappers
   own *only* the safe invocation. It works **both directions**
   (Claude↔Codex) and ports across runtimes — closer to a constitution than a
   product, with nothing to install or host.

6. **Operational hardening** the lightweight alternatives skip: a per-round
   watchdog that reaps the reviewer's full process tree, a structural health
   contract (the wrapper's exit code, never the model's), a billing-fail-closed
   auth preflight on the reverse path, and skip-not-fail degradation so a failed
   external service never blocks the loop.

None of these is the cross-model idea itself; together they are the difference
between a second-opinion feature and a disciplined development loop you can ship
work from.

## Quick start

1. **Install the framework into your repo.** The installer copies the
   `.touchstone/methodology/` payload, writes the two-line `.gitignore` negation block
   (so your repo commits the vendored methodology and ignores only the runtime
   artifacts), and PRINTS (never writes) the pointer stanzas to paste into your repo's
   own `CLAUDE.md` / `AGENTS.md`, plus local runtime setup snippets needed for
   cross-model external review from Claude Code or Codex:

   ```sh
   ./install.sh /path/to/your-repo
   ```

   Then **commit the result** — the installer never stages or commits for you:

   ```sh
   cd /path/to/your-repo
   git add .gitignore .touchstone/methodology && git commit
   ```

   (Prefer the blanket-ignore model — host commits nothing of Touchstone? Pass
   `--ignore-all`; see [Customizing](#customizing).)

   **Manual fallback** (same effect, by hand). Use the SAFE contents-copy — `mkdir -p`
   the destination then copy the payload's CONTENTS into it (the trailing `/.` avoids a
   nested `methodology/methodology/`), then add the two-line negation block (the `!` line
   MUST come after the `/.touchstone/*` line):

   ```sh
   mkdir -p /path/to/your-repo/.touchstone/methodology
   cp -R .touchstone/methodology/. /path/to/your-repo/.touchstone/methodology/
   printf '/.touchstone/*\n!/.touchstone/methodology/\n' >> /path/to/your-repo/.gitignore
   ```

   (If `.touchstone/methodology/` already exists in the host, prefer `./install.sh` to
   update it — it refuses to overwrite a differing payload without `--force`; see
   [Upgrading Touchstone](#upgrading-touchstone).)

   Then add a short pointer to your repo's OWN `CLAUDE.md` (Claude Code) and `AGENTS.md`
   (Codex / OpenCode) — `install.sh` prints exactly what to paste. The pointer tells the
   agent to read `.touchstone/methodology/TOUCHSTONE.md` — the complete runtime-neutral
   process, self-sufficient for a Codex orchestrator (it includes the pinned reverse
   cross-model wrapper) — and, under Claude Code, ALSO
   `.touchstone/methodology/TOUCHSTONE-claude.md` (the Claude-specific mechanisms). Your repo
   keeps its own agent files; Touchstone never auto-edits them. Touchstone writes all
   working artifacts — plans, logs, external reviews, marker files — under the ignored part
   of the `.touchstone/` namespace (the methodology itself is committed).

2. **Drive it.** Ask your agent to build or change a skill and to *follow the
   Touchstone process in `.touchstone/methodology/TOUCHSTONE.md`*. The agent will gather context, consult,
   plan, and run the review loops. For a small change it will skip planning and go
   straight to a single implementation-review loop; for a risky one it will run the
   full plan + implementation loops. Scale with risk — the point is quality, not
   ceremony.

   For example, launch your runtime in auto mode (see [Running unattended](#running-unattended-automatic-mode))
   and paste a prompt naming the skill, the change, and the process file:

   ```sh
   claude --permission-mode auto       # Claude Code
   # or
   codex                               # Codex CLI
   ```

   > Improve the `<skill-name>` skill: `<what to add/change, or the bug to fix>`.
   > Follow the Touchstone process in `.touchstone/methodology/TOUCHSTONE.md` — gather
   > context, run the expert consult, then run the review loops (plan + implementation)
   > scaled to the change's risk. Stay in auto mode and keep the plan as a file under
   > `.touchstone/plans/`, not a runtime plan mode.

   The prompt is the same for either runtime: under **Claude Code** the agent also reads
   the Claude binding (`.touchstone/methodology/TOUCHSTONE-claude.md`) automatically;
   under **Codex CLI** the runtime-neutral core is self-sufficient on its own (it includes
   the pinned reverse cross-model wrapper).

The internal review loop works with **no extra setup** — it uses your runtime's own
subagent/delegation mechanism. Cross-model review needs one more thing — the
other model's CLI; see [Setting up cross-model review](#setting-up-cross-model-review).

## Upgrading Touchstone

Because the default install commits the vendored methodology, pulling a newer Touchstone
is a tracked bump you review and commit:

```sh
./install.sh /path/to/your-repo --force
cd /path/to/your-repo
git diff .touchstone/methodology    # review what changed
git add .gitignore .touchstone/methodology && git commit
```

`--force` replaces `.touchstone/methodology/` (your runtime artifacts under `.touchstone/`
are untouched). It **refuses** if your `.touchstone/methodology/` has uncommitted local
changes — commit or stash them first, or pass `--discard-local` to overwrite them. The
installer never stages or commits the bump for you; the upgrade is an explicit, git-tracked
diff you approve.

## Setting up cross-model review

Cross-model review needs the *other* model's CLI installed and authenticated. Pick
the direction that matches your orchestrator:

### Claude orchestrates → GPT reviews (forward)

- Install the **Codex CLI** and authenticate it (a ChatGPT subscription that
  includes Codex quota, or an OpenAI account).
- The wrapper pins `gpt-5.5` at `high` reasoning effort and scrubs `OPENAI_API_KEY`
  so the run stays on the included subscription quota rather than per-token API
  billing.
- For autonomous Claude Code runs, grant the wrapper in the **gitignored**
  `.claude/settings.local.json` (never commit it):

  ```json
  { "permissions": { "allow": ["Bash(./.touchstone/methodology/scripts/external-review/external-review-codex.sh:*)"] } }
  ```

### Codex/GPT orchestrates → Claude reviews (reverse)

- Install **Claude Code** and sign in with a Claude Pro/Max subscription.
- The wrapper is **billing-fail-closed**: it scrubs every API/provider/OAuth-token
  env route and invokes the reviewer only when `claude auth status` confirms a
  first-party `pro`/`max` subscription. If that preflight fails, it exits `3`
  (no-spend skip) and the process proceeds internal-only — it will never silently
  fall back to per-token API billing.
- Troubleshooting: a one-off `AUTH OK` followed by a zero-usage 401 is not, by itself,
  evidence that Claude Max auth is permanently broken. Run the smoke probes described in
  `TOUCHSTONE.md` from a sterile no-repo posture. If they pass, use fresh output paths.
- For autonomous Codex runs with `approvals_reviewer = "auto_review"`, approve the exact
  absolute path of `.touchstone/methodology/scripts/external-review/external-review-claude.sh`
  and invoke that wrapper directly as the top-level command. Do not approve `claude`,
  `bash`, `zsh`, `env`, a directory, a repo-relative path, a wildcard path, or a generic
  external-review prefix.
- Use `--wrapper-stderr-log <file>` for reverse-wrapper calls so retry-vs-skip
  classification reads durable wrapper-owned markers from a file distinct from Claude child
  stderr at `<log>.stderr`.

Either wrapper self-enforces a per-round wall-clock watchdog (default 600s, reaps
the reviewer's full process tree) and reports a structural health verdict via its
exit code (`0` healthy / `1` unhealthy / `2` config error; the reverse wrapper adds
`3` no-spend skip). The
orchestrator owns prompt assembly, evidence verification, disposition, and loop
control; the wrapper owns only the deterministic, safe invocation.

Both wrappers also accept `--web-search <on|off>` (default `off`). Use `on` for
consults and review rounds where a load-bearing external premise may need current
documentation or provider/API verification. The forward Codex wrapper enables
Codex's hosted `web_search`; the reverse Claude wrapper enables
`WebSearch,WebFetch` with `--permission-mode auto` while still granting no
write-capable tools or Bash.

You can also run the wrappers by hand to sanity-check your setup, e.g. (these `/tmp`
paths are an intentional throwaway location *outside* the repo — not Touchstone
working-artifact paths, which live under `.touchstone/`; the wrapper takes whatever
output paths you pass):

```sh
printf 'Review the following and reply with the findings schema.\n' > /tmp/prompt.txt
./.touchstone/methodology/scripts/external-review/external-review-codex.sh \
  --prompt /tmp/prompt.txt \
  --schema .touchstone/methodology/scripts/external-review/findings.schema.json \
  --findings /tmp/findings.json \
  --log /tmp/review.log \
  --cd "$(pwd)" \
  --web-search off
echo "exit=$?"   # 0 healthy, 1 unhealthy, 2 config error
```

Reverse wrapper smoke shape:

```sh
printf 'Review the following and reply with the findings schema.\n' > /tmp/prompt.txt
./.touchstone/methodology/scripts/external-review/external-review-claude.sh \
  --prompt /tmp/prompt.txt \
  --schema .touchstone/methodology/scripts/external-review/findings.schema.json \
  --findings /tmp/claude-findings.json \
  --log /tmp/claude-review.log \
  --wrapper-stderr-log /tmp/claude-review.wrapper-stderr \
  --repo "$(pwd)" \
  --web-search off
echo "exit=$?"   # 0 healthy, 1 unhealthy, 2 config error, 3 no-spend auth skip
```

## Running unattended (automatic mode)

A core benefit of Touchstone is that a whole change runs start-to-finish without
stopping to ask. `.touchstone/methodology/TOUCHSTONE.md` mandates "stay in auto mode; never enter a
plan/approval mode that needs a separate exit," and treats the plan as a *file*,
not a runtime mode. To deliver on that, the orchestrating runtime must be allowed
to write files, run shell commands (grep, tests, git, the review wrapper), and
spawn subagents without per-action prompts. Configure that once and the loop runs
hands-off.

### Claude Code (orchestrator)

Grant the loop's actions through two settings files (this split is also how this
repo is wired):

- **Committed, shareable — `.claude/settings.json` at your repo root.** Let the
  agent create and edit files (plans, skills) without per-edit prompts:

  ```json
  { "permissions": { "allow": ["Write", "Edit"] } }
  ```

- **Local, gitignored — `.claude/settings.local.json`.** The cross-model wrapper
  grant from the section above lives here; add any other repo-specific commands the
  loop runs (test runner, linters) so they don't prompt either:

  ```json
  {
    "permissions": {
      "allow": [
        "Bash(./.touchstone/methodology/scripts/external-review/external-review-codex.sh:*)",
        "Bash(npm test:*)"
      ]
    }
  }
  ```

For a fully hands-off run, use **auto mode** rather than an exhaustive allowlist.
Launch with `--permission-mode auto` (or set `"permissions": { "defaultMode":
"auto" }`):

```sh
claude --permission-mode auto
```

Auto mode runs the agent autonomously but keeps a safety net: a classifier judges
each action and auto-approves the routine ones, stopping only for genuinely risky
operations. That's the right default for Touchstone — the loop runs unattended
without handing over a blanket bypass, and it matches the framework's "stay in auto
mode" discipline. A more conservative option is `acceptEdits` (auto-approves file
edits, still prompts on shell commands).

Reserve `bypassPermissions` (a.k.a. the `--dangerously-skip-permissions` flag) for
throwaway or externally-sandboxed environments only — it disables *all* permission
checks, including the auto-mode safety classifier.

**Do not use `plan` mode.** Touchstone keeps the plan as a markdown file under
`.touchstone/plans/` and relies on the agent staying in auto mode; a runtime plan/approval mode
breaks the loop. Keep the orchestrator on a strong model and effort — e.g.
`"model": "opus"`, `"effortLevel": "high"` in your global `~/.claude/settings.json`.

### Codex CLI

Whether Codex is your orchestrator (reverse path) or just the GPT reviewer (forward
path), configure non-interactive operation in `~/.codex/config.toml`:

```toml
model = "gpt-5.5"
model_reasoning_effort = "high"

# Autonomous, with a safety net (the analog of Claude Code's auto mode):
# the model requests approval when it judges one is needed, and an automated
# reviewer decides — instead of stopping for you.
approval_policy    = "on-request"
approvals_reviewer = "auto_review"
sandbox_mode       = "workspace-write"  # write within the repo without prompts

[sandbox_workspace_write]
network_access = true              # if the loop needs the network
writable_roots = ["/path/to/your-repo", "/path/to/your-repo/.git"]

# Trust the repos the loop runs in so Codex doesn't prompt on entry.
[projects."/path/to/your-repo"]
trust_level = "trusted"
```

- `approval_policy = "on-request"` + `approvals_reviewer = "auto_review"` is the
  recommended autonomous default: the agent runs unattended but an automated
  reviewer adjudicates approvals, mirroring Claude Code's auto-mode safety
  classifier rather than handing over a blanket bypass.
- The forward path's reviewer is launched by the wrapper as
  `codex exec --sandbox read-only --ephemeral …`, which is already non-interactive —
  it only needs Codex installed and authenticated.
- For the reverse path under `auto_review`, add a narrow rule for the exact absolute
  wrapper path in `~/.codex/rules/default.rules` and restart Codex:

  ```python
  prefix_rule(
      pattern = ["/absolute/path/to/repo/.touchstone/methodology/scripts/external-review/external-review-claude.sh"],
      decision = "allow",
      justification = "Allow Touchstone's reverse external-review wrapper from this trusted repo. The wrapper enforces first-party Claude subscription auth, sterile settings, no write-capable tools, schema output, and bounded budget.",
  )
  ```

  You can validate the rule locally before relying on it:

  ```sh
  codex execpolicy check \
    --rules ~/.codex/rules/default.rules \
    /absolute/path/to/repo/.touchstone/methodology/scripts/external-review/external-review-claude.sh \
    --prompt /tmp/prompt.txt --schema /tmp/schema.json \
    --findings /tmp/findings.json --log /tmp/review.log \
    --wrapper-stderr-log /tmp/review.wrapper-stderr
  ```

  A shell-wrapped command such as `bash -lc ...` should not match this rule.
- Reserve the aggressive options for throwaway or externally-sandboxed environments
  only: `approval_policy = "never"` removes the approval gate entirely, and the
  `--dangerously-bypass-approvals-and-sandbox` flag skips approvals *and* sandboxing.

The wrappers themselves never prompt — each self-enforces a per-round watchdog and
returns a structural health verdict via its exit code — so once the orchestrator's
permissions are set, the cross-model arm runs unattended too, degrading to
internal-only (with a logged notice) if the external model is unreachable.

## Customizing

- **Lenses.** The Tier 1 / Tier 2 lens catalogue in `.touchstone/methodology/TOUCHSTONE.md`
  is the highest-leverage thing to tune. The examples there are domain-neutral; add lenses
  for the failure modes your own skills keep hitting. **If you plan to upgrade**, prefer an
  **overlay** — a host-owned file (e.g. a `touchstone-local.md` your `CLAUDE.md`/`AGENTS.md`
  also points at) that `install.sh --force` never touches — over editing the vendored
  `TOUCHSTONE.md` in place. Editing in place is fine, but it means owning the merge on each
  bump (now a reviewable `git diff .touchstone/methodology` you re-apply your edits onto).
- **Opting out of vendoring (`--ignore-all`).** The default commits the methodology so a
  fresh checkout has Touchstone ready for contributors. If you would rather your host ignore
  the whole namespace and commit nothing of Touchstone, install with `./install.sh
  /path/to/your-repo --ignore-all` — it writes the blanket `/.touchstone/` rule instead of
  the negation block. (If the methodology is already tracked, the installer prints the `git
  rm -r --cached .touchstone/methodology` follow-up, since gitignoring a tracked path does
  not untrack it.)
- **Findings schema.** `.touchstone/methodology/scripts/external-review/findings.schema.json`
  is what makes the reviewer's output
  machine-checkable. Keep it in sync with how your orchestrator consumes findings
  (the severity enum drives the termination teeth; `location_concept` drives the
  re-raise match; evidence fields also carry web-source details for web-backed
  findings).
- **Reviewer models.** Both wrappers take `--model` / `--effort`; the defaults
  (`gpt-5.5` / `claude-opus-4-8`, `high`) are sensible starting points.

## Background

The pattern is described in more depth in a companion essay on cross-model review
loops for autonomous agentic development. It builds on
established work (Self-Refine, Reflexion, ChatDev, MetaGPT, Agent-as-a-Judge) but
puts its weight on a particular synthesis: staged plan *and* implementation review,
internal *and* external model-family review, fresh contexts, explicit disposition
records, and verification before accepting or rejecting findings. The novelty isn't
that agents can loop — it's making the loop adversarial enough to matter and
disciplined enough to ship work from.

## License

MIT — see `LICENSE`.
