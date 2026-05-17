---
# ───────────────────────────────────────────────────────────────────────────────
# Symphony demo workflow — Jira adapter
#
# Copy this file to <repo-root>/elixir/WORKFLOW.md (or anywhere) and run:
#   ./elixir/run_dream_scene_symphony.sh  (or any launcher pointing at it)
#
# Required env vars (export in ~/.zshrc or your shell):
#   export JIRA_EMAIL="you@example.com"
#   export JIRA_API_TOKEN="ATATT3x..."           # https://id.atlassian.com/manage-profile/security/api-tokens
#   export JIRA_ENDPOINT="https://yoursite.atlassian.net"
#   export JIRA_AUTH_SCHEME="basic"              # default; use "bearer" only for OAuth tokens
#
# See lib/symphony_elixir/jira/AGENTS.md for full field documentation.
# ───────────────────────────────────────────────────────────────────────────────

tracker:
  kind: jira
  project_slug: "PROJ"            # ← your Jira project key (e.g. PROJ, MYAPP, DEV)
  endpoint: "$JIRA_ENDPOINT"      # or hardcode "https://yoursite.atlassian.net"
  email: "$JIRA_EMAIL"
  api_key: "$JIRA_API_TOKEN"
  active_states:
    - In Progress                 # tickets in these states are picked up by Symphony
  terminal_states:
    - Done                        # tickets stop being watched once they reach these

polling:
  interval_ms: 5000

workspace:
  # Each ticket gets its own subdirectory: <root>/<ISSUE-KEY>/
  root: ~/code/symphony-workspaces

hooks:
  # Runs once when the workspace is created for a ticket.
  # Use this to clone your project repo and install deps.
  after_create: |
    PROJECT_REPO="${PROJECT_REPO:-$HOME/projects/my-project}"
    ISSUE_ID="$(basename "$PWD")"
    BRANCH="codex/$(echo "$ISSUE_ID" | tr '[:upper:]' '[:lower:]')"
    git clone "$PROJECT_REPO" .
    git checkout -b "$BRANCH"

  # Runs before the workspace is deleted (i.e. after the ticket reaches a terminal state).
  # ALWAYS commit + push + backup here — uncommitted work in the workspace is lost.
  before_remove: |
    set +e  # never fail — losing code is unacceptable
    PROJECT_REPO="${PROJECT_REPO:-$HOME/projects/my-project}"
    ISSUE_ID="$(basename "$PWD")"
    BRANCH="codex/$(echo "$ISSUE_ID" | tr '[:upper:]' '[:lower:]')"
    BACKUP_DIR="$HOME/symphony-backups/$ISSUE_ID-$(date +%Y%m%d-%H%M%S)"
    # Safety net: raw copy before any git ops
    mkdir -p "$(dirname "$BACKUP_DIR")" && cp -R "$PWD" "$BACKUP_DIR"
    echo "Backup at $BACKUP_DIR"
    # Commit anything uncommitted
    git add -A
    git diff --cached --quiet || git commit -m "codex: $ISSUE_ID final state"
    # Push branch back to the project repo and merge into master
    git remote add project "$PROJECT_REPO" 2>/dev/null || git remote set-url project "$PROJECT_REPO"
    git push project "HEAD:refs/heads/$BRANCH" --force && echo "Pushed $BRANCH"
    git -C "$PROJECT_REPO" checkout master 2>/dev/null || git -C "$PROJECT_REPO" checkout -b master
    git -C "$PROJECT_REPO" merge --no-ff "$BRANCH" -m "feat: $ISSUE_ID" && echo "Merged $BRANCH into master"
    exit 0

agent:
  max_concurrent_agents: 1
  max_turns: 20

codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite

server:
  port: 4050
---

You are working on Jira issue `{{ issue.identifier }}`.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Execution posture:
- Work autonomously in this issue's provided workspace.
- Keep the Jira issue current with a single `## Codex Workpad` comment summarising progress.
- If the issue is not actionable, document the blocker in the workpad and stop.
- Preserve the ticket's scope. Do not independently redesign the product.
- Run targeted validation before handoff.
- **Commit your work to git before finishing.** Run `git add -A && git commit -m "codex: done"` as your final step. The workspace is deleted after you finish — uncommitted work is permanently lost. The before_remove hook will merge your branch into master automatically.

Status handling:
- `To Do`: not watched by this workflow. A human moves a ticket to `In Progress` to run it.
- `In Progress`: execute the ticket.
- `Done`: terminal; no further work.

Quality bar:
- Test your changes before claiming completion.
- Keep changes scoped to the ticket.
- Leave the workpad comment clean and informative.
