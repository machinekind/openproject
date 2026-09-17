---
name: openproject-mcp-connect
description: Connect Claude Code, Codex or another local MCP client to OpenProject Community through the independent openproject-ce-mcp API v3 adapter. Use when openproject-local tools are missing or failing, the user asks to connect OpenProject or set up MCP, or an old /mcp connection returns 401 or 404. Also use before openproject-work-packages when its MCP tools are unavailable.
---

# Connect OpenProject Community MCP

Register `openproject-ce-mcp==0.4.0` as a local stdio server named
`openproject-local`. It calls the public REST API at the configured base URL,
`http://localhost:3000` for this development instance. Groups, memberships,
projects and work packages do not need an Enterprise unlock. Preserve upstream
Enterprise checks, including the check on the built-in `/mcp` endpoint.

## Steps

1. If `mcp__openproject-local__get_current_user` is available, call it. A returned
   user confirms the connection; continue the task that needed it.
2. Read [Community MCP setup](../../../COMMUNITY_MCP.md) for installation, Codex
   and Claude configuration, environment variables, and project access lists.
   Reuse an existing valid API token privately when authorized. Never print
   token-bearing configuration or credentials into chat, logs or shell arguments.
3. Install the pinned adapter if needed:

   ```sh
   uv tool install --python python3.11 'openproject-ce-mcp==0.4.0'
   ```

4. Configure a stdio command pointing to the installed executable. Set
   `OPENPROJECT_BASE_URL` to the instance URL without `/mcp` or `/api/v3`, and
   `OPENPROJECT_API_TOKEN` to its personal API token. Set explicit
   `OPENPROJECT_READ_PROJECTS` and `OPENPROJECT_WRITE_PROJECTS` lists; empty lists
   deny access. `*` permits all projects visible to the API user.
5. Enable `OPENPROJECT_ENABLE_ADMIN_READ` and `OPENPROJECT_ENABLE_ADMIN_WRITE`
   when group management is requested. These are instance-wide operations and
   still require permission in OpenProject. Project lists do not scope them.
6. Replace an existing HTTP `openproject-local` registration rather than creating
   a duplicate. Preserve other client settings. Keep actual configuration local
   and ignored by Git, with token-bearing files readable only by the owner.
7. Reconnect or restart the client. Verify `get_current_user`, `list_projects`,
   `list_groups`, and `list_roles`. For a known project, verify
   `list_project_memberships` and `list_work_packages`.

When no valid token is available, direct the user to **My account → Access
tokens** to create one and save it in private configuration. Do not ask for the
token in chat. The integration acts as the token owner.

## Troubleshooting

| Symptom | Action |
|---|---|
| Executable not found | Use its absolute installed path; GUI clients can have a different `PATH`. |
| Connection refused | Start the local OpenProject app and verify the base URL. |
| API returns 401 | Check the token is valid and API token authentication is enabled. Never log the token. |
| HTTP 404 from `/mcp` | Replace the old HTTP registration with Community stdio configuration. |
| Project absent or write rejected | Check project read/write lists and the API user's permissions. |
| Group tools missing | Enable admin read/write in the adapter and reconnect. |
| `data` or other raw REST fields rejected | Use the Community tool's typed arguments. |
| Preview succeeds but nothing is saved | Inspect the preview, then call with `confirm: true` for an authorized change. |

The `confirm` flag is a protocol step. It does not require another user prompt
when the requested action is already authorized. Return to the original task
once the connection is verified; the work package skill describes its tools.
