---
name: ship-no-merge
description: Create a PR, request code reviews from Claude and Gemini, and address all review comments (no merge).
disable-model-invocation: true
argument-hint: [optional description of changes]
allowed-tools:
  - Bash(gh *)
  - Bash(git *)
  - Read
  - Grep
  - Glob
  - Edit
  - Write
---

# Ship (No Merge): PR + Review Workflow

Complete the end-of-work shipping workflow for the current branch, but leave the PR open for manual merge.

## Context

$ARGUMENTS

## Steps

### 1. Create the Pull Request

- Run `git status` and `git log main..HEAD` to understand what's being shipped
- Create a PR targeting `main` using `gh pr create`:
  - Title: follow conventional commits (`feat:`, `fix:`, `chore:`)
  - Body: include summary bullets, test plan, and the Claude Code attribution line
  - If there is a related GitHub issue, include `Closes #N` in the body
- Capture the PR number from the output

### 2. Request Code Reviews

- Comment on the PR to trigger code review bots:
  ```
  gh pr comment <number> --body "@claude do a code review"
  ```

### 3. Wait for Reviews

- Note: Gemini auto-triggers on PR creation; Claude was triggered by the comment in Step 2.
- Get the repo's owner/name: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`
- Substitute the PR number (from Step 1) for `<number>`, and split the `nameWithOwner` output on `/` to get `<owner>` and `<repo>` for all API paths below.
- Poll up to 20 times (sleep 15 seconds before each check, 5 minutes total):
  - Each cycle starts with `sleep 15`, then checks both APIs for each bot:
    - `gh api repos/<owner>/<repo>/issues/<number>/comments --jq 'any(.[]; .user.login == "claude[bot]")'`
    - `gh api repos/<owner>/<repo>/issues/<number>/comments --jq 'any(.[]; .user.login == "gemini-code-assist[bot]")'`
    - `gh api repos/<owner>/<repo>/pulls/<number>/reviews --jq 'any(.[]; .user.login == "claude[bot]")'`
    - `gh api repos/<owner>/<repo>/pulls/<number>/reviews --jq 'any(.[]; .user.login == "gemini-code-assist[bot]")'`
  - Mark `claude_done=true` if either Claude check returns `true`; `gemini_done=true` if either Gemini check returns `true`
  - If both `claude_done` and `gemini_done` are true, stop polling immediately
- If 20 cycles complete without both bots posting, note which bot(s) did not respond and proceed with whatever comments/reviews exist
- Read ALL review comments and formal reviews carefully — from both Claude and Gemini (and any human reviewers)

### 4. Address Review Comments

- For each review comment or suggestion:
  - Read the relevant code in context
  - Make the requested fix or improvement (use Edit/Write tools)
  - If a suggestion doesn't make sense or would be harmful, explain why in a reply comment using `gh pr comment`
- After all changes are made, commit with a message like `chore: address review feedback`
- Push the changes with `git push`

### 5. Verify CI and Report

- Check that CI is passing: `gh pr checks <number>`
  - If CI is failing, investigate and fix the issues, commit, and push again
- Once CI passes and review feedback is addressed, report the PR URL and note that it is ready for manual merge
- Do NOT merge the PR
