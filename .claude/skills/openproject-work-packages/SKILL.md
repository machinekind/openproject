---
name: openproject-work-packages
description: Create and structure OpenProject work packages (tasks, milestones, epics, features, bugs, user stories, summary tasks) through a connected OpenProject MCP server, local or deployed, including parents, milestone relations, assignees, dates, versions and the project, group, user, membership, type, module and board tools that a new project needs first. Use this whenever the user asks to add tasks, tickets, issues, milestones, epics or a plan to OpenProject, to put work under a milestone or parent, to enable a work package type or a module, to create a board or set its filters and lists, to set up a project or team in OpenProject, or mentions Wojtek or any project tracked in this instance, even if they do not say "work package" or "MCP".
---

# OpenProject work packages via MCP

A "work package" is OpenProject's word for any tracked item. Its **type** (Task, Milestone, Epic, ...) decides which fields it has, whether it is a single date or a span, and which projects may hold it. Most mistakes come from the type rules, so read the type table before creating anything.

The tools come from an OpenProject instance's built-in MCP server and are named `mcp__openproject-<instance>__*`, for example `openproject-local` for development and `openproject-prod` for production. They take the same JSON as the REST API v3, wrapped in each tool's arguments. If no such tools are available, connect first with the `openproject-mcp-connect` skill.

**Know which instance you are writing to.** Call `current_user` first; its result names the instance's URL. If tools for more than one instance are connected, confirm the target with the user before any write. Ids differ between instances, so never reuse an id learned on another one.

## Workflow

1. **Resolve the project.** Call `search_projects` with the name and keep the numeric `id`. If nothing matches, create it with `create_project` (see "Setting up a project" below).
2. **Resolve the type.** Call `list_types` once and map names to ids. Never guess ids; they differ between instances. `list_project_types` shows which of them the project accepts.
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

A project only accepts the types enabled in its settings. If a create fails with "Type is not set to one of the allowed values", the type is not enabled for that project. A project created through the API starts with **no types** when the instance marks none as default. Call `list_project_types` to see what is enabled and `update_project_types` to change it, then retry:

```
list_project_types(project_id: 8)
update_project_types(project_id: 8, add: [5])
```

Type ids come from `list_types`. `update_project_types` also takes `remove`; a type still used by work packages in the project cannot be removed. Both tools need the numeric project id, not the identifier. Changing types needs the "Select types" permission in the project.

`list_types` returns an empty list while the instance has no project at all, even for an administrator, because the list is only visible to users with work package permissions in some project. `list_statuses` was observed to behave the same way. Create the first project, then list again.

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

Updates go through `update_work_package` with `id` and `data`; put the `lockVersion` you last read inside `data`. Only send the fields that change. A 409-style conflict means someone changed it since; re-read and retry. These tools write immediately. There is no preview step.

Check the returned payload for `error` before reporting success. The built-in server can return a permission or validation error in `structuredContent.error` while the MCP envelope's `isError` is false.

More payload examples, relation types and the error table are in [references/payloads.md](references/payloads.md). Read it when you hit an error you do not recognise or need a field not listed above.

## Setting up a project, team and members

These tools exist only in this fork; upstream OpenProject's MCP server cannot do them.

| Need | Tool | Key payload |
|---|---|---|
| Project | `create_project` | `{"data": {"name": "Wojtek", "identifier": "wojtek"}}`. Always a plain project workspace. |
| Team | `create_group` | `{"data": {"name": "Wojtek", "_links": {"members": [{"href": "/api/v3/users/32"}]}}}` |
| Person | `create_user` | `{"data": {"login": "marcin", "email": "...", "firstName": "...", "lastName": "...", "status": "invited"}}`. Create users as `invited`; they set their own password from the invitation mail. Never send a `password` through this tool: request parameters are logged. If the instance has no outgoing mail, an admin sets the password at `/users/<id>/edit`. |
| Role ids | `list_roles` | Member is the normal choice for a team. |
| Add to project | `create_membership` | `{"data": {"_links": {"principal": {"href": "/api/v3/groups/33"}, "project": {"href": "/api/v3/projects/8"}, "roles": [{"href": "/api/v3/roles/4"}]}}}` |
| Which types are enabled | `list_project_types` | `{"project_id": 8}` or `{"project_id": "wojtek"}`. |
| Enable a type | `update_project_types` | `{"project_id": 8, "add": [5], "remove": [3]}`. Ids from `list_types`. A type still used by work packages cannot be removed. |
| Which modules are on | `list_project_modules` | `{"project_id": "wojtek"}`. Any member of the project may call it. Returns every module with its `name`, `enabled`, `dependencies` and enterprise state. |
| Turn a module on or off | `update_project_modules` | `{"project_id": "wojtek", "enable": ["board_view"]}`. New projects get the instance's default modules, which normally include `board_view`; enable it only when `create_board` answers "The Boards module is not enabled in this project." Dependencies are never enabled implicitly — pass them in the same call. A module gated by an enterprise feature can be enabled without a token, as on the settings page; `enterpriseFeatureAvailable` in the payload says whether the feature itself works. |

