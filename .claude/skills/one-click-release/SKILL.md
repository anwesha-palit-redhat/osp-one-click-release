---
name: one-click-release
description: Verify and execute the staged OpenShift Pipelines release workflow for a specific X.Y.Z version. Use for release configuration, builds, stage image copying, resumable status checks, or explicitly approved production releases.
---

# One-Click Release

Use the executable interface at `scripts/one-click-release.sh`. Do not reproduce or run commands from the companion Markdown stage references; the scripts are the execution authority.

## Start

1. Parse the skill argument as an `X.Y.Z` version.
2. Run the read-only workflow:

   ```bash
   .claude/skills/one-click-release/scripts/one-click-release.sh verify VERSION
   ```

3. Summarize the generated reports and the first blocking step. A blocker exit is expected when action is needed.

To inspect one non-production stage, run:

```bash
.claude/skills/one-click-release/scripts/one-click-release.sh verify VERSION --stage config
.claude/skills/one-click-release/scripts/one-click-release.sh verify VERSION --stage build
.claude/skills/one-click-release/scripts/one-click-release.sh verify VERSION --stage image-copy
```

## Execute a blocking step

1. Show the user the blocking step, proposed action, and relevant report or manifest path.
2. Ask `Step X.Y: DESCRIPTION. Execute?`
3. Only after an explicit yes, run:

   ```bash
   .claude/skills/one-click-release/scripts/one-click-release.sh execute VERSION --stage STAGE
   ```

4. When the script requests its exact approval phrase, provide it only because the user approved that same step.
5. Summarize the re-verification result. Stop if the command exits with another blocker.

Never bypass the script approval prompt or invoke an `execute.sh` after a decline.

## Production release gate

Production is not part of the default `verify VERSION` flow. After Config, Build, Image Copy, and QE approval are complete, ask exactly:

`All builds verified and images copied. Ready to start production release? (yes/no)`

Only after an explicit yes, run:

```bash
.claude/skills/one-click-release/scripts/one-click-release.sh verify VERSION --stage production-release
```

Provide the script's separate `start production-release VERSION` phrase only after that confirmation. Production mutations still require the additional per-step execute approval.

## Run through a stage

Use the sequential read-only command when requested:

```bash
.claude/skills/one-click-release/scripts/one-click-release.sh run VERSION --through STAGE
```

The command stops nonzero at the first blocker and is safe to rerun. Selecting `production-release` still activates its separate gate.

## Invariants

- Treat verification as read-only and execution as explicitly approved mutation.
- Preserve sequential step order and stop at the first blocking step.
- Keep all Konflux operations in `tekton-ecosystem-tenant`.
- Never print credentials or approval secrets.
- Use `oc create -f` for generated Release CRs; never use `oc apply` for them.
- Preserve reports under `reports/{MAJOR_MINOR}/{VERSION}/{config|build|image-copy|release}/` and manifests under `manifest/{stage|prod}/`.
- Re-run verification after execution; external system state remains the source of truth.

For background, manual remediation, failure modes, and the exact legacy behavior retained by the scripts, consult `SETUP.md` and the `STAGE_*.md` files only as references.
