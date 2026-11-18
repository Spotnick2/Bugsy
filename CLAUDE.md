# CLAUDE.md

This file guides Claude Code (claude.ai/code) in this repository.

## What this is

Bugsy is a **bug-reporting addon for WoW: Forever 1.60.1** (Interface `16001`, Lua 5.1), single
owner (Spotnick). It replaces the usual error collector and its viewer: it catches errors, groups them into problems
with their evidence, says which addon seems involved and how sure that is, and prepares a report a
player can copy to the author. An optional author library, `LibBugsy-1.0`, adds context and
breadcrumbs. The name is the gangster's: the player-facing wording may play on it, the reports never
do.

- The design is [docs/DESIGN.md](docs/DESIGN.md). Read it before changing a layer.
- What is verified, measured or still open: [docs/FOREVER-PROBE.md](docs/FOREVER-PROBE.md).
- The report format: [docs/REPORT-SCHEMA.md](docs/REPORT-SCHEMA.md). The library:
  [docs/LIBRARY.md](docs/LIBRARY.md). The plan: [docs/BACKLOG.md](docs/BACKLOG.md).

## The references

The reference addons (other error collectors and viewers, in `References\Addons\DevelopmentTools`)
are **All Rights Reserved**: behaviour references only, never copy their code. **Never name them**
in this repo, commits, issues or PRs (owner's rule): say "the collector", "its viewer", "an addon
that embeds a copy". The one exception is interoperability: the collector's global and event
names, as code strings in `Capture.COLLECTOR` and `tests\wow_stubs.lua` (`COLLECTOR`), nowhere
else. This repo is MIT.

## Rules

- **The error handler is the critical path** (DESIGN §3): it never throws, never recurses, checks
  every value with `Safe` before touching it, stays within its budget, and defers everything else
  to the drain. A change there needs a test and, for client behaviour, a probe result.
- **Secret values** (DESIGN §5): check before `tostring`, `#`, comparison, concatenation or use as
  a key. Store a marker, never the value. Never try to recover restricted data.
- **Never say a report was submitted.** Bugsy sends nothing anywhere.
- **Attribution keeps its uncertainty**: `named`, `inStack` and `suspect` stay separate; pattern
  explanations are not facts.
- **Bounded everything**: queues, samples, counters' companions, strings, nesting.
- **No chat spam**: one quiet line per new problem, throttled, held during combat.
- Every client API through `Compat` (`rawget`), so the tests' strict stubs read a missing API as
  nil.

## Toolchain

```powershell
pwsh tests\run.ps1                 # luac -p + every tests\test_*.lua, through WowTestKit (tests\kit.pin)
pwsh Tools\deploy.ps1              # copy !Bugsy into _forever_\Interface\AddOns
pwsh Tools\deploy.ps1 -Probe       # ...and BugsyProbe (deploys ..\ForeverProbe first)
```

Mutation-test a new test: break the behaviour, see it go red.

## Workflow

Issue → branch → PR with `Closes #N`; the owner merges. Plans and significant changes get an
adversarial review (Codex via `/codex-consult`; Fable as a second, independent pass).

## Releasing

`References\Docs\RELEASING.md` is the guide. A tag `vX.Y.Z` does three things:
- CurseForge (project **1812842**, `X-Curse-Project-ID`) builds its file from the tag, through
  its webhook. No CurseForge key lives here.
- CI's `release` job publishes the zip `check` built and checked as a GitHub Release, with
  `release.json` (`tests/release_files.sh`, the template, unchanged).
- CI's `wago` job uploads the same zip to Wago Addons (project **mKOajgNx**, `X-Wago-ID`; the
  `WAGO_API_TOKEN` repo secret, set from the owner's secrets file).

The tag's `## vX.Y.Z` section of `CHANGELOG.md` is the notes. `README.curseforge.md` is
untracked: the owner pastes it into CurseForge and Wago's Description tab. A release tag updates
both READMEs in its prep PR (RELEASING.md §3).

## Consulting Codex

Hand it this file, `docs/`, and the evidence files FOREVER-PROBE.md cites. What is risky here and
worth a second opinion: the critical path (recursion, secrets, budgets), grouping signatures
(merging distinct bugs, splitting one), provider switching when another handler takes over, and
anything that could make a report claim more than its evidence.
