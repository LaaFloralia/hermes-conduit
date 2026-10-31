# Personal Linear tasks

The owner-facing task source uses its own Linear personal API key. It never falls back to the existing agent credential. A Mac-side operator must configure both `LAA_LINEAR_PERSONAL_TOKEN_HELPER` (an absolute path to an executable that prints only the key to standard output) and `LAA_LINEAR_PERSONAL_VIEWER_ID` (the expected Linear user ID) in the Bridge's runtime environment. The helper and credential are provisioned by the owner/operator, not by the iPhone. Neither the key nor helper output belongs in the repository, command arguments, logs, or an iPhone response. When either setting is missing, the key is malformed, or the `viewer` is different, the personal source refuses access. Each operation checks the viewer using the same credential used for its subsequent request.

These authenticated `tasks:read` endpoints are separate from the existing `/v1/tasks` agent view:

- `GET /v1/personal-tasks`: `view=all|mine|active|backlog`, optional `search`, `project`, `cycle`, `customView`, `limit`, and `cursor`. A saved view cannot be combined with other filters. Search and saved view evaluation are performed by Linear.
- `GET /v1/personal-tasks/{id}`: an issue by Linear identifier or `linear:`-prefixed identifier, including its full description.
- `GET /v1/task-projects`, `/v1/task-cycles`, `/v1/task-views`, `/v1/task-inbox`: paginated personal collections. Reading the inbox does not mark it read.
- `GET /v1/task-metadata`: first page of choices with a `complete` flag per collection. If a flag is false, the client must not present that subset as complete.
- `GET /v1/task-options?kind=teams|users|states|labels|milestones`: paginated choices. Projects and cycles use the separate collection endpoints above.

Pages contain `items`, `nextCursor`, `observedAt`, and `paginationConsistency: "live"`. Cursors are tied to the filter and viewer. Linear can change between pages, so this is not a snapshot; clients should deduplicate by ID and refresh when needed. Individual issue label sets explicitly include `labelsComplete`.

The source uses fixed GraphQL documents and rejects partial/error responses instead of interpreting them as empty results. No live credential or task data was used for the fixture tests. The current notification relay does not accept Linear events; inbox data does not imply APNs delivery.
