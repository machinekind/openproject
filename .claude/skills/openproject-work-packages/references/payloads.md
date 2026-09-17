# Community MCP arguments and REST fallback

These examples target `openproject-ce-mcp==0.4.0`. Use the connected schema as
the authority for argument names. Call writes first without `confirm`, inspect
`ready` and `validation_errors`, then repeat with `confirm: true` when authorized.

## MCP examples

Create a task, then a child using its returned ID:

```json
{"project": "wojtek", "type": "Task", "subject": "New leg design"}
{"project": "wojtek", "type": "Task", "subject": "Print knee bracket", "parent": "50"}
```

Update via `update_work_package`:

```json
{"work_package_id": 42, "start_date": "2026-10-01", "due_date": "2026-10-14", "estimated_time": "PT8H"}
```

Add a comment via `add_work_package_comment` with `work_package_id` and `comment`.
Send only fields to change. `description` and comments are Markdown strings.
Dates are `YYYY-MM-DD`; durations are ISO 8601, such as `PT8H` or `PT1H30M`.
The adapter reads the current REST `lockVersion` when updating.

## Relations

`create_work_package_relation` takes `work_package_id`,
`related_to_work_package_id`, `relation_type`, and optionally `lag` in days.

| Type | Meaning | Affects scheduling |
|---|---|---|
| `precedes` / `follows` | Ordering | Yes, for automatically scheduled items |
| `blocks` / `blocked` | Blocker | No |
| `relates` | Loose link | No |
| `duplicates` / `duplicated` | Duplicate work | No |
| `includes` / `partof` | Loose containment | No |
| `requires` / `required` | Dependency | No |

OpenProject canonicalizes inverse relations, swapping their endpoints. Read the
returned type and endpoints to confirm direction. Hierarchy instead uses `parent`
on the child; a milestone cannot be a parent.

## Fields requiring REST API v3 or the UI

The Community adapter's write schema does not cover every REST field. In 0.4.0,
milestone `date` and `scheduleManually` require the UI or direct API calls.
Authenticate API calls using the configured token privately; do not log it or
put it in command arguments. Use `/api/v3`, never `/mcp`, for this fallback.

For a milestone, send this to `PATCH /api/v3/work_packages/<id>` using the
`lockVersion` from a fresh `GET`:

```json
{"lockVersion": 2, "date": "2026-12-15"}
```

To enable automatic scheduling on an existing item:

```json
{"lockVersion": 2, "scheduleManually": false}
```

Send these raw fields only to API v3, not to Community MCP tools. A subsequent
write needs the new `lockVersion`. Re-read after a conflict and verify the saved
date, especially when scheduling dependencies are present.

## Errors

| Error | Action |
|---|---|
| Type is not set to one of the allowed values | Check `list_types(project: ...)`; enable the type in project settings. |
| Parent cannot be a milestone | Use a relation to the milestone or a Summary task/Epic parent. |
| Assignee or responsible is invalid | Add project membership with an assignable role, directly or through a group. |
| Project is invalid or forbidden | Resolve it again with `list_projects`; check the API user's permissions and the integration's read/write project lists. |
| Subject can't be blank | Supply a nonempty subject. |
| Conflict / stale lock version | Re-read and retry against current data. |
| Status transition not allowed | Inspect the work package context and workflow; choose an allowed status. |
| Admin tools missing | Check `OPENPROJECT_ENABLE_ADMIN_READ` and `OPENPROJECT_ENABLE_ADMIN_WRITE`, then reconnect. |
| Unknown argument `data`, `_links`, or `lockVersion` | A built-in MCP/REST payload was sent to a Community tool. Use its named arguments. |
| `ready: false` without an MCP error | The preview failed validation. Resolve `validation_errors`; do not confirm. |
| HTTP 404 from `/mcp` | An old HTTP registration is still active. Use the Community stdio connection. |
