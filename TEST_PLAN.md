# Test Plan

How to test this repo, what the current suite covers, where it falls short,
and the work to close those gaps.

## 1. What this repo ships

| Part | What it is | Main risk |
|------|------------|-----------|
| **Agent roster** | 282 agent `.md` files across 18 divisions (`divisions.json`) | Bad frontmatter, broken code fences, near-duplicates, or drift from the README, runbooks and i18n map |
| **Converter** | `scripts/convert.sh`, `scripts/lib.sh`, `scripts/build-hermes-plugin.py` render the roster for 15 tools (Claude Code and Copilot install the source files as they are) | Output that parses but is wrong (mangled descriptions, dropped agents or tools) |
| **Installer** | `scripts/install.sh` (1,800 lines) copies or links that output into 17 tools (`tools.json`) | Files land in the wrong place, overwrite each other, partial installs, wrong exit codes |
| **Contracts** | `divisions.json`, `tools.json`, `strategy/runbooks.json` | Disagreement with the scripts, the directories on disk, or the CI path filters |
| **Docs** | `README.md`, `CONTRIBUTING.md`, `integrations/*/README.md`, `strategy/`, `examples/` | Stale counts, dead links, references to agents that were renamed |

There is no application code, so all of the testing targets the scripts and
the data they consume.

## 2. Current suite and baseline

Baseline run on 2026-10-23 at `4e3ac3c`, on Linux with bash 5.2 and Python 3.13
(PyYAML 6.0.3).

**All 30 entry points pass.** Run one after another, they take about 8 minutes.

| Area | Scripts | Run by CI in | Result | Time |
|------|---------|--------------|--------|------|
| Contracts | `check-divisions.sh`, `check-tools.sh`, `check-runbooks.sh` | their own workflows | pass | ~2s |
| Shell syntax | `bash -n scripts/*.sh` | `test-install.yml` (Linux + macOS) | pass | <1s |
| Agent lint | `lint-agents.sh` (all 282 agents) | `lint-agents.yml` (changed files only; whole roster only when the linter changes) | 0 errors, 58 warnings (missing recommended sections) | 31s |
| Originality | `check-agent-originality.sh` (all 282 agents) | `lint-agents.yml` (changed files only) | pass, no near-duplicates | 33s |
| Lint regressions | `test-folded-frontmatter`, `test-lint-fences`, `test-lint-qwen-placeholders`, `test-frontmatter-closing` | `lint-agents.yml` / `check-tools.yml` | pass | ~2s |
| Converter regressions | `test-convert-frontmatter`, `-slug-collisions`, `-symlink-output`, `-parallel-failure`, `-fence-model` | `check-tools.yml` (Linux only) | pass | ~41s |
| Generated-output eval | `test-convert-outputs.sh` | `check-tools.yml` (Linux only) | 32/32 invariants over 282 agents × 15 tools; manifest matches with drift enforced | 180s |
| Hermes contract | `check-hermes-plugin.py`, `check-hermes-config-rewrite.sh` | `check-tools.yml`, `check-hermes-config-rewrite.yml` | pass | ~1s |
| Hermes runtime | `test-hermes-plugin.py` | **not run in CI** | 6/6 pass after `convert.sh --tool hermes`; all 6 error without that step | 1s |
| Installer | `test-install.sh` | `test-install.yml` (Linux + macOS) | 66 pass, **2 xfail** (see G11) | 166s |
| Installer regressions | `test-agent-selection`, `test-cli-usage`, `test-install-{hermes-destination,conversion-failure,all-path-collision,selection-completeness,continue-after-failure}` | `check-tools.yml` (Linux only) | pass | ~30s |
| | `test-install-{openclaw-registration,link-ownership,parallel-logs}` | `test-install.yml` (Linux + macOS) | pass | ~2s |

The "Run by CI in" column shows CI at the baseline commit. Phase 1 (below)
moved every test behind `scripts/run-tests.sh`; run it with `--list` to see
which suite each test is in now.

### Running it locally

Prerequisites: bash 3.2 or newer, Python 3.11+ with PyYAML, git, and the
standard coreutils (`awk`, `find`, `mktemp`, `sha256sum`/`shasum`). The tests
isolate `HOME` and write only to `mktemp` directories, so it is safe to run them
on a machine where the tools are really installed.

```bash
./scripts/run-tests.sh --fast          # under a minute: everything except the slow tests
./scripts/run-tests.sh                 # about 8 minutes: every suite CI runs
./scripts/run-tests.sh checks install  # only some suites: checks, outputs, install, roster
./scripts/run-tests.sh --list          # what each suite contains
./scripts/lint-agents.sh path/to/agent.md   # one agent
```

### Which checks to run for which change

When in doubt, run `./scripts/run-tests.sh`. For a narrower run:

