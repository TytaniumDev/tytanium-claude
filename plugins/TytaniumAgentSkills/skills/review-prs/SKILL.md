---
name: review-prs
description: Review all open PRs in the current repo, triage for quality, fix issues, and merge them sequentially.
disable-model-invocation: true
allowed-tools:
  - Bash(gh *)
  - Bash(git *)
  - Read
  - Grep
  - Glob
  - Edit
  - Write
---

# Review PRs: Triage, Fix, and Merge

Review every open non-draft PR in the current repo. For each PR: rebase onto the base branch, run quality checks, fix CI/review issues, and merge if worthy. PRs are processed **sequentially** — after merging one, rebase the next onto the updated base before proceeding. Present a summary at the end.

## Step 1: List Open PRs

Run:
```
gh pr list --state open --draft=false --json number,title,headRefName,baseRefName,url --limit 100
```

If no PRs are returned, report "No open non-draft PRs found" and stop.

Save the list. You will need `number`, `title`, `headRefName`, `baseRefName`, and `url` for each PR.

## Step 2: Get Repo Info

Run:
```
gh repo view --json nameWithOwner --jq '.nameWithOwner'
```

Split on `/` to get `OWNER` and `REPO`. You will need these for API calls.

## Step 3: Triage All PRs in Parallel

For EVERY PR from Step 1, dispatch a parallel haiku subagent using the Agent tool with `model: "haiku"`. Send ALL Agent tool calls in a single message so they run concurrently.

Each subagent receives the PR number, title, branch name, base branch name, URL, OWNER, REPO, and the full instructions from the "Triage Subagent Instructions" section below.

Each subagent returns a structured report:
- `pr_number`, `pr_title`, `pr_url`, `base_branch`
- `verdict`: one of `worthy`, `not_worthy`
- `reason`: short explanation

After all triage subagents complete, split the results into two lists: **worthy PRs** and **not-worthy PRs**.

## Step 4: Merge Worthy PRs Sequentially

Process the worthy PRs **one at a time, in order** (lowest PR number first). For each PR:

### 4a. Rebase onto Latest Base Branch

The base branch may have changed since triage (due to earlier PRs merging). Fetch and rebase:

```
git fetch origin <BASE_BRANCH>
```

Dispatch a subagent with `model: "haiku"` and `isolation: "worktree"` with the instructions from the "Rebase Subagent Instructions" section below. This subagent will check out the branch, rebase, and push.

If the rebase subagent reports merge conflicts, dispatch a **sonnet subagent** with `model: "sonnet"` using the "Conflict Resolution Subagent Instructions" section below.

If conflicts are unresolvable, comment on the PR and add it to the "Needs Human Attention" list. Move to the next PR.

### 4b. Wait for CI

After the rebase push, wait for CI to run:

```
sleep 30
```

Then poll CI status up to 20 times (sleep 15s each):
```
gh pr checks <NUMBER>
```

Stop polling when all checks complete (pass or fail).

### 4c. Fix CI Failures / Review Comments (if needed)

Check CI status and review state:
```
gh pr checks <NUMBER>
gh api repos/<OWNER>/<REPO>/pulls/<NUMBER>/reviews --jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length'
```

If CI is green and no `CHANGES_REQUESTED` reviews, skip to 4d.

If there are issues, dispatch a **sonnet subagent** with `model: "sonnet"` and `isolation: "worktree"` with the instructions from the "Fix Subagent Instructions" section below. Up to 5 fix-push cycles.

If still failing after 5 cycles, comment on the PR and add it to the "Needs Human Attention" list. Move to the next PR.

### 4d. Merge

Once CI is green and no blocking reviews:

```
gh pr merge <NUMBER> --squash --delete-branch
```

If merge fails (e.g., new conflicts from a race condition), retry the rebase-CI-merge cycle once. If it fails again, add to "Needs Human Attention" and move on.

Record the PR as "Merged" with a short reason.

## Step 5: Present Summary

After processing all PRs, present a summary:

```
## PR Review Summary -- <OWNER>/<REPO>

### Merged (N)
- #<number> -- "<title>" -- <reason> -- <url>

### Not Worthy (N)
- #<number> -- "<title>" -- <reason> -- <url>

### Needs Human Attention (N)
- #<number> -- "<title>" -- <reason> -- <url>
```

If a section has 0 items, omit it.

---

## Triage Subagent Instructions

**IMPORTANT:** Copy this entire section into the prompt for each triage subagent, substituting the PR-specific values.