Order: user, then group with that user, then membership of the group in the project, then work packages. Adding a group to a project gives every member of the group the role, including people added later.

"Me" in this instance is whoever the API token belongs to; call `current_user` if unsure. Do not assume the user has an account with their own name.

## Boards

Board tools come from the Boards module, so a project needs `board_view` enabled before any of them works. It is normally on in new projects. Only `create_board` names the missing module; with `board_view` off, `create_board_list` and `update_board` answer "The given board could not be found." and `search_boards` returns nothing. Enable the module with `update_project_modules`, which needs the "Select project modules" permission. Managing boards needs the separate "Manage boards" permission, along with "Save views" and "Manage public views", which the Member role has by default and which "Manage boards" declares as its dependencies.

| Need | Tool | Key payload |
|---|---|---|
| Find boards | `search_boards` | `{"project_id": 8}`, or `{"name": "delivery"}` for a partial name. Each result carries the board's saved filters in `options` and its lists in `widgets`. |
| Create a board | `create_board` | `{"project_id": 8, "name": "Delivery", "type": "subtasks"}` |
| Add a list (column) | `create_board_list` | `{"board_id": 12, "value": 50}` |
| Rename or set filters | `update_board` | `{"id": 12, "filters": [{"type": {"operator": "=", "values": ["5"]}}]}` |

`create_board` takes one `type`: `basic` (a free board with a single unnamed list), `status` (starts with a list for the default status), `version` (one list per open version), and `assignee`, `subproject`, `subtasks`, which start with no list at all. `subtasks` is the parent-child board.

`create_board_list`'s `value` is the id of what the list is built on: a status, a user or group, a version, a subproject, or the parent work package on a parent-child board. It is required on every action board; leaving it out answers "Pass the value the new list shall show: a status ID." and the equivalent for the other types. Pass `null` on an assignee board for the unassigned list. A board takes one list per value: a value that already has a list, such as the default status of a new status board or an open version of a new version board, is rejected with "The board already has a list for this value." `value` is ignored on a basic board. `name` is optional and defaults to the value's own name. Call the tool once per column.

`update_board`'s `filters` use the APIv3 filter form, with values as strings, and apply to every list of the board. The array replaces the filters the board has; `[]` removes them all, so the tool is marked destructive. Pass `name`, `filters` or both. Each entry is one object naming one attribute, as `{"type": {"operator": "=", "values": ["5"]}}`; anything else answers "Each filter must be an object like ...". An action board refuses a filter on the attribute its lists are built on, because that filter would overwrite every list: a status filter on a status board answers "A status board filters its lists by status; add or remove lists instead." A backlogs sprint task board rejects filter changes altogether, because its sprint scoping lives in that array. It is otherwise a status board: `create_board_list` adds a status column to it as the UI does, and the next sprint's board copies its columns.

Order for a new initiative: `create_board` (enable `board_view` first only if it reports the module is missing), one `create_board_list` per column, then `update_board` for the filters.

## Reporting back

List what was created as a short table of id and subject, name the project URL (`<instance URL>/projects/<identifier>/work_packages`, with the instance URL taken from the `current_user` result), and state plainly anything you could not do, such as a module you lacked the permission to enable. Do not claim a hierarchy exists when you created relations.
