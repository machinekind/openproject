---
name: openproject-work-packages
description: Create and structure OpenProject work packages (tasks, milestones, epics, features, bugs, user stories, summary tasks) through the openproject-local Community MCP integration, including parents, relations, assignees, dates, versions, projects, groups and memberships. Use whenever the user asks to add tasks, tickets, issues, milestones, epics or a plan to OpenProject, to put work under a milestone or parent, to set up a project or team, or mentions Wojtek or any project tracked in this instance, even without saying "work package" or "MCP".
---

# OpenProject work packages via Community MCP

A work package is a tracked item. Its type controls the available fields and
whether it can contain children. Use the independent `openproject-ce-mcp` 0.4.0
server registered as `openproject-local`. It calls API v3 at
`http://localhost:3000`; the built-in Enterprise `/mcp` endpoint is not needed.
If its tools are missing, use the `openproject-mcp-connect` skill first.

The tools take named arguments, not raw REST payloads or a `data` wrapper. Inspect
the connected tool schema before using an argument. Never guess IDs.

## Workflow

1. Resolve the project with `list_projects(search: "Wojtek")`. Keep its identifier
   or numeric ID. Follow `next_offset` when a list is paginated.
2. Call `list_types(project: "wojtek")` or
   `get_project_work_package_context(project: "wojtek", type: "Task")` to find the
   enabled types and creation context.
3. Resolve people with `list_users(search: "Marcin")` and check
   `list_project_memberships(project: "wojtek")`. An assignee must be a member
   directly or through a group with an assignable role.
4. Call `create_work_package` for a preview. Check `ready`, `validation_errors`,
   and the resolved payload. For an authorized change, repeat the same arguments
   with `confirm: true`. Apply this two-call pattern to other writes as well.
   The protocol flag does not require another user prompt when the user has
   already authorized the change. A preview alone has not saved anything.
5. Create parents before children, using the returned ID as `parent` on children.
6. Verify with `get_work_package` or `list_work_packages(project: "wojtek")`.

## Tasks and updates

Example arguments for `create_work_package` (resolve the assignee ID first):

```json
{"project": "wojtek", "type": "Task", "subject": "New leg design", "assignee": "32", "start_date": "2026-10-01", "due_date": "2026-10-14", "estimated_time": "PT8H"}
```

Use `description` for Markdown, `parent` for a parent work package ID, and
`target_versions` for version IDs/names from `list_versions`. For updates, call
`update_work_package(work_package_id: 42, ...)` with only changed fields. The
adapter handles REST `lockVersion`; do not supply it as an MCP argument. Re-read
the item after conflicts and verify returned dates, which can move to working days.

## Types and milestones

| Type | Dates | Can contain children |
|---|---|---|
| Task, Epic, Feature, User story, Bug | Start and due dates | Yes |
| Summary task | Span, potentially calculated from children | Yes |
| Milestone | Single date | No |

Only enabled project types are accepted. New projects on this development
instance may start with no enabled types. Enable the needed types under
**Project settings → Work package types**, then retry.

When tasks lead to a milestone, use `create_work_package_relation`:

```json
{"work_package_id": 42, "related_to_work_package_id": 46, "relation_type": "precedes"}
```

OpenProject stores this as the milestone `follows` the task, with the endpoints
swapped. Verify the response rather than assuming the stored direction. Use a
Summary task or Epic parent when the user wants a hierarchy.

Version 0.4.0 does not expose the milestone `date` or `scheduleManually` write
fields. Do not send task date arguments and assume they set a milestone date.
Use the Community UI or API v3 for these fields; see
[references/payloads.md](references/payloads.md).

## Projects, groups and memberships

Teams are ordinary OpenProject groups. These operations use Community API v3:

| Need | Tool | Example arguments, before confirmation |
|---|---|---|
| Project | `create_project` | `{"name": "Wojtek", "identifier": "wojtek"}` |
| Group | `create_group` | `{"name": "Wojtek", "user_ids": [32]}` |
| Add person to group | `update_group` | `{"group_id": 33, "add_user_ids": [32]}` |
| Role IDs | `list_roles` | Find a project role such as Member; follow pagination. |
| Add group or person to project | `create_membership` | `{"project": "wojtek", "principal": "33", "roles": ["Member"]}` |

Resolve existing users and groups before creating duplicates. If the user asks to
create an account, `create_user` accepts `login`, `email`, `firstname`, `lastname`,
and `status: "invited"`. Invited accounts do not require a password; delivery
depends on the instance's mail configuration. User creation can send an
invitation, so it needs the user's instruction to invite/create that person.

Order: existing or requested user, group, project membership, work packages.
Group membership gives its users the assigned project role, including users
added to the group later. Admin tools must be enabled in the integration, and
the API user needs the corresponding OpenProject permissions.

"Me" means the API token owner. Call `get_current_user`; do not infer the account
from the person speaking to the assistant.

## Reporting

Return created IDs and subjects, the project URL
(`http://localhost:3000/projects/<identifier>/work_packages`), and any unresolved
limitations. Distinguish previews from saved changes and relations from parent
hierarchies. Consult [references/payloads.md](references/payloads.md) for errors
and fields that need the REST API.