You are triaging PR #<NUMBER> ("<TITLE>") on branch `<BRANCH>` targeting `<BASE_BRANCH>` in <OWNER>/<REPO>.
URL: <URL>

Your job: evaluate whether this PR is worthy of merging. You are NOT merging it — just evaluating. Return a structured verdict.

### Check 1: Code Review Quality

Read the full PR diff:
```
gh pr diff <NUMBER>
```

Evaluate holistically: Do the changes make sense? Is the code correct, reasonably clean, and not introducing obvious bugs or security issues? Would a competent reviewer approve this?

### Check 2: No Duplication of Existing Functionality

Look at what the PR adds (new functions, components, utilities, etc). For each significant addition, search the existing codebase using Grep and Glob to check if similar functionality already exists. Flag if the PR reimplements something that's already there.

### Check 3: No CI Naming Changes

First check if any workflow files are changed:
```
gh pr diff <NUMBER> --name-only | grep '.github/workflows/' || true
```

If workflow files are changed, check specifically for modifications to `name:` fields on jobs or workflows. Renaming CI jobs or workflows is an automatic rejection — it breaks existing automations. Adding new workflows or changing non-name fields is fine.

### Return Result

If ALL checks pass:
- Return: `{ verdict: "worthy", reason: "<brief positive summary>" }`

If ANY check fails:
- Post a review comment explaining which check(s) failed and why:
  ```
  gh pr comment <NUMBER> --body "<explanation of which checks failed and why>"
  ```
- Return: `{ verdict: "not_worthy", reason: "<brief summary of failures>" }`

---

## Rebase Subagent Instructions

You are rebasing PR #<NUMBER> branch `<BRANCH>` onto `origin/<BASE_BRANCH>` in <OWNER>/<REPO>.

1. Check out the PR branch:
   ```
   git checkout <BRANCH>
   ```

2. Fetch latest base branch:
   ```
   git fetch origin <BASE_BRANCH>
   ```

3. Attempt rebase:
   ```
   git rebase origin/<BASE_BRANCH>
   ```

4. If rebase succeeds with no conflicts, force-push:
   ```
   git push --force-with-lease
   ```
   Report: `{ result: "rebased" }`

5. If rebase fails due to merge conflicts:
   ```
   git rebase --abort
   ```
   Report: `{ result: "conflicts" }`

---

## Conflict Resolution Subagent Instructions

You are in a worktree on branch `<BRANCH>` for PR #<NUMBER> in <OWNER>/<REPO>.
A rebase onto `origin/<BASE_BRANCH>` failed with merge conflicts. Resolve them:

1. Make sure rebase is aborted:
   ```
   git rebase --abort 2>/dev/null; true
   ```
2. Merge the base branch instead:
   ```
   git merge origin/<BASE_BRANCH>
   ```
3. For each conflicted file, read the file, understand both sides, and resolve the conflict sensibly
4. After resolving all conflicts:
   ```
   git add <resolved files>
   git commit -m "chore: merge <BASE_BRANCH> into <BRANCH>"
   git push --force-with-lease
   ```

Report `{ result: "conflicts_resolved" }` if successful, or `{ result: "conflicts_unresolvable", reason: "<explanation>" }` if not.

---

## Fix Subagent Instructions

You are in a worktree on branch `<BRANCH>` for PR #<NUMBER> in <OWNER>/<REPO>.
Fix CI failures and/or review comments on this PR. You have up to 5 fix-push cycles.

For each cycle:
1. Read CI failure logs: `gh run list --branch <BRANCH> --limit 1 --json databaseId --jq '.[0].databaseId'` then `gh run view <RUN_ID> --log-failed`
2. Read unresolved review comments: `gh api repos/<OWNER>/<REPO>/pulls/<NUMBER>/comments`
3. Fix the issues in the code using Read/Edit/Write tools
4. Commit and push:
   ```
   git add <files you modified>
   git commit -m "fix: address CI failures and review feedback"
   git push
   ```
   Stage only the files you modified. Do NOT use `git add -A` or `git add .` — this skill runs across arbitrary repos and could accidentally stage sensitive files.
5. Wait 30 seconds for CI to start, then poll CI status up to 20 times (sleep 15s each):
   ```
   gh pr checks <NUMBER>
   ```
   Stop polling when all checks complete (pass or fail).
6. If CI passes and no more unresolved comments, report `{ result: "fixed" }` and stop.
7. If CI still fails, start the next cycle.

After 5 failed cycles, report `{ result: "unfixed", reason: "<summary of what was tried and what's still broken>" }`.
