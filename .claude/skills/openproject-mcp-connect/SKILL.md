---
name: openproject-mcp-connect
description: Connect Codex, Claude Code or another MCP client to this fork's built-in OpenProject MCP endpoint and verify project, group, membership and task tools. Use when openproject-local tools are missing or failing, the user asks to connect OpenProject or set up MCP, or the connection returns 401 or 404.
---

# Connect the built-in OpenProject MCP server

Use the HTTP endpoint `http://localhost:3000/mcp`, registered as
`openproject-local`. This fork enables only the MCP entitlement without an
Enterprise token. Other Enterprise features, authentication, user permissions,
and the administrator's server/tool switches retain their normal behavior.

## Workflow

1. If `mcp__openproject-local__current_user` is available, call it. A returned
   user confirms the connection; continue the original task.
2. Read [MCP setup](../../../MCP_SETUP.md) for Codex and Claude configuration.
   Replace a previous `openproject-ce-mcp` stdio registration with the built-in
   HTTP endpoint, preserving other settings.
3. Reuse an existing valid API token privately when authorized. API tokens use
   Basic authentication with username `apikey` and the token as password. Keep
   the resulting Authorization header in private local configuration, never
   logs, chat, command arguments, or committed files.
4. If no valid token exists, direct the user to **My account → Access tokens**
   and have it stored in private configuration. Do not ask for a token in chat.
5. Reconnect or restart the MCP client after changing configuration. Verify
   `current_user` and `search_projects`. If the separate project setup tools from
   [PR #2](https://github.com/machinekind/openproject/pull/2) are installed, also
   verify `list_roles`, `create_project`, `create_group`, `create_user`, and
   `create_membership` are listed when needed.
6. Return to the original task, using `openproject-work-packages` for its workflow.

For shared clients, use per-user OAuth with the `mcp` scope, as documented in
[OpenProject's MCP guide](https://www.openproject.org/docs/system-admin-guide/integrations/mcp-server/).

## Troubleshooting

| Symptom | Action |
|---|---|
| Connection refused | Start the local OpenProject app and check the URL. |
| HTTP 401 | Check the private API credential and whether API tokens are enabled. For OAuth, verify the `mcp` scope. |
| HTTP 404, MCP server is not available | Check **Administration → AI → Model Context Protocol → Enabled**. This fork does not require an Enterprise token for MCP. |
| Project setup tools missing | Check the running branch contains the tools and their configuration rows exist and are enabled. The MCP configuration seeder can initialize missing rows. |
| Tool disabled | Check the tool's MCP administration setting; preserve intentional restrictions. |
| Permission error | The API user needs the normal OpenProject permission. Group/user creation normally needs administrative permissions. |
| Unknown `confirm` or Community adapter argument | Inspect the built-in tool schema. Create/update tools take API payloads under `data`; writes execute immediately. |

Do not change unrelated Enterprise entitlements when fixing this connection.
