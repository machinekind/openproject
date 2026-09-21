# OpenProject MCP payloads and errors

## Work package fields

All links use API v3 hrefs. Numeric ids come from the search and list tools; do not build hrefs from names.

| Field | Format | Notes |
|---|---|---|
| `subject` | string | Required. |
| `description` | `{"raw": "markdown"}` | Markdown; the server renders `html`. |
| `startDate`, `dueDate` | `"YYYY-MM-DD"` | Not valid on milestones. |
| `date` | `"YYYY-MM-DD"` | Milestones only. |
| `scheduleManually` | boolean | `false` lets follows relations and children drive the dates. Defaults to `true` on new items. |
| `estimatedTime` | ISO 8601 duration, e.g. `"PT8H"`, `"P2D"` | Hours per day come from instance settings. |
| `percentageDone` | integer 0-100 | May be derived from status depending on instance settings. |
| `lockVersion` | integer | Required on every update; read it from the item first. |
| `_links.project` | `/api/v3/projects/<id>` | Required on create. |
| `_links.type` | `/api/v3/types/<id>` | Required on create; must be enabled in the project. |
| `_links.status` | `/api/v3/statuses/<id>` | Defaults to the first status; transitions follow the workflow of the type and role. |
| `_links.priority` | `/api/v3/priorities/<id>` | Defaults to Normal. |
| `_links.assignee`, `_links.responsible` | `/api/v3/users/<id>` or `/api/v3/groups/<id>` | Must be a project member with an assignable role. |
| `_links.parent` | `/api/v3/work_packages/<id>` | Any non milestone in the same or a related project. |
| `_links.targetVersions` | array of `/api/v3/versions/<id>` | Find ids with `search_versions`. |
| `_links.category` | `/api/v3/categories/<id>` | Optional project category. |
| custom fields | `customFieldN` or `_links.customFieldN` | Resolve names with `search_custom_fields`. |

## Examples

Milestone with a date:

```json
{"subject": "Wojtek V2", "date": "2026-12-15",
 "_links": {"project": {"href": "/api/v3/projects/8"}, "type": {"href": "/api/v3/types/2"}}}
```

Epic, feature under it, task under the feature (three calls, each using the previous id):

```json
{"subject": "Locomotion", "_links": {"project": {"href": "/api/v3/projects/8"}, "type": {"href": "/api/v3/types/5"}}}
{"subject": "New leg design", "_links": {"project": {"href": "/api/v3/projects/8"}, "type": {"href": "/api/v3/types/4"}, "parent": {"href": "/api/v3/work_packages/50"}}}
{"subject": "Print knee bracket", "_links": {"project": {"href": "/api/v3/projects/8"}, "type": {"href": "/api/v3/types/1"}, "parent": {"href": "/api/v3/work_packages/51"}}}
```

Update dates and switch to automatic scheduling:

```json
{"lockVersion": 2, "startDate": "2026-10-01", "dueDate": "2026-10-14", "scheduleManually": false}
```

Comment on an item: `create_work_package_comment` with the id and markdown text.

## Relation types

`create_work_package_relation` takes `from_work_package_id`, `to_work_package_id`, `type` and optional `lag` in days.

| Type | Meaning | Affects scheduling |
|---|---|---|
| `precedes` / `follows` | Ordering. `from precedes to` is stored as `to follows from`. | Yes: a following item with automatic scheduling starts after the preceding one finishes plus lag. |
| `blocks` / `blocked` | Cannot progress until the other is done. | No |
| `relates` | Loose link. | No |
| `duplicates` / `duplicated` | Same work reported twice. | No |
| `includes` / `partof` | Loose containment without hierarchy. | No |
| `requires` / `required` | Dependency without ordering. | No |

Hierarchy is not a relation; set `_links.parent` on the child instead.

## Errors and what they mean

