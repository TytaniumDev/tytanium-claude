---
name: overnight
description: Run a long, autonomous code-improvement session. Multiple critic sub-agents scan the repo in parallel, propose fixes, and ship them as themed PRs. Bounded by a 5-hour wall clock and a 20-PR cap. Self-merges when CI passes.
disable-model-invocation: true
allowed-tools:
  - Bash(gh *)
  - Bash(git *)
  - Bash(date *)
  - Bash(mkdir *)
  - Bash(rm *)
  - Bash(cat *)
  - Bash(echo *)
  - Bash(test *)
  - Bash(sleep *)
  - Bash(find *)
  - Bash(grep *)
  - Bash(wc *)
  - Bash(ls *)
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - Task
---

# Overnight: Autonomous Codebase Improvement

Run a long-form, multi-critic improvement session against the current repo. Discover issues, propose fixes, deliberate, ship as themed PRs, and self-merge once CI is green. Wakes up tomorrow's Tyler to a series of small, reviewable commits on `main` and a written summary of what changed and why.

This skill is **fully autonomous**. There are no human checkpoints. Stop with `Ctrl+C` if you need to bail; whatever PRs have already merged will stay merged.

## Hard Constraints

These are non-negotiable. Treat them as kill-switches, not guidelines.

| Constraint | Value | Enforced by |
|---|---|---|
| Wall-clock budget | **5 hours** from start | Step 2 (set deadline), checked between every PR |
| PR cap | **20 PRs** merged per run | Counter checked between every PR |
| Per-PR time limit | **30 minutes** of work | Fixer sub-agent enforces internally |
| Verification gate | Tests pass + analysis clean | Step 6 before merge |
| Branch model | Long-lived working branch, **squash-merged PRs** to main | Step 6 |
| Off-limits paths | None | n/a |
| Human review | None | n/a — full auto |

## Step 1: Pre-flight checks

Before doing anything, verify the environment is sane.

```bash
# Confirm we're in a git repo with a clean working tree
git status --porcelain
```

If the working tree is not clean, **abort** with a clear message. The user should commit or stash before running `/overnight`.

```bash
# Confirm we're on (or can switch to) main
git rev-parse --abbrev-ref HEAD
git fetch origin main
git checkout main
git pull --ff-only origin main
```

If `main` is not the default branch for this repo, detect the default with `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'` and use that everywhere `main` appears below.

```bash
# Confirm gh is authenticated
gh auth status
```

If any of these checks fail, abort and tell the user what's wrong.

## Step 2: Establish the run

