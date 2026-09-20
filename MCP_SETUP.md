# Built-in MCP setup

This fork enables only the `mcp_server` feature without an Enterprise token.
Other feature entitlements, subscription status, trials, banners, and user limits
retain upstream behavior. The override does not disable authentication or grant
user permissions. Administrators can still disable the server and individual
tools under **Administration → Artificial Intelligence (AI) → Model Context
Protocol (MCP)**.

The endpoint is the instance's base URL plus `/mcp`: `http://localhost:3000/mcp` for local development,
`https://<host>/mcp` for a deployed instance. The additional project, group, user, membership, role, project
configuration, and board tools in this fork use OpenProject's normal contracts and permissions.

## Authentication

Reuse a valid personal API token or create one in **My account → Access tokens**.
API token authentication must be enabled in OpenProject. The connection acts as
the token owner; it does not elevate that user's permissions.

For API tokens, send an `Authorization` header containing `Basic ` followed by
the Base64 encoding of `apikey:<API_TOKEN>`. Store the resulting header privately
in local client configuration. Base64 is reversible and must be treated as a
credential. Do not commit or print it.

Name each registration after its instance, for example `openproject-local` and `openproject-prod`. Distinct
names keep test data out of production when both are connected.

## Claude Code

Run this in the project directory. It reads the token from a hidden prompt, so the token stays out of the shell
history. Replace the name and URL for the instance you are connecting to. Then run `/mcp` in Claude Code to connect.

```sh
# zsh
read -s "T?API token: "; echo
# bash: read -s -p "API token: " T; echo
claude mcp add --transport http openproject-prod https://<host>/mcp \
  --header "Authorization: Basic $(printf 'apikey:%s' "$T" | base64)"
unset T
```

The registration is stored in `~/.claude.json` for this project directory. The equivalent entry in a project's
`.mcp.json` (ignored by Git) is:

```json
{
  "mcpServers": {
    "openproject-prod": {
      "type": "http",
      "url": "https://<host>/mcp",
      "headers": { "Authorization": "Basic YOUR_PRIVATE_BASE64_CREDENTIAL" }
    }
  }
}
```

## Codex

Use the trusted project's `.codex/config.toml` (ignored by Git):

```toml
[mcp_servers.openproject-prod]
url = "https://<host>/mcp"
startup_timeout_sec = 30
tool_timeout_sec = 120

[mcp_servers.openproject-prod.http_headers]
Authorization = "Basic YOUR_PRIVATE_BASE64_CREDENTIAL"
```

Keep token-bearing files readable only by your user (`chmod 600`). Restart or reconnect the MCP client after
changing configuration.

For ongoing agent work, use a dedicated non-admin account's token. Work package text can carry instructions, and
an administrator's token would let them reach user management.

## Verification and workflow

Call `current_user`, `search_projects`, and `list_roles`. Check that the project
setup tools are listed and enabled. Work-package tools accept API v3 payloads in
their `data` argument; updates also need the work package `id` and its current
`lockVersion`. Writes execute immediately. There is no preview step.

Configuring a project needs no browser. `list_project_types` and
`update_project_types` read and change the work package types enabled in a
project. `list_project_modules` and `update_project_modules` do the same for its
modules. `search_boards`, `create_board`, `create_board_list`, and
`update_board` manage boards and their filters; the Boards module registers
them, and they act only in a project where `board_view` is enabled. These tools
take flat arguments rather than a `data` payload.

Check the returned payload's `error` field even if the MCP envelope has
`isError: false`; permission and validation failures can use that response shape.

See the [work package skill](.claude/skills/openproject-work-packages/SKILL.md)
for team setup, task creation, and milestone scheduling. For shared clients,
configure per-user OAuth with the `mcp` scope as described in
[OpenProject's MCP documentation](https://www.openproject.org/docs/system-admin-guide/integrations/mcp-server/).
