# Built-in MCP setup

This fork enables only the `mcp_server` feature without an Enterprise token.
Other feature entitlements, subscription status, trials, banners, and user limits
retain upstream behavior. The override does not disable authentication or grant
user permissions. Administrators can still disable the server and individual
tools under **Administration → Artificial Intelligence (AI) → Model Context
Protocol (MCP)**.

Connect directly to `http://localhost:3000/mcp` for local development. A deployed
instance uses its own HTTPS URL ending in `/mcp`. No external MCP adapter is
required. Additional project, group, user, membership, and role tools are provided
separately by [PR #2](https://github.com/machinekind/openproject/pull/2). They use
OpenProject's normal contracts and permissions and are not needed to connect.

## Authentication

Reuse a valid personal API token or create one in **My account → Access tokens**.
API token authentication must be enabled in OpenProject. The connection acts as
the token owner; it does not elevate that user's permissions.

For API tokens, send an `Authorization` header containing `Basic ` followed by
the Base64 encoding of `apikey:<API_TOKEN>`. Store the resulting header privately
in local client configuration. Base64 is reversible and must be treated as a
credential. Do not commit or print it.

## Codex

Use the trusted project's `.codex/config.toml` (ignored by Git):

```toml
[mcp_servers.openproject-local]
url = "http://localhost:3000/mcp"
startup_timeout_sec = 30
tool_timeout_sec = 120

[mcp_servers.openproject-local.http_headers]
Authorization = "Basic YOUR_PRIVATE_BASE64_CREDENTIAL"
```

## Claude Code

Register this under `mcpServers` in the project's local registration in
`~/.claude.json`, or in `.mcp.json` (ignored by Git):

```json
{
  "openproject-local": {
    "type": "http",
    "url": "http://localhost:3000/mcp",
    "headers": {
      "Authorization": "Basic YOUR_PRIVATE_BASE64_CREDENTIAL"
    }
  }
}
```

Replace the previous stdio registration, preserving other client settings. Keep
token-bearing files readable only by your user (`chmod 600`). Restart or
reconnect the MCP client after changing configuration.

## Verification and workflow

Call `current_user` and `search_projects`. If PR #2 is also installed, verify
`list_roles` and check that its project setup tools are listed and enabled.
Work-package tools accept API v3 payloads in
their `data` argument; updates also need the work package `id` and its current
`lockVersion`. Writes execute immediately; the external adapter's `confirm`
argument is not part of these tools.

Check the returned payload's `error` field even if the MCP envelope has
`isError: false`; permission and validation failures can use that response shape.

See the [work package skill](.claude/skills/openproject-work-packages/SKILL.md)
for team setup, task creation, and milestone scheduling. For shared clients,
configure per-user OAuth with the `mcp` scope as described in
[OpenProject's MCP documentation](https://www.openproject.org/docs/system-admin-guide/integrations/mcp-server/).
