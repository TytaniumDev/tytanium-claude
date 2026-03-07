# tytanium-claude

Personal Claude Code plugins for PR workflows, code review, and shipping.

## Skills

| Skill | Command | Description |
|-------|---------|-------------|
| **commit-push** | `/commit-push` | Stage all changes, commit, and push to `main` |
| **ship-it** | `/ship-it [description]` | Create a PR, request code reviews from Claude/Gemini bots, address feedback, and squash-merge |
| **ship-no-merge** | `/ship-no-merge [description]` | Same as `ship-it` but leaves the PR open for manual merge |

## Setup on a new computer

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated

### Install the plugin

Run the following command to install the plugin from the marketplace:

```sh
claude plugin add TytaniumDev/tytanium-claude
```

That's it — the skills will be available in all your Claude Code sessions. You can verify by running `/help` in Claude Code to see the registered skills.

### Uninstall

```sh
claude plugin remove tytanium-claude
```