| Change | Run at least |
|--------|--------------|
| Agent added or edited | `lint-agents.sh <file>`, `check-agent-originality.sh <file>`, `test-convert-outputs.sh --drift=advisory` |
| Agent renamed or removed | The row above, plus `check-runbooks.sh`, and update the README roster and `scripts/i18n/agent-names-zh.json` (nothing checks those two yet; see G6 and G8) |
| `convert.sh` / `lib.sh` | `run-tests.sh checks roster`, then `test-convert-outputs.sh --update` |
| `install.sh` | `run-tests.sh install`, plus `check-hermes-config-rewrite.sh` |
| `build-hermes-plugin.py` | `run-tests.sh checks` |
| New tool (`tools.json`) | `check-tools.sh`, `test-convert-outputs.sh --update`, plus a new install-destination case (see Phase 2) |
| New division (`divisions.json`) | `check-divisions.sh`, `run-tests.sh install` |
| New test script | Register it in `TESTS` in `scripts/run-tests.sh`; the runner fails until you do |

## 3. Gaps found

| # | Gap | Evidence | Impact |
|---|-----|----------|--------|
| G1 | `scripts/test-hermes-plugin.py` is in the repo but no workflow runs it | It is not referenced in any `.github/workflows/*.yml`, and it needs `convert.sh --tool hermes` to run first | The Hermes router's runtime behaviour (launch, wait, cancel, failure paths) is untested in CI |
| G2 | 7 of the 17 tools have no install test | No test passes `--tool` for antigravity, cursor, kimi, opencode, osaurus, vibe or zcode. gemini-cli and qwen are covered only by the collision and failure cases | A wrong destination for those tools would pass CI |
| G3 | The OpenCode limit of 119 agents is never tested | Nothing exercises `tool_cap` or `capacity_warn` | The warning the README promises could silently disappear |
| G4 | The converter is tested only on Linux | `check-tools.yml` runs on `ubuntu-latest` only; only the `test-install*` family also runs on macOS | The bash 3.2 support claimed in the script headers is unverified for `convert.sh` and the outputs eval |
| G5 | The whole roster is linted only when the linter itself changes | `lint-agents.yml` has no `push` trigger and lints only changed files | An agent merged around the linter, or a rule tightened later, leaves `main` failing without anyone seeing it |
| G6 | The zh-CN name map has drifted | 8 keys in `agent-names-zh.json` match no current agent (the `Academic *` names, `SRE`, `Security Engineer`, `Healthcare Marketing Compliance`). 138 of 282 agents have no entry | Renamed agents silently lose their translation |
| G7 | No static analysis of the shell scripts | No `shellcheck` step anywhere | Quoting and word-splitting bugs, which caused several past install bugs, are found only when a test happens to hit them |
| G8 | Docs are not checked | No link checker. The README roster is complete today but nothing enforces that. The acknowledgments still say "230+ agents" while the roster has 282 | Dead links and stale claims accumulate |
| G9 | The interactive installer is untested | Every test passes `--no-interactive`, so the TUI (`selector`, `screen_*`, `interactive_wizard`) is never run | The default path a first-time user takes has no coverage |
| G10 | No end-to-end check that real tools load what was installed | All tests stop at "the file landed here" | A format the tool rejects, such as a frontmatter key or a size limit, is caught only by users |
| G11 | A known installer bug is parked as xfail | `test-install.sh` has two xfail cases for `--parallel` with a `--path` that contains a space or glob characters: it exits 123 and installs 0 agents. The test says msitarzewski/agency-agents#755 fixes it, but that fix is not in this tree | Anyone with a spaced install path who uses `--parallel` gets a failed install, and CI stays green |

## 4. Plan

The phases are ordered by value per effort. Phases 1–3 are small, self-contained
PRs. Phases 4–5 cost more and can be scheduled as needed.

### Phase 1: Run the tests that already exist (G1, G4, G5)

**Status: implemented, not yet run in GitHub Actions.** Every suite passes
locally on Linux. The macOS jobs will first run when a pull request triggers
these workflows.

1. **One runner.** `scripts/run-tests.sh` holds the test list in four suites:
   `checks`, `outputs`, `install` and `roster`. It runs every selected test even
   after a failure, then names all the failures. It also fails if a
   `scripts/test-*` or `scripts/check-*` file is not registered, or if a
   registered file no longer exists. That is how `test-hermes-plugin.py` went
   unrun, and the check makes it impossible to repeat.
2. **Hermes runtime tests (G1).** The `checks` suite builds the plugin into a temp
   directory and runs `test-hermes-plugin.py` against it, using the new
   `AGENCY_HERMES_PLUGIN` variable.
3. **macOS for the converter (G4).** `check-tools.yml` runs
   `run-tests.sh checks outputs` on `ubuntu-latest` and `macos-latest`. It pins
   Python 3.12 and PyYAML so both runners parse the same way.
4. **Installer suite.** `test-install.yml` runs `run-tests.sh install`. That suite
   now includes the installer regressions that used to run only on Linux under
   `check-tools.yml`.
5. **Whole-roster lint on `main` (G5).** In `lint-agents.yml`, every push to
   `main` and a weekly run (Mondays 06:23 UTC) lint and originality-check all
   282 agents. Pull requests behave as before, except that a change to
   `check-agent-originality.sh` or `run-tests.sh` also triggers the whole-roster
   job. The folded-frontmatter and Qwen-placeholder fixtures now run on every
   PR (`checks` suite) instead of only when the linter changes.

