# Community MCP setup

Groups, project memberships, and work packages use OpenProject's Community
features. This fork keeps the upstream Enterprise token checks, including the
check on the built-in `/mcp` endpoint.

AI clients can use the independent, MIT-licensed
[openproject-ce-mcp](https://github.com/jtauschl/openproject-ce-mcp) server. It runs
locally over stdio and calls OpenProject's public API v3 with a personal API token.
It does not require the built-in MCP server or an Enterprise token. The API user's
permissions still apply to every request. The extra Rails MCP tools in this fork
remain available through the built-in server when licensed; this integration does
not depend on them.

## Install and authenticate

Install the version verified against this checkout (Python 3.11 or newer):

```sh
uv tool install --python python3.11 'openproject-ce-mcp==0.4.0'
```

Create an API token in **My account → Access tokens**, or reuse an existing local
API token. Keep the token in private client configuration; never commit it. Use
`http://localhost:3000` for this development instance, without `/mcp` or `/api/v3`.
For a remote instance, use its HTTPS base URL.

The examples below use placeholders. Set `command` to the absolute installed
executable path if the GUI client's `PATH` does not include it.

## Codex

Add this to the trusted project's `.codex/config.toml` (ignored by Git):

```toml
[mcp_servers.openproject-local]
command = "/absolute/path/to/openproject-ce-mcp"
startup_timeout_sec = 30
tool_timeout_sec = 120

[mcp_servers.openproject-local.env]
OPENPROJECT_BASE_URL = "http://localhost:3000"
OPENPROJECT_API_TOKEN = "YOUR_PRIVATE_API_TOKEN"
OPENPROJECT_READ_PROJECTS = "*"
OPENPROJECT_WRITE_PROJECTS = "*"
OPENPROJECT_ENABLE_ADMIN_READ = "true"
OPENPROJECT_ENABLE_ADMIN_WRITE = "true"
```

See [Codex MCP configuration](https://developers.openai.com/codex/mcp/).

## Claude Code

Use the same server name, `openproject-local`, in the project's `.mcp.json`
(ignored by Git), or its existing local registration in `~/.claude.json`:

```json
{
  "mcpServers": {
    "openproject-local": {
      "type": "stdio",
      "command": "/absolute/path/to/openproject-ce-mcp",
      "args": [],
      "env": {
        "OPENPROJECT_BASE_URL": "http://localhost:3000",
        "OPENPROJECT_API_TOKEN": "YOUR_PRIVATE_API_TOKEN",
        "OPENPROJECT_READ_PROJECTS": "*",
        "OPENPROJECT_WRITE_PROJECTS": "*",
        "OPENPROJECT_ENABLE_ADMIN_READ": "true",
        "OPENPROJECT_ENABLE_ADMIN_WRITE": "true"
      }
    }
  }
}
```

Replace the previous HTTP registration pointing to `/mcp`; avoid leaving two
registrations with the same name. Preserve other servers and client settings.
Keep files containing tokens readable only by your user (`chmod 600`). Restart or
reconnect the client after changing its MCP configuration.

## Access and verification

`*` permits access to all projects visible to the API user. To restrict the
integration, replace it with comma-separated project identifiers or numeric IDs.
Write access must also be included in the read list. Empty lists deny project
access. Group and user administration is instance-wide and requires the admin
read/write toggles plus permission in OpenProject; project lists do not restrict
those operations.

Verify with `get_current_user`, `list_projects`, `list_groups`,
`list_project_memberships`, and `list_work_packages`. Follow `next_offset` to
retrieve additional pages. The tools use typed arguments, not the built-in
server's `data` wrapper:

```json
{"project": "wojtek", "type": "Task", "subject": "Review the leg design"}
```

Writes default to a preview. Inspect `ready`, `validation_errors`, and the resolved
payload, then repeat with `confirm: true` for an authorized change. A successful
preview has not created anything. Existing user authorization can cover that
second call; the protocol flag does not itself require another user prompt.

Use the [work package skill](.claude/skills/openproject-work-packages/SKILL.md)
for the project/team/task workflow and tool limitations. The external server's
tools can change between versions, so review its schema before upgrading.
