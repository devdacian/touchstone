# Claude Code entry (Touchstone source repo)

This repo develops Touchstone and dogfoods it on itself; the methodology lives
under `.touchstone/methodology/`. Because Touchstone is always relevant here, this
entry file eager-imports the full methodology so every session has it loaded:

@.touchstone/methodology/TOUCHSTONE.md
@.touchstone/methodology/TOUCHSTONE-claude.md

This repo's own dogfood tests for the external-review machinery live in
`tests/external-review/` (NOT under `.touchstone/methodology/`, so they are never
vendored into hosts). When you change the classifier or wrappers under
`.touchstone/methodology/scripts/external-review/`, run and keep them green:
`bash tests/external-review/test-classifier.sh` and
`bash tests/external-review/test-forward-wrapper-argv.sh` and
`bash tests/external-review/test-reverse-wrapper-argv.sh`.

When you change `install.sh`, run and keep green:
`bash -n install.sh` and
`bash tests/test-install-output.sh`.
