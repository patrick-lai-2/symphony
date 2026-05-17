#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

WORKFLOW_PATH="$PWD/WORKFLOW_DREAM_SCENE.md"
LOGS_ROOT="$PWD/log-dream-scene"
PORT="${SYMPHONY_PORT:-4050}"
EXPLICIT_JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"
TWG_USER=""
TWG_TOKEN=""
TWG_CLOUD_ID=""
TWG_AUTH_METHOD=""

if [[ -f "$HOME/.config/twg/auth.conf" ]]; then
  while IFS='=' read -r key value; do
    [[ -z "${key:-}" || "${key:0:1}" == "#" ]] && continue
    case "$key" in
      user) TWG_USER="$value" ;;
      token) TWG_TOKEN="$value" ;;
      cloud-id) TWG_CLOUD_ID="$value" ;;
      auth-method) TWG_AUTH_METHOD="$value" ;;
    esac
  done < "$HOME/.config/twg/auth.conf"
fi

export JIRA_EMAIL="${JIRA_EMAIL:-${ROVODEV_JIRA_EMAIL:-$TWG_USER}}"
# Prefer an explicit Jira API token; fall back to the generic Atlassian API token; then TWG token
export JIRA_API_TOKEN="${JIRA_API_TOKEN:-${ATLASSIAN_API_TOKEN:-$TWG_TOKEN}}"

if [[ -z "${JIRA_ENDPOINT:-}" ]]; then
  if [[ -z "$EXPLICIT_JIRA_API_TOKEN" && -n "$TWG_CLOUD_ID" && -n "$TWG_TOKEN" && "${TWG_AUTH_METHOD:-}" != "api-token" && "${TWG_AUTH_METHOD:-}" != "classic" ]]; then
    export JIRA_AUTH_SCHEME="${JIRA_AUTH_SCHEME:-bearer}"
    export JIRA_ENDPOINT="https://api.atlassian.com/ex/jira/$TWG_CLOUD_ID"
  else
    # classic / api-token auth-methods use a standard Atlassian API token with basic auth
    _jira_domain="$(grep '^domain=' ~/.config/twg/auth.conf 2>/dev/null | cut -d= -f2 || true)"
    export JIRA_AUTH_SCHEME="${JIRA_AUTH_SCHEME:-basic}"
    export JIRA_ENDPOINT="https://${_jira_domain:-plai2.atlassian.net}"
  fi
fi

if [[ -z "${JIRA_EMAIL:-}" ]]; then
  echo "Missing JIRA_EMAIL. Export it or run twg login first." >&2
  exit 1
fi

if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
  echo "Missing JIRA_API_TOKEN. Export it or run twg login first." >&2
  exit 1
fi

export SYMPHONY_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DREAM_SCENE_REPO="${DREAM_SCENE_REPO:-$HOME/atlassian/dream-scene}"

echo "Starting Symphony Dream Scene workflow"
echo "  workflow: $WORKFLOW_PATH"
echo "  logs:     $LOGS_ROOT/log/symphony.log"
echo "  port:     $PORT"
echo "  Jira:     $JIRA_ENDPOINT project DS status 'In Progress' auth ${JIRA_AUTH_SCHEME:-basic}"

if command -v lsof >/dev/null 2>&1; then
  port_owner="$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN || true)"
  if [[ -n "$port_owner" ]]; then
    echo "Port $PORT is already in use. Stop the existing process before launching:" >&2
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2 || true
    exit 1
  fi
fi

echo "  Jira connectivity: skipped (Symphony will watch for In Progress tickets automatically)"

mise exec -- mix build
exec mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$LOGS_ROOT" \
  --port "$PORT" \
  "$WORKFLOW_PATH"