Create a unique run identifier and a runtime working directory **outside the repo** (so it doesn't pollute git):

```bash
RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
RUNTIME_DIR="/tmp/overnight-${RUN_ID}"
mkdir -p "$RUNTIME_DIR"
DEADLINE=$(($(date +%s) + 5 * 3600))
echo "$DEADLINE" > "$RUNTIME_DIR/deadline"
echo "0" > "$RUNTIME_DIR/pr_count"
```

Remember `RUN_ID`, `RUNTIME_DIR`, and `DEADLINE` for the rest of the run. Every loop iteration must check `date +%s` against the deadline before starting new work.

Create the long-lived working branch:

```bash
WORKING_BRANCH="overnight/${RUN_ID}"
git checkout -b "$WORKING_BRANCH"
git push -u origin "$WORKING_BRANCH"
```

PRs will branch off `$WORKING_BRANCH`, and once they merge, `$WORKING_BRANCH` is fast-forwarded so subsequent PRs see the latest state.

## Step 3: Bootstrap or read `agent-memory/`

The persistent memory directory lives **in the target repo** (not in this skill). Check whether it exists:

```bash
test -d agent-memory
```

### If it does not exist

Create it from the templates below. Commit the bootstrap as the first PR of the run (so subsequent PRs already see the directory).

Files to create (use the `Write` tool):

- `agent-memory/README.md` — see template at the bottom of this skill
- `agent-memory/codebase-map.md` — empty stub with header
- `agent-memory/style-decisions.md` — empty stub with header
- `agent-memory/avoid-list.md` — empty stub with header explaining TTL
- `agent-memory/open-backlog.md` — empty stub
- `agent-memory/summaries/.gitkeep`

Then bootstrap-PR the directory:
```bash
git checkout -b "overnight/${RUN_ID}/bootstrap-agent-memory"
git add agent-memory/
git commit -m "chore: bootstrap agent-memory/ for /overnight runs"
git push -u origin "overnight/${RUN_ID}/bootstrap-agent-memory"
gh pr create --base "$WORKING_BRANCH" --title "chore: bootstrap agent-memory/" \
  --body "Initial scaffold for the persistent memory directory used by /overnight."
```

Then verify CI and squash-merge per Step 6. This counts as PR #1 of the run.

### If it does exist

Read every file in `agent-memory/` (Read tool), and **load into your active context**:

- `codebase-map.md` — orient yourself before scanning
- `style-decisions.md` — these are LAW. Never re-litigate a decision recorded here. If a critic proposes something that contradicts a style decision, the proposal is dropped without further deliberation.
- `avoid-list.md` — anything dated within the last 7 days is still active and must be respected. Older entries can be ignored (the historian will prune them later).
- `open-backlog.md` — these are existing known issues. Treat them as pre-seeded findings before the critics run.
- `summaries/` — read the **3 most recent** summaries to understand recent direction.

## Step 4: Detect language and toolchain

Run a quick survey to figure out what you're working with. This determines which critics apply and how to run tests/analysis.

```bash
ls -1 package.json pyproject.toml Cargo.toml go.mod pubspec.yaml composer.json Gemfile pom.xml build.gradle 2>/dev/null
```

Read the relevant manifest(s) to determine:

1. **Test command.** Examples: `npm test`, `pytest`, `cargo test`, `go test ./...`, `flutter test`. If the repo has a `Makefile`, `justfile`, or scripts in `package.json`, prefer those.
2. **Static analysis command.** Examples: `npm run lint && npm run typecheck`, `ruff check && mypy .`, `cargo clippy`, `flutter analyze`. Mirror what CI runs.
3. **Build command** (only if needed for verification). Examples: `npm run build`, `cargo build`, `flutter build apk`.
4. **Whether a UI layer exists.** Look for: `*.tsx`/`*.jsx`/`*.vue`/`*.svelte`, `lib/widgets/`, `templates/` directories, frontend frameworks in dependencies. If yes, the **accessibility** critic applies. If no, skip it.
5. **Whether the type system is strong-by-default.** Rust, OCaml, Haskell, etc. → skip the **type-safety tightener** critic. TypeScript with `any`, Python without strict typing, Dart with `dynamic`, etc. → it applies.

If CI configuration exists in `.github/workflows/`, read the actual workflow files. Your verification commands must produce the same results CI would. If you're unsure what command CI runs, **read the workflow YAML directly**.

Record what you found in `$RUNTIME_DIR/toolchain.md` for reference during the run.

## Step 5: Coordinator + critic deliberation

This is the discovery phase. Goal: produce a deduped, prioritized, themed backlog of fixes.

### 5a. Dispatch critic sub-agents in parallel

Use the **`Task` tool** to launch the applicable critics simultaneously (one assistant turn, multiple Task calls). Each critic gets the prompt template below filled in with its specialty. Each critic must return a structured list of proposals.

**The full critic roster:**

1. `code-smell` — duplication, overly long functions, deeply nested logic, magic numbers, awkward names, comments that have drifted from the code, leaky abstractions, primitive obsession. Always applies.
2. `architecture` — modules with too many responsibilities, circular deps, layer violations, missing abstractions, abstractions that exist only once and could be inlined, file/directory structure incoherent with the conceptual model. Always applies.
3. `performance` — unnecessary allocations, synchronous work that should be async, N+1 patterns, inefficient algorithms in hot paths, dropped opportunities for memoization or batching. Always applies. *Be conservative — never sacrifice readability for micro-optimizations.*
4. `test-coverage` — code paths without tests, branches without tests, integration tests that would catch real bugs that unit tests miss, test files that test nothing meaningful. Always applies. **High priority** because the verification gate depends on tests.
5. `documentation` — missing or stale docstrings on public APIs, README drift from actual behavior, examples that no longer compile, missing module-level docs. Always applies.
6. `dependency-hygiene` — outdated packages with security advisories, unused dependencies, version pinning issues, dependencies that could be replaced with the standard library. Always applies. *Run `npm audit` / `pip list --outdated` / `cargo outdated` / equivalent first.*
7. `dead-code` — unused exports, unreachable functions, commented-out blocks left behind, files referenced nowhere, generated artifacts that shouldn't be in source. Always applies.
8. `consistency` — divergent patterns for the same task (two HTTP clients, two error-handling styles, two ways to format dates). Picks one and standardizes. Always applies. **This critic's proposals carry the tiebreaker weight in deliberation.**
9. `todo-fixme` — comments marking known issues. For each, decides: fix now, file as backlog item in `agent-memory/open-backlog.md`, or remove if obsolete. Always applies.
10. `type-safety` — `any`/`dynamic`/`Object` where a concrete type would do, missing return type annotations, nullable-where-non-nullable-suffices. Apply only if the language allows for tightening (skip for Rust, OCaml, etc.).
11. `accessibility` — missing semantic labels, hardcoded text that should be localized, contrast issues, missing ARIA roles, keyboard-trap interactions. Apply only if the codebase has a UI layer.

**Critic prompt template** (fill in `<CRITIC_NAME>` and `<CRITIC_DOMAIN>`):

```
You are the <CRITIC_NAME> critic in an autonomous codebase improvement run.

Your sole concern: <CRITIC_DOMAIN>.

You are NOT writing fixes — only proposing them. Another sub-agent will implement.

CONTEXT:
- Repo root: $(pwd)
- Toolchain: <contents of $RUNTIME_DIR/toolchain.md>
- Style decisions to respect (these are LAW): <contents of agent-memory/style-decisions.md>
- Avoid list (do not propose anything matching these, dated within last 7 days): <contents of agent-memory/avoid-list.md>

INSTRUCTIONS:
1. Scan the codebase for issues within your domain. Use Read, Grep, Glob.
2. For each issue, produce a proposal with these fields:
   - id: <CRITIC_NAME>-<short-slug>
   - severity: critical | major | minor
   - file(s): paths affected
   - summary: one sentence describing the issue
   - proposed_fix: one paragraph describing the fix
   - estimated_blast_radius: small | medium | large (lines changed across files)
   - high_risk_area: true if the fix touches error handling, auth, data persistence, or public APIs

3. Return ONLY a JSON array of proposals. No prose. No code fences. No commentary.
   If you find nothing, return [].

4. Be ruthless about scope. A single proposal should be one coherent change.
   If you'd want to break it into multiple PRs, return multiple proposals.

5. Do not propose anything you'd be uncomfortable defending in code review.
   "It's slightly nicer this way" is not a valid proposal.

Time budget for this scan: 10 minutes. Return what you have at that point.
```

Launch these in **parallel** (multiple Task calls in one assistant turn). Each returns a JSON array of proposals.

### 5b. Coordinator deliberation

Once all critics have returned, **you** (the orchestrator) act as the coordinator. Aggregate all proposals into `$RUNTIME_DIR/proposals.json`. Then:

1. **Drop anything** that contradicts `agent-memory/style-decisions.md` or appears in `agent-memory/avoid-list.md` (recent entries).
2. **Detect overlaps** — two or more proposals that touch the same files or the same logical concern.
3. **Reconcile overlaps.** When critics disagree on the same code:
   - The proposal that improves *consistency and readability* wins.
   - If still tied, prefer the proposal with smaller blast radius.
   - If still tied, prefer the proposal whose critic is higher in the priority order: `consistency` > `architecture` > `code-smell` > `performance` > everything else.
   - **Never** ship two contradictory fixes for the same code. Pick one and drop the other.
4. **Group into themes.** A theme is one PR's worth of work — multiple proposals that fit together. Examples of good themes:
   - "Remove dead code across the bot command modules"
   - "Standardize error handling on Result-style returns in API layer"
   - "Add tests for the rate-limit middleware"
   - "Tighten types in event handlers (eliminate `any`)"
   - **Bad** themes: anything that crosses critic domains randomly, anything bigger than ~500 lines changed.
5. **Prioritize themes.** Order by:
   - Highest severity first (critical > major > minor).
   - Within severity, prefer themes that **unblock** other themes (e.g. dead-code removal often unblocks consistency/architecture work).
   - Then prefer smaller blast radius (faster, lower risk).
6. Write the prioritized theme list to `$RUNTIME_DIR/backlog.md` with one section per theme, listing the proposals it absorbs.

The coordinator output should be a backlog of **at most ~25 themes** even if there are more proposals — pick the best 25. The PR cap is 20, and you want some slack.

## Step 6: The PR loop

For each theme in priority order:

### 6a. Budget checks (do this BEFORE starting the theme)

```bash
NOW=$(date +%s)
DEADLINE=$(cat "$RUNTIME_DIR/deadline")
PR_COUNT=$(cat "$RUNTIME_DIR/pr_count")

# Stop if out of time
if [ "$NOW" -ge "$DEADLINE" ]; then exit_loop_to_step_7; fi

# Stop if at the PR cap
if [ "$PR_COUNT" -ge 20 ]; then exit_loop_to_step_7; fi

# Soft signal: if less than 30 minutes left, only consider themes that are small/medium blast radius
TIME_LEFT=$((DEADLINE - NOW))
if [ "$TIME_LEFT" -lt 1800 ] && [ "$THEME_BLAST_RADIUS" = "large" ]; then
  skip_to_next_theme
fi
```

### 6b. Make sure the working branch is up-to-date

Before starting each theme, sync the working branch with main (so each PR sees the latest merged state):

```bash
git checkout "$WORKING_BRANCH"
git fetch origin main
git merge --ff-only origin/main || git merge --no-edit origin/main
git push origin "$WORKING_BRANCH"
```

### 6c. Spawn the fixer sub-agent

Use the `Task` tool with this prompt:

```
You are the FIXER sub-agent for theme: <THEME_TITLE>.

Your job: implement the proposals in this theme as a single coherent PR, with passing tests and analysis.

CONTEXT:
- Theme description and proposals: <theme block from $RUNTIME_DIR/backlog.md>
- Working branch (you branch off this): $WORKING_BRANCH
- Test command: <from toolchain.md>
- Analysis command: <from toolchain.md>
- Style decisions to respect: <agent-memory/style-decisions.md>

HARD LIMITS:
- 30 minutes wall-clock for this theme. If you can't finish in 30 minutes, abandon and report.
- If a previously passing test breaks because of your changes, FIX THE TEST (or fix the code so the test passes again). Do not revert.
- If you find that the theme can't be implemented without violating a style decision or breaking something unrelated, ABANDON and report what you found.

INSTRUCTIONS:
1. Branch from $WORKING_BRANCH:
   git checkout $WORKING_BRANCH
   git checkout -b overnight/<RUN_ID>/<short-theme-slug>

2. Implement the proposals. Use Edit/Write.

3. Run tests locally. They must pass before you push.
4. Run static analysis. It must be clean.
5. If new files / changed behavior introduce code paths without tests, write tests for them.

6. Commit with a conventional-commits message: e.g.
   feat: <theme title> — addresses <proposal ids>
   refactor: <theme title>
   test: <theme title>
   chore: <theme title>

7. Push the branch.

8. Open the PR targeting $WORKING_BRANCH (NOT main):
   gh pr create --base $WORKING_BRANCH --title "<conventional-commits title>" --body <BODY>
   where <BODY> includes:
   - One-paragraph summary of what changed
   - Bullet list of the proposal IDs absorbed
   - Test plan (what you ran locally and what passed)
   - "Generated by /overnight run <RUN_ID>"

9. Return the PR number.

If you abandon, return: { "abandoned": true, "reason": "..." }
If you succeeded, return: { "pr_number": N, "branch": "...", "files_changed": N, "lines_changed": N }
```

### 6d. Wait for CI on the PR

```bash
# Poll until CI either passes or fails — up to 15 minutes
for i in $(seq 1 60); do
  sleep 15
  STATE=$(gh pr checks "$PR_NUMBER" --json state --jq '[.[].state] | unique | join(",")')
  case "$STATE" in
    "SUCCESS") echo "ci_pass"; break ;;
    *FAILURE*|*CANCELLED*|*TIMED_OUT*) echo "ci_fail"; break ;;
    *) continue ;;
  esac
done
```

If CI fails, dispatch the fixer one more time with the failure logs (`gh pr checks $PR_NUMBER --json state,name,link`, then `gh run view <run-id> --log-failed`) and ask it to push a fix. Limit: **one CI-fix attempt** per PR. If it still fails after one fix, close the PR (`gh pr close $PR_NUMBER --delete-branch`) and move on. Note in `$RUNTIME_DIR/abandoned.md`.

### 6e. Reviewer sub-agent (extra-strict for high-risk areas)

Once CI is green, dispatch the **reviewer** via Task:

```
You are the REVIEWER sub-agent for PR #<N>.

Your job: a final sanity pass before merge. CI is already green. You are the last line of defense against subtle problems CI can't catch.

CONTEXT:
- PR diff: gh pr diff <N>
- PR description: gh pr view <N>
- Theme: <theme title>

CHECK FOR:
1. Behavioral changes that aren't covered by the existing tests (especially error handling — does the new code swallow errors that used to propagate?).
2. Public API changes that aren't reflected in docs.
3. Removed code that is referenced elsewhere (CI may not catch dynamic references).
4. Configuration drift (env vars, secrets, build flags).
5. Anything that just looks wrong on a careful read.

HIGH-RISK AREAS — apply EXTRA scrutiny if the diff touches:
- Error handling (try/catch, Result types, error class definitions)
- Authentication or authorization (any file matching auth*, *token*, *session*, *credential*)
- Data persistence (database queries, migrations, file writes that update state, cache invalidation)
- Public APIs (exported symbols, route handlers, CLI flags, plugin contracts)

For high-risk diffs: if you can think of a single plausible scenario where the change breaks something subtle, REJECT.

Return one of:
- { "decision": "approve" }
- { "decision": "reject", "reasons": ["...", "..."] }
- { "decision": "request_changes", "changes": ["...", "..."] }
```

Handle the response:
- **approve** → proceed to 6f.
- **request_changes** → re-dispatch the fixer with the requested changes (one attempt only). Then re-review. If still rejected, close the PR.
- **reject** → close the PR (`gh pr close $PR_NUMBER --delete-branch`), record in `$RUNTIME_DIR/abandoned.md` with reasons, move on.

### 6f. Merge

```bash
gh pr merge "$PR_NUMBER" --squash --delete-branch
```

Then:

```bash
# Bump the counter
PR_COUNT=$(($(cat "$RUNTIME_DIR/pr_count") + 1))
echo "$PR_COUNT" > "$RUNTIME_DIR/pr_count"

# Update working branch with the merge so the next theme sees it
git checkout "$WORKING_BRANCH"
git pull --ff-only origin "$WORKING_BRANCH" 2>/dev/null || true
git fetch origin main
git merge --no-edit origin/main
git push origin "$WORKING_BRANCH"
```

### 6g. Loop

Go back to the top of Step 6 with the next theme.

## Step 7: Historian — write the morning report

Once the loop exits (deadline hit, PR cap hit, or backlog empty), dispatch the **historian** via Task:

```
You are the HISTORIAN sub-agent for /overnight run <RUN_ID>.

Your job: produce the morning report and update agent-memory/.

INPUTS:
- $RUNTIME_DIR/proposals.json (every proposal critics produced)
- $RUNTIME_DIR/backlog.md (themes that were prioritized)
- $RUNTIME_DIR/abandoned.md (PRs that were closed and why)
- gh pr list --state merged --search "head:overnight/<RUN_ID>/" — actually merged PRs from this run
- Existing agent-memory/ contents

OUTPUT 1 — write agent-memory/summaries/<YYYY-MM-DD>-night.md:

  # Overnight run <RUN_ID>
  - Wall-clock: <start> → <end> (<hours>h <minutes>m)
  - PRs merged: <N> (cap: 20)
  - PRs abandoned: <N>

  ## What changed (by theme)
  For each merged PR: theme title, one-sentence summary, PR link.

  ## What was attempted but didn't ship
  For each abandoned PR or skipped theme: what it was, why it didn't ship.

  ## Observations
  Patterns the critics surfaced that recur. Anything Tyler should know.

  ## Suggested follow-ups for human attention
  Things that need human judgment — too risky for the agent to ship alone.

OUTPUT 2 — update agent-memory/codebase-map.md:
  Append/revise based on what you learned. Keep it accurate; don't bloat it.

OUTPUT 3 — update agent-memory/style-decisions.md:
  For every consistency-critic proposal that was merged this run, record the decision.
  Format: "- <YYYY-MM-DD>: <decision>. Rationale: <one line>. PR: #<N>."
  These entries are PERMANENT.

OUTPUT 4 — update agent-memory/avoid-list.md:
  - For every abandoned PR, add: "- <YYYY-MM-DD>: <what was tried> failed because <reason>. PR: #<N>."
  - PRUNE entries dated more than 7 days ago. Remove them entirely.

OUTPUT 5 — update agent-memory/open-backlog.md:
  - Remove items that were resolved this run.
  - Add proposals that critics found but the loop didn't get to.
  - Add suggested follow-ups from the human-attention list above.

OUTPUT 6 — open one final PR titled "chore: agent-memory updates from <RUN_ID>"
  - Base: main (not the working branch — this should land directly on main)
  - Body: short summary, link to summaries/<date>-night.md
  - Wait for CI, squash-merge per Step 6 logic.
  - This counts as ONE additional PR (so the effective cap is 21 — the historian PR is always allowed even if 20 fixes already merged).
```

## Step 8: Cleanup

```bash
# Delete the working branch — all useful work has been merged to main
git checkout main
git pull --ff-only origin main
git push origin --delete "$WORKING_BRANCH" 2>/dev/null || true
git branch -D "$WORKING_BRANCH" 2>/dev/null || true

# Wipe the runtime dir
rm -rf "$RUNTIME_DIR"
```

Print a final summary to the terminal:

```
/overnight run <RUN_ID> complete.
- Duration: Xh Ym
- PRs merged: N (cap: 20)
- PRs abandoned: M
- Summary: agent-memory/summaries/<YYYY-MM-DD>-night.md
```

---

## Templates

### `agent-memory/README.md` template

Use this when bootstrapping (Step 3). Copy verbatim except for the repo name:

```markdown
# agent-memory/

Persistent state for the `/overnight` autonomous improvement skill.

This directory is **checked into git on purpose**. It accumulates the agent's understanding of the codebase across runs, lessons from past attempts, and decisions that should not be re-litigated.

## Files

- `codebase-map.md` — the agent's evolving model of the architecture. Read at the start of each run.
- `style-decisions.md` — consistency choices that have been made. **These are LAW.** The agent never reproposes anything contradicting these.
- `avoid-list.md` — refactors that were attempted and failed. Entries have a 7-day TTL — older entries are pruned by the historian.
- `open-backlog.md` — known issues found by past runs but not yet addressed. Pre-seeded into each new run as findings.
- `summaries/` — one markdown file per overnight run. Permanent record. Read the most recent few at the start of each run.

## Editing

You (Tyler) can edit any of these manually to steer the agent — for example, to add a style decision the agent should follow, or to add an item to the avoid list. The agent will read your changes on the next run.

The agent writes most of its updates via the historian role at the end of each run.

## What's NOT in here

Runtime state (the per-run backlog of proposals being deliberated, PR counters, deadlines) lives in `/tmp/overnight-<RUN_ID>/` outside the repo and is deleted at the end of each run.
```

### Initial stubs for the other files

`codebase-map.md`:
```markdown
# Codebase map

The agent's evolving understanding of this codebase's architecture. Updated by the historian after each /overnight run.

(empty — first run will populate this)
```

`style-decisions.md`:
```markdown
# Style decisions

Consistency and pattern choices the agent has standardized on. These are LAW — never re-litigate.

Format: `- <YYYY-MM-DD>: <decision>. Rationale: <one line>. PR: #<N>.`

(empty — first run will populate this)
```

`avoid-list.md`:
```markdown
# Avoid list

Things tried and failed. Entries dated within the last 7 days are active. Older entries are pruned by the historian.

Format: `- <YYYY-MM-DD>: <what was tried> failed because <reason>. PR: #<N>.`

(empty — first run will populate this)
```

`open-backlog.md`:
```markdown
# Open backlog

Known issues found by past runs but not yet addressed. Pre-seeded into each new run as critic findings.

(empty — first run will populate this)
```
