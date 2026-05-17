---
tracker:
  kind: jira
  project_slug: "DS"
  endpoint: "$JIRA_ENDPOINT"
  email: "$JIRA_EMAIL"
  api_key: "$JIRA_API_TOKEN"
  active_states:
    - In Progress
  terminal_states:
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces-dream-scene
hooks:
  after_create: |
    DREAM_SCENE_REPO="${DREAM_SCENE_REPO:-$HOME/atlassian/dream-scene}"
    # Derive issue identifier from workspace dir name (e.g. DS-2)
    ISSUE_ID="$(basename "$PWD")"
    BRANCH="codex/$(echo "$ISSUE_ID" | tr '[:upper:]' '[:lower:]')"
    # Ensure dream-scene repo has at least one commit before cloning
    if [ -z "$(git -C "$DREAM_SCENE_REPO" log --oneline -1 2>/dev/null)" ]; then
      git -C "$DREAM_SCENE_REPO" commit --allow-empty -m "chore: init dream-scene repo"
    fi
    git clone "$DREAM_SCENE_REPO" .
    git checkout -b "$BRANCH"
  before_remove: |
    set +e  # never fail — losing code is unacceptable, log errors instead
    DREAM_SCENE_REPO="${DREAM_SCENE_REPO:-$HOME/atlassian/dream-scene}"
    ISSUE_ID="$(basename "$PWD")"
    BRANCH="codex/$(echo "$ISSUE_ID" | tr '[:upper:]' '[:lower:]')"
    BACKUP_DIR="$HOME/atlassian/dream-scene-backups/$ISSUE_ID-$(date +%Y%m%d-%H%M%S)"
    # SAFETY NET: always tar+copy workspace to backup dir first
    mkdir -p "$(dirname "$BACKUP_DIR")"
    cp -R "$PWD" "$BACKUP_DIR"
    echo "Safety backup at $BACKUP_DIR"
    # Commit everything uncommitted
    git add -A
    git diff --cached --quiet || git commit -m "codex: $ISSUE_ID final state"
    # Push branch to dream-scene repo
    git remote add dream-scene "$DREAM_SCENE_REPO" 2>/dev/null || git remote set-url dream-scene "$DREAM_SCENE_REPO"
    git push dream-scene "HEAD:refs/heads/$BRANCH" --force && echo "Pushed $BRANCH"
    # Merge branch into master in dream-scene repo
    git -C "$DREAM_SCENE_REPO" checkout master 2>/dev/null || git -C "$DREAM_SCENE_REPO" checkout -b master
    git -C "$DREAM_SCENE_REPO" merge --no-ff "$BRANCH" -m "feat: $ISSUE_ID" && echo "Merged $BRANCH into master at $DREAM_SCENE_REPO"
    exit 0
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
server:
  port: 4050
---

You are working on Jira issue `{{ issue.identifier }}` for the Dream Scene Builder MVP.

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

Project source of truth:
- Jira board: https://plai2.atlassian.net/jira/software/projects/DS/boards/83
- Confluence space: https://plai2.atlassian.net/wiki/spaces/DSB/overview

Core product constraints:
- The app itself is not runtime AI-powered.
- Do not use ComfyUI or generated bitmap assets for the MVP.
- Use code-native visuals: SVG, CSS, gradients, masks, filters, shadows, particles, and subtle animation.
- Build one excellent hardcoded rainy cyberpunk plant shop scene before procedural generation.
- Verify visual quality in browser screenshots before moving on.

Execution posture:
- Work autonomously in this issue's provided workspace.
- Keep the Jira issue current with a single `## Codex Workpad` comment.
- If the issue is not actionable, document the blocker in the workpad and stop.
- Preserve the ticket's scope. Do not independently redesign the product.
- Run targeted validation before handoff.
- **Commit your work to git before finishing.** Run `git add -A && git commit -m "codex: done"` as your final step. The workspace is deleted after you finish — uncommitted work is permanently lost. The before_remove hook will merge your branch into master of the dream-scene repo automatically.

Status handling:
- `To Do`: not watched by this Symphony workflow. A human should move exactly one ticket to `In Progress` when ready to run it.
- `In Progress`: execute the ticket.
- `Done`: terminal; no further work.

Quality bar:
- Do not claim visual work is complete without browser verification.
- Reject flat clipart, random SVG shapes, loud colors, empty scenes, or UI that competes with the scene.
- Default scene must read as a rainy plant shop without explanatory text.
