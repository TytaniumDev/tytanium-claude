---
name: review-prs
description: Review all open PRs in the current repo, triage for quality, close unworthy ones, fix issues, and merge worthy ones sequentially. Use this when the user wants to review all open PRs.
---

# Review PRs: Triage, Fix, Close, and Merge

Review every open non-draft PR in the current repo. For each PR: rebase onto the base branch, run quality checks, fix CI/review issues, and merge if worthy — or **close** it if not. PRs are merged **sequentially** — after merging one, rebase the next onto the updated base before proceeding. Present a summary at the end.

## Step 1: List Open PRs

Run:
```bash
gh pr list --state open --draft=false --json number,title,headRefName,baseRefName,url --limit 100
```

If no PRs are returned, report "No open non-draft PRs found" and stop.

Save the list. You will need `number`, `title`, `headRefName`, `baseRefName`, and `url` for each PR.

## Step 2: Get Repo Info

Run:
```bash
gh repo view --json nameWithOwner --jq '.nameWithOwner'
```

Split on `/` to get `OWNER` and `REPO`. You will need these for API calls.

## Step 3: Triage All PRs

For EVERY PR from Step 1, evaluate whether it is worthy of merging. You can process these evaluations one at a time.

For each PR, follow the "Triage Instructions" section below and record:
- `pr_number`, `pr_title`, `pr_url`, `base_branch`
- `verdict`: one of `worthy`, `closed`
- `reason`: short explanation

Not-worthy PRs are **closed** during triage (after posting an explanatory comment).

After all triage completes, split the results into two lists: **worthy PRs** and **closed PRs**.

## Step 4: Merge Worthy PRs Sequentially

Process the worthy PRs **one at a time, in order** (lowest PR number first). For each PR:

### 4a. Rebase onto Latest Base Branch

The base branch may have changed since triage (due to earlier PRs merging). Fetch and rebase:

1. Check out the PR branch:
   ```bash
   git checkout <BRANCH>
   ```
2. Fetch latest base branch:
   ```bash
   git fetch origin <BASE_BRANCH>
   ```
3. Attempt rebase:
   ```bash
   git rebase origin/<BASE_BRANCH>
   ```
4. If rebase succeeds, force-push:
   ```bash
   git push --force-with-lease
   ```
5. If rebase fails due to merge conflicts:
   1. Run `git rebase --abort` to reset
   2. Run `git merge origin/<BASE_BRANCH>` instead
   3. For each conflicted file, use `view_file` to read the file, understand both sides, and resolve the conflict sensibly using `replace_file_content` or `write_to_file`
   4. After resolving all conflicts, run `git add <resolved files>` and `git commit -m "chore: merge <BASE_BRANCH> into <BRANCH>"`
   5. Run `git push --force-with-lease`

   If conflicts cannot be resolved:
   - Comment on the PR: `gh pr comment <NUMBER> --body "Unable to automatically resolve merge conflicts with <BASE_BRANCH>. Manual resolution needed."`
   - Record as "Needs Human Attention" and move to the next PR.

### 4b. Wait for CI

After pushing, wait for CI:
```bash
sleep 30
```

Then poll CI status up to 20 times (sleep 15s each):
```bash
gh pr checks <NUMBER>
```

Stop polling when all checks complete (pass or fail).

### 4c. Fix CI Failures / Review Comments (if needed)

Check CI status and review state:
```bash
gh pr checks <NUMBER>
gh api repos/<OWNER>/<REPO>/pulls/<NUMBER>/reviews --jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length'
```

If CI is green and no `CHANGES_REQUESTED` reviews, skip to 4d.

If there are issues, work through up to 5 fix-push cycles:

For each cycle:
1. Read CI failure logs: `gh run list --branch <BRANCH> --limit 1 --json databaseId --jq '.[0].databaseId'` then `gh run view <RUN_ID> --log-failed`
2. Read unresolved review comments: `gh api repos/<OWNER>/<REPO>/pulls/<NUMBER>/comments`
3. Fix the issues using `view_file`, `replace_file_content`, and `write_to_file`
4. Commit and push:
   ```bash
   git add <files you modified>
   git commit -m "fix: address CI failures and review feedback"
   git push
   ```
   Stage only the files you modified. Do NOT use `git add -A` or `git add .`.
5. Wait 30 seconds, then poll CI up to 20 times (sleep 15s each):
   ```bash
   gh pr checks <NUMBER>
   ```
6. If CI passes and no more unresolved comments, proceed to 4d.
7. If CI still fails, start the next cycle.

After 5 failed cycles:
- Comment on the PR with a summary of what was tried
- Record as "Needs Human Attention" and move to the next PR.

### 4d. Merge

Once CI is green and no blocking reviews:
```bash
gh pr merge <NUMBER> --squash --delete-branch
```

If merge fails (e.g., new conflicts from a race condition), retry the rebase-CI-merge cycle once. If it fails again, record as "Needs Human Attention" and move on.

Record the PR as "Merged" with a short reason.

## Step 5: Present Summary

After processing all PRs:

```
## PR Review Summary -- <OWNER>/<REPO>

### Merged (N)
- #<number> -- "<title>" -- <reason> -- <url>

### Closed (N)
- #<number> -- "<title>" -- <reason> -- <url>

### Needs Human Attention (N)
- #<number> -- "<title>" -- <reason> -- <url>
```

If a section has 0 items, omit it.

---

## Triage Instructions

You are triaging PR #<NUMBER> ("<TITLE>") on branch `<BRANCH>` targeting `<BASE_BRANCH>` in <OWNER>/<REPO>.
URL: <URL>

Evaluate whether this PR is worthy of merging. You are NOT merging it — just evaluating.

### Check 1: Code Review Quality

Read the full PR diff:
```bash
gh pr diff <NUMBER>
```

Evaluate holistically: Do the changes make sense? Is the code correct, reasonably clean, and not introducing obvious bugs or security issues?

### Check 2: No Duplication of Existing Functionality

Look at what the PR adds. For each significant addition, search the existing codebase using `grep_search` to check if similar functionality already exists.

### Check 3: No CI Naming Changes

Check if any workflow files are changed:
```bash
gh pr diff <NUMBER> --name-only | grep '.github/workflows/' || true
```

If workflow files are changed, check for `name:` field modifications. Renaming CI jobs or workflows is an automatic rejection. Adding new workflows or changing non-name fields is fine.

### Return Result

If ALL checks pass: record as `worthy` with a brief positive summary.

If ANY check fails:
- Post a comment explaining which check(s) failed:
  ```bash
  gh pr comment <NUMBER> --body "<explanation>"
  ```
- Close the PR:
  ```bash
  gh pr close <NUMBER> --comment "Closing after automated review. See prior comment for details."
  ```
- Record as `closed` with a brief summary of failures.
