# Built-in MCP setup

This fork enables the `mcp_server` and `define_custom_style` (Administration > Design) features. All other features
behave as upstream. The change does not disable authentication or grant user permissions. Administrators can still disable the server and individual
tools under **Administration → Artificial Intelligence (AI) → Model Context
Protocol (MCP)**.

The endpoint is the instance's base URL plus `/mcp`: `https://projects.machinekind.ai/mcp` in production and
`http://localhost:3000/mcp` for local development. The additional project, group, user, membership, role, project
configuration, and board tools in this fork use OpenProject's normal contracts and permissions.

## Authentication

Create a personal API token under **Account settings → Access tokens → API**. API token authentication must be
enabled in OpenProject. The connection acts as the token owner. It does not elevate that user's permissions.

Clients send the token in the header `Authorization: Bearer <API_TOKEN>`. Bearer authentication accepts only tokens
that start with `opapi-`. Create a new token if yours does not.

Store the token only in local client configuration, readable only by your user. Do not commit or print it.

Name each registration after its instance, for example `openproject-prod` and `openproject-local`. Distinct
names keep test data out of production when both are connected.

## Connecting a client

The [README](README.md) has step-by-step setup for Claude Code, Codex, and Antigravity against production. For a
local instance, follow the same steps with the name `openproject-local` and the URL `http://localhost:3000/mcp`.
Restart or reconnect the client after changing its configuration.

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
modules. All four take the project's numeric id or its identifier.
`search_boards`, `create_board`, `create_board_list`, and `update_board` manage
boards and their filters; the Boards module registers them, and they act only in
a project where `board_view` is enabled. These tools take flat arguments rather
than a `data` payload.

Check the returned payload's `error` field even if the MCP envelope has
`isError: false`; permission and validation failures can use that response shape.

See the [work package skill](.claude/skills/openproject-work-packages/SKILL.md)
for team setup, task creation, and milestone scheduling. For shared clients,
configure per-user OAuth with the `mcp` scope as described in
[OpenProject's MCP documentation](https://www.openproject.org/docs/system-admin-guide/integrations/mcp-server/).