Two check names changed, so update branch protection if it requires the old
ones:

| Old | New |
|-----|-----|
| tools.json is the single source of truth | checks and converted outputs (ubuntu-latest), and the same with (macos-latest) |
| Whole roster, when the linter changes | Whole roster (linter changes, main, weekly) |

`check-divisions.yml`, `check-runbooks.yml` and
`check-hermes-config-rewrite.yml` are unchanged. Their scripts also run in the
`checks` suite, which costs a few seconds of duplicated work.

**Done when:** every `scripts/test-*` and `scripts/check-*` file is run by CI or
listed in the runner's `HELPERS` with a reason. The runner now enforces this.

### Phase 2: Cover every tool's install (G2, G3, G11)

1. Land or port the `--parallel` spaced-path fix (msitarzewski/agency-agents#755).
   Then change the two `xfail_eq` cases in `test-install.sh` to `assert_eq`
   so the bug cannot come back.

2. Add `scripts/test-install-every-tool.sh`, a table-driven test that reads
   `tools.json`. For each tool, it creates a sandbox `HOME` and a small fixture
   `integrations/` tree, runs `install.sh --no-interactive --no-convert --tool <t> --agent <slug>`,
   and asserts that the file lands at the `dest` template from `tools.json`.
   Because the expected values come from the catalog, a new tool is covered
   automatically, and a tool with no assertable destination fails the test.
3. In the same loop, repeat each case with `--link` and assert that a symlink
   points back into the repo. Re-run the install and assert the file count is
   unchanged, to check idempotency.
4. OpenCode limit: select 120 fixture agents and assert the warning appears.
   Select 119 and assert it does not.
5. Run `--parallel --jobs 4` against a sequential install of the same selection
   and `diff -r` the two trees.

**Done when:** all 17 tools have a destination assertion, the OpenCode warning
is tested in both directions, and `test-install.sh` reports no xfail cases.

### Phase 3: Add cheap consistency checks (G6, G7, G8)

1. **shellcheck**: add a step running `shellcheck -S warning scripts/*.sh`.
   Start it as advisory with a recorded baseline, fix or annotate the existing
   findings, then make it blocking.
2. **Python**: run `python3 -m py_compile scripts/*.py` (blocking), plus `ruff
   check scripts/` (advisory).
3. **i18n map**: add `scripts/check-i18n.sh`. It fails when a key in
   `agent-names-zh.json` matches no roster `name`, which fails today on the 8
   keys listed in G6, so fix those in the same PR. It reports coverage of
   144/282 as advisory output.
4. **README roster**: fail if any agent file is not linked from `README.md`
   (this passes today), and warn when a numeric agent-count claim differs from
   the real count.
5. **Links**: run an offline relative-link check over `README.md`,
   `CONTRIBUTING*.md`, `integrations/**/README.md`, `examples/` and
   `strategy/`. Extend `check-runbooks.sh` so that agent names in
   `strategy/playbooks` and `strategy/coordination` must also resolve.

### Phase 4: Test the interactive installer (G9)

Drive `install.sh` (with no flags) under a pseudo-terminal, using Python's
`pty` module so no extra dependency is needed:

- Accepting the defaults with Enter installs the detected tools and nothing else.
- Toggling one tool and one division writes exactly that selection.
- Quitting on the review screen writes nothing and exits 0.
- With stdin not a TTY, the installer falls back to the non-interactive path.
- Run with `TERM=dumb` and `NO_COLOR=1`, which must not crash the TUI.

### Phase 5: Release smoke tests, manual or nightly (G10)

This phase is not a gate on every PR. Run it before a release, or nightly
where the tool's CLI can run headless:

- For each tool whose CLI is installable in CI (for example `opencode`,
  `qwen`, `gemini`, `codex`, `hermes`): install into a sandbox `HOME`, use the
  tool's own command to list the agents it registered, and compare the count
  with the roster. For OpenCode, compare with the 119-agent limit.
- For Hermes: load the generated plugin in a real Hermes process and run one
  routed task.
- Manual spot check: in Claude Code, invoke 2 or 3 agents per division and
  confirm the persona loads with no frontmatter or fence debris in the prompt.

### Optional: agent quality evals

Linting proves an agent is well formed, not that it is good. If that matters,
build a small on-demand eval: a fixed task per sampled agent, graded against a
rubric (stays in role, follows its own workflow, no hallucinated tools). Keep
it out of PR CI because of cost and nondeterminism, and track scores per
release.

## 5. Exit criteria

- Phases 1–3 are merged, and CI is green on Linux and macOS.
- Every script under `scripts/` is either run by CI or explicitly marked
  manual in `scripts/run-tests.sh`.
- Every entry in `tools.json` has an install-destination assertion, enforced by
  the test reading the catalog rather than a hand-written list.
- `main` is linted as a whole at least weekly.
