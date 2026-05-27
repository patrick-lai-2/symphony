# Jira Adapter

Implements the `SymphonyElixir.Tracker` behaviour against the Jira Cloud REST API v3.

## Files

- `adapter.ex` — thin behaviour wrapper; delegates every call to `client.ex`
- `client.ex` — all HTTP logic: search, transition, comment, pagination
- `WORKFLOW.demo.md` — **start here** — a copy-pasteable WORKFLOW.md with all credentials/URLs templated

---

## Configuring the Tracker

Set these fields in the `tracker:` section of your WORKFLOW.md frontmatter:

```yaml
tracker:
  kind: jira
  endpoint: "https://yoursite.atlassian.net"   # required
  email: "you@example.com"                      # required — used for basic auth
  api_key: "ATATT3x..."                         # required — Atlassian API token
  project_slug: "MYPROJECT"                     # required — Jira project key (e.g. DS, JPO)
  active_states:
    - In Progress                               # Symphony watches issues in these states
  terminal_states:
    - Done                                      # Symphony stops watching when issue reaches these
```

### Using environment variables instead of inline values

Any field value starting with `$` is expanded from the environment at startup:

```yaml
tracker:
  kind: jira
  endpoint: "$JIRA_ENDPOINT"
  email: "$JIRA_EMAIL"
  api_key: "$JIRA_API_TOKEN"
  project_slug: "DS"
```

### Automatic env fallbacks (no WORKFLOW.md config needed)

If a field is omitted or left as `$VAR` with no match, the config layer falls back to these env vars automatically:

| Field      | Env vars checked (in order)                        |
|------------|----------------------------------------------------|
| `endpoint` | `JIRA_ENDPOINT`                                    |
| `api_key`  | `JIRA_API_TOKEN`, then `ATLASSIAN_API_TOKEN`       |
| `email`    | `JIRA_EMAIL`, then `ATLASSIAN_EMAIL`               |

So the minimal WORKFLOW.md for a machine that already exports those vars is just:

```yaml
tracker:
  kind: jira
  project_slug: "DS"
  active_states:
    - In Progress
  terminal_states:
    - Done
```

---

## Authentication schemes

The client reads `JIRA_AUTH_SCHEME` at runtime (not from WORKFLOW.md):

| `JIRA_AUTH_SCHEME` | Auth header sent             | When to use                                      |
|--------------------|------------------------------|--------------------------------------------------|
| `basic` (default)  | `Basic base64(email:token)`  | Standard Atlassian API token + email             |
| `bearer`           | `Bearer <token>`             | OAuth2 access tokens (e.g. TWG/cloud API tokens) |

For most users: leave this unset. Basic auth with a classic Atlassian API token is the reliable path.

> **Gotcha**: TWG CLI tokens (`~/.config/twg/auth.conf`) are OAuth tokens scoped for Bitbucket/TWG,
> not Jira. They will authenticate (no 401) but return empty search results because they lack
> `read:jira-work` scope. Always use a dedicated Atlassian API token from
> https://id.atlassian.com/manage-profile/security/api-tokens.

---

## How the client works

### Issue search

Builds a JQL query from `tracker.project_slug` and the requested states:

```
project = "DS" AND status IN ("In Progress") ORDER BY created ASC
```

Paginates via `nextPageToken` until all results are collected.

### State transitions

Calls `GET /rest/api/3/issue/{key}/transitions` to find the transition ID matching the target
state name (case-insensitive), then `POST /rest/api/3/issue/{key}/transitions` to apply it.

### Comments

Posts Atlassian Document Format (ADF) JSON to `POST /rest/api/3/issue/{key}/comment`.
Plain text bodies are wrapped in an ADF paragraph node automatically.

---

## Common errors

| Error atom                  | Meaning                                              | Fix                                              |
|-----------------------------|------------------------------------------------------|--------------------------------------------------|
| `:missing_jira_api_token`   | `api_key` resolved to nil                            | Export `JIRA_API_TOKEN` or set in WORKFLOW.md    |
| `:missing_jira_email`       | `email` resolved to nil                              | Export `JIRA_EMAIL` or set in WORKFLOW.md        |
| `:missing_jira_endpoint`    | `endpoint` resolved to nil                           | Export `JIRA_ENDPOINT` or set in WORKFLOW.md     |
| `{:jira_api_status, 401}`   | Wrong token or wrong auth scheme                     | Check token type; ensure `JIRA_AUTH_SCHEME=basic`|
| `{:jira_api_status, 404}`   | Issue key or project not found                       | Check `project_slug` matches the Jira project key|
| `{:transition_not_available, name, available}` | Target state not a valid transition | Check Jira workflow; `available` lists valid ones|
| Empty results with 200      | Token lacks Jira scopes (OAuth token misuse)         | Use a classic API token, not a TWG/OAuth token   |
