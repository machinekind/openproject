---
name: openproject-mcp-connect
description: Connect Claude Code, Codex or another MCP client to an OpenProject instance's built-in MCP endpoint, local or deployed, and verify it. Use when no mcp__openproject-* tools are available, the user asks to connect OpenProject or set up MCP, or a connection returns 401 or 404.
---

# Connect to an OpenProject MCP server

The endpoint is the instance's base URL plus `/mcp`, for example `http://localhost:3000/mcp` in development or
`https://<host>/mcp` for a deployed instance. This fork serves it without an Enterprise token. Authentication,
user permissions and the administrator's server and tool switches work as in upstream.

## Steps

1. If any `mcp__openproject-*__current_user` tool exists, call it. A returned user means the connection works.
   Continue with the original task.
2. Otherwise ask which instance to connect to, and name the server after it: `openproject-local` for
   development, `openproject-prod` for production. Distinct names keep test data out of production.
3. Have the user create an API token under **Account settings → Access tokens** and run the registration
   themselves, so the token never enters the conversation. [MCP setup](../../../MCP_SETUP.md) has the command,
   which reads the token from a hidden prompt.
4. After the user reconnects the client, call `current_user`, `search_projects` and `list_roles`. All three are
   reads. Then return to the original task, using `openproject-work-packages` for its workflow.

## Rules for credentials

- Never ask for a token in chat, and never print, log or commit one. A Base64 `Authorization` header is a
  credential too.
- The connection acts as the token's owner. For ongoing agent work, recommend a dedicated non-admin account:
  work package text can carry instructions, and an administrator's token would let them reach user management.

## When it fails

| Symptom | Meaning |
|---|---|
| Connection refused | The instance is not running, or the URL is wrong. |
| HTTP 401 | The token is wrong or revoked, or API tokens are disabled. For OAuth, the `mcp` scope is missing. |
| HTTP 404 "MCP server is not available" | The server is switched off under **Administration → AI → Model Context Protocol**, or the instance runs an image without this fork's code. |
| A setup tool is missing | It is disabled in the same administration page, or the running image predates it. |
| Permission error in a tool result | The token's user lacks the OpenProject permission. Creating groups needs an administrator. |
