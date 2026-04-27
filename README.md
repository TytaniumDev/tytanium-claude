# TytaniumAgentSkills

Personal Claude Code and Gemini CLI plugins for PR workflows, code review, and shipping.

## Skills

| Skill | Command | Platform | Description |
|-------|---------|----------|-------------|
| **commit-push** | `/commit-push` | Claude / Gemini | Stage all changes, commit, and push to `main` |
| **ship-it** | `/ship-it [description]` | Claude / Gemini | Create a PR, request reviews, address feedback, and merge |
| **ship-no-merge** | `/ship-no-merge [description]` | Claude / Gemini | Same as `ship-it` but leaves the PR open for manual merge |
| **overnight** | `/overnight` | Claude | Long-running autonomous improvement session: parallel critic sub-agents propose fixes, deliberate, and ship as themed PRs (5-hour budget, 20-PR cap) |

## Setup on a new computer

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) OR [Gemini CLI](https://github.com/google/gemini-cli) installed and authenticated
- [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated

### Installation

#### **Claude Code**
First, add the marketplace:
```sh
claude plugin marketplace add TytaniumDev/TytaniumAgentSkills
```
Then install the plugin:
```sh
claude plugin install TytaniumAgentSkills
```

#### **Gemini CLI**
Install the extension:
```sh
gemini extensions install https://github.com/TytaniumDev/tytanium-claude
```
Verify the skills are available:
```sh
gemini skills list
```

### Uninstall

**Claude Code:** `claude plugin uninstall TytaniumAgentSkills`
**Gemini CLI:** `gemini extensions uninstall TytaniumAgentSkills`
