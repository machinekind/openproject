---
name: openproject-work-packages
description: Create and structure OpenProject work packages (tasks, milestones, epics, features, bugs, user stories, summary tasks) through the openproject-local MCP server, including parents, milestone relations, assignees, dates, versions and the project, group, user and membership tools that a new project needs first. Use this whenever the user asks to add tasks, tickets, issues, milestones, epics or a plan to OpenProject, to put work under a milestone or parent, to set up a project or team in OpenProject, or mentions Wojtek or any project tracked in this instance, even if they do not say "work package" or "MCP".
---

# OpenProject work packages via MCP

A "work package" is OpenProject's word for any tracked item. Its **type** (Task, Milestone, Epic, ...) decides which fields it has, whether it is a single date or a span, and which projects may hold it. Most mistakes come from the type rules, so read the type table before creating anything.

The MCP server is the running OpenProject at `http://localhost:3000/mcp`, registered in Codex and Claude Code as `openproject-local`. Its tools take the same JSON as the REST API v3, wrapped in each tool's arguments. If no `mcp__openproject-local__*` tools are available, connect first with the `openproject-mcp-connect` skill. This fork enables only the `mcp_server` entitlement without a license token; other Enterprise features retain their token checks.

## Workflow

1. **Resolve the project.** Call `search_projects` with the name and keep the numeric `id`. If nothing matches, create it with `create_project` (see "Setting up a project" below).
2. **Resolve the type.** Call `list_types` once and map names to ids. Never guess ids; they differ between instances.
3. **Resolve people.** Call `search_users` for the assignee. An assignee must already be a member of the project, either directly or through a group. If they are not, add them with `create_membership` first, otherwise the create fails with "Assignee is invalid".
4. **Create the items** with `create_work_package`. Create parents before children so you have the parent id.
5. **Link milestones with relations, not parents.** See "Milestones".
6. **Verify** with `search_work_packages` filtered by `project_id` and report ids and subjects back to the user.

## Type rules

| Type | Dates | Can be a parent | Notes |
|---|---|---|---|
| Task | startDate, dueDate | yes | The default for "add a task". |
| Milestone | `date` only | **no** | Setting a milestone as `parent` fails with "Parent cannot be a milestone." |
| Summary task | span, rolled up from children | yes | Use as the container when the user wants a phase or release with tasks under it. |
| Epic | span | yes | Large theme; usually holds features. |
| Feature | span | yes | A deliverable; usually holds tasks. |
| User story | span | yes | Agile requirement. |
| Bug | span | yes | A defect. |

A project only accepts the types enabled in its settings. If a create fails with "Type is not set to one of the allowed values", the type is not enabled for that project. Projects created through the API on this dev instance start with **no types**, because the seed marks none as default. Enable them under Project settings, Work package types, or ask an admin, then retry.

## Milestones

Milestones are single dates and cannot contain children. When the user says "tasks under milestone X", they usually mean the tasks lead to the milestone. Model that with a `precedes` relation from each task to the milestone:

```
create_work_package_relation(from_work_package_id: <task>, to_work_package_id: <milestone>, type: "precedes")
```

The server stores it as the milestone *follows* the task. Once tasks have dates and the milestone has `scheduleManually: false`, the milestone date moves to the end of the latest task. Tell the user this is a relation, not a hierarchy, and offer a Summary task or Epic parent plus a milestone if they want both grouping and a date marker.

## Payload cheat sheet

Minimal task payload (pass this object as `data` to `create_work_package`):

```json
{"subject": "New leg design",
 "_links": {"project": {"href": "/api/v3/projects/8"},
            "type": {"href": "/api/v3/types/1"},
            "assignee": {"href": "/api/v3/users/32"}}}
```

Add as needed: `"description": {"raw": "markdown text"}`, `"startDate": "2026-10-01"`, `"dueDate": "2026-10-14"`, `"estimatedTime": "PT8H"` (ISO 8601 duration), `"_links": {"parent": {"href": "/api/v3/work_packages/46"}, "priority": {...}, "status": {...}, "responsible": {...}, "targetVersions": [{"href": "/api/v3/versions/3"}]}`. Milestones take `"date"` instead of start and due.

Updates go through `update_work_package` with `id` and `data`; put the `lockVersion` you last read inside `data`. Only send the fields that change. A 409-style conflict means someone changed it since; re-read and retry. These tools write immediately and have no `confirm` argument.

Check the returned payload for `error` before reporting success. The built-in server can return a permission or validation error in `structuredContent.error` while the MCP envelope's `isError` is false.

More payload examples, relation types and the error table are in [references/payloads.md](references/payloads.md). Read it when you hit an error you do not recognise or need a field not listed above.

## Setting up a project, team and members

These tools exist only in this fork; upstream OpenProject's MCP server cannot do them.

| Need | Tool | Key payload |
|---|---|---|
| Project | `create_project` | `{"data": {"name": "Wojtek", "identifier": "wojtek"}}`. Always a plain project workspace. |
| Team | `create_group` | `{"data": {"name": "Wojtek", "_links": {"members": [{"href": "/api/v3/users/32"}]}}}` |
| Person | `create_user` | `{"data": {"login": "marcin", "email": "...", "firstName": "...", "lastName": "...", "status": "invited"}}`. Invited users set their own password; this dev instance sends no mail, so an admin sets one at `/users/<id>/edit`. |
| Role ids | `list_roles` | Member is the normal choice for a team. |
| Add to project | `create_membership` | `{"data": {"_links": {"principal": {"href": "/api/v3/groups/33"}, "project": {"href": "/api/v3/projects/8"}, "roles": [{"href": "/api/v3/roles/4"}]}}}` |

Order: user, then group with that user, then membership of the group in the project, then work packages. Adding a group to a project gives every member of the group the role, including people added later.

"Me" in this instance is whoever the API token belongs to; call `current_user` if unsure. Do not assume the user has an account with their own name.

## Reporting back

List what was created as a short table of id and subject, name the project URL (`http://localhost:3000/projects/<identifier>/work_packages`), and state plainly anything you could not do, such as a type that was not enabled. Do not claim a hierarchy exists when you created relations.