| Error text | Cause | Fix |
|---|---|---|
| Type is not set to one of the allowed values. | Type not enabled in the project. | Enable it with `update_project_types`. Projects created via the API here start with none. |
| Parent cannot be a milestone. | Milestones cannot hold children. | Use a `precedes` relation to the milestone, or a Summary task or Epic as parent. |
| Assignee is invalid. / Responsible is invalid. | Person is not a project member with an assignable role. | Add them with `create_membership`, or add their group. |
| Project is invalid. | Wrong id, or the token's user cannot see it. | Re-run `search_projects`. |
| Subject can't be blank. | Missing subject. | Add one. |
| lockVersion conflict | Item changed since read. | Re-read, take the new `lockVersion`, resend. |
| Status transition not allowed | Workflow forbids the jump for this type and role. | Call `list_statuses`, pick an allowed next status, or leave status unset on create. |
| Workspace type is not set to one of the allowed values. | Only from raw API project creation. | Use `create_project`, which sets the workspace type. |
| MCP server is not available. (HTTP 404) | MCP disabled in Administration. | Check Administration, AI, Model Context Protocol. This fork enables only the MCP entitlement without an Enterprise token. |
| Types still in use by work packages: ... | `update_project_types` was asked to remove a type the project still uses. | Move or delete those work packages, or leave the type enabled. |
| Not available on this instance: ... / Unknown module names: ... | A name passed to `update_project_modules` is misspelled or its module is not installed. | Take names from `list_project_modules`; the message also lists the valid ones. |
| The Boards module is not enabled in this project. | `board_view` is off in the project. | `update_project_modules` with `{"enable": ["board_view"]}`. |
| The given board could not be found. | Wrong id, the token's user cannot see the board, or `board_view` is off in its project. | Run `search_boards`, then `list_project_modules`. |
| Lists cannot be added to a board of this type. | The board is an action board whose attribute is not status, assignee, version, subproject or subtasks. No shipped board is; a backlogs sprint task board is a status board and takes lists. | Read the board's `options.attribute` from `search_boards`; add the list in the UI if the attribute comes from a plugin. |

## Group, user and membership payloads

Group members are set through the `members` link array on create or update. Invited users (`"status": "invited"`) need no password. Active users need `"password"`. A membership needs a principal (user or group), a project and at least one role; `list_roles` gives the ids and Member is the default choice for a team.

## Project configuration and board arguments

These tools take flat arguments, not a `data` payload.

| Tool | Arguments |
|---|---|
| `list_project_types` | `project_id` (numeric, required) |
| `update_project_types` | `project_id` (numeric, required), `add` (array of type ids), `remove` (array of type ids). At least one of `add` and `remove` is required, and an id must not appear in both. |
| `list_project_modules` | `project_id` (numeric id or identifier, required) |
| `update_project_modules` | `project_id` (numeric id or identifier, required), `enable` (array of module names), `disable` (array of module names). At least one of `enable` and `disable` is required, and a name must not appear in both. |
| `search_boards` | `id`, `project_id`, `name` (partial, not case-sensitive), `page` |
| `create_board` | `project_id` (required), `name` (required), `type` (required: `basic`, `status`, `assignee`, `version`, `subproject`, `subtasks`) |
| `create_board_list` | `board_id` (required), `value` (id of the status, assignee, version, subproject or parent work package; `null` for the unassigned list on an assignee board), `name` |
| `update_board` | `id` (required), `name`, `filters` (APIv3 filter array, replaces the board's filters) |

Enabling a type is all or nothing: if one id in `add` or `remove` fails, none of the changes in that call is kept. `update_project_modules` computes the new module list from the project's current one, so modules you do not name keep their state; dependencies are never enabled implicitly.

A parent-child board for an epic:

```
update_project_modules(project_id: 8, enable: ["board_view"])
create_board(project_id: 8, name: "Locomotion", type: "subtasks")
create_board_list(board_id: 12, value: 50)
update_board(id: 12, filters: [{"type": {"operator": "=", "values": ["5"]}}])
```

The board filters apply to every list. `search_boards` reads them back from the board's `options`, and its lists from `widgets`, where each widget names the query it renders.
