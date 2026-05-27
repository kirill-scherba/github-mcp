# Design: github-mcp

## Architecture

```txt
┌─────────────┐     JSON-RPC 2.0      ┌──────────────────┐     curl HTTP      ┌─────────────┐
│  MCP Client  │ ◄───── stdin/stdout ──► │  github-mcp.pl   │ ◄──── REST ──────► │ GitHub REST │
│     (AI)     │                        │  (Perl)          │                   │   API       │
└─────────────┘                        │                  │                   └─────────────┘
                                        │  while (<STDIN>) │                        │
                                        │  dispatch → tool │                        │
                                        │  _github_api()   │                   ┌─────▼─────────┐
                                        │  _github_graphql()│ ◄─── GraphQL ───► │ GitHub GraphQL │
                                        └──────────────────┘                   └───────────────┘
                        stderr: [TIMESTAMP] [LEVEL] message
```

## Key Design Decisions

### 1. Single-file Perl Script

- No build step, no dependencies beyond `perl` + `JSON` + `curl`
- Easy to deploy — copy one file and set env
- Follows the same pattern as `db-tool-mcp`

### 2. Direct curl for GitHub API

Unlike ai-hub which used Safe sandbox + `_github_api` wrapper, this version:

- Calls `curl` directly from shell for each request
- No Perl module for HTTP (zero additional CPAN deps)
- `GITHUB_TOKEN` passed via `-H 'Authorization: Bearer ...'`

### 3. Environment-based Authentication

```perl
my $GITHUB_TOKEN = $ENV{GITHUB_TOKEN} // '';
```

No hardcoded tokens. Configurable via MCP settings `env` block.

### 4. Structured Logging to stderr

Format: `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`
Levels: DEBUG, INFO, WARN, ERROR
Stderr is clean — stdout reserved for JSON-RPC responses.

### 5. MCP Protocol

Implements:

- `initialize` — returns protocol version + server capabilities
- `ping` — health check
- `tools/list` — returns all 28 tool definitions with JSON Schema
- `tools/call` — dispatches to tool handler, catches errors

Error handling:

- Unknown method → `-32601` (Method not found)
- Tool execution error → `-32603` (Internal error)
- Missing required args → Perl `die` caught by eval

### 6. Tool Registration

Tools defined in `%tool_handlers` hash:

- Key: tool name (e.g. `github_issue_create`)
- Value: `{ description, handler => \&sub, inputSchema => { ... } }`

This makes adding a new tool a matter of:

1. Write the handler subroutine
2. Add entry to `%tool_handlers`

### 7. Multi-repo Support in github_issue_list

The `repo` parameter accepts either a single string or an array of repository names:

- **String** → single repo query (backward compatible)
- **Array** → iterates over all repos, collects issues from each, adds `repo` field per issue

Array mode handles per-repo errors gracefully — if one repo fails (e.g. doesn't exist), it logs the error and continues with the remaining repos. `inputSchema` uses `oneOf` to declare both types for MCP client compatibility.

## Data Flow

### Issue Creation

```txt
tools/call → github_issue_create(args)
  → validate required params (owner, repo, title)
  → JSON-encode payload
  → _github_api("POST", "/repos/o/r/issues", body)
    → curl -X POST -H 'Authorization: ...' -d '...' https://api.github.com/...
    → parse JSON response
  → return { issue_number, issue_url, state, title, created_at }
```

### File Retrieval

```txt
tools/call → github_get_file(args)
  → _github_api("GET", "/repos/o/r/contents/path?ref=...")
  → decode base64 content
  → return { name, path, size, sha, content, ... }
```

## Security

- GITHUB_TOKEN in environment only (not in code, not in logs)
- Token is masked as 'found'/'NOT found' in startup log
- curl called with `--connect-timeout 10 --max-time 30`
- Temporary files for POST bodies cleaned up in `unlink`

### 8. GraphQL API for Projects V2

A second helper `_github_graphql($query, $variables)` was added to support GitHub Projects V2 (and any other GraphQL-only GitHub APIs). It differs from `_github_api` (REST):

- Single endpoint: `POST https://api.github.com/graphql`
- Body is always JSON-encoded `{query, variables}`
- Response parsed for `data` **and** `errors` — GraphQL errors return HTTP 200 but contain `errors` array
- Uses same `GITHUB_TOKEN`
- Also uses temp file for body (same cleanup pattern)

All Projects V2 tools (10 tools total) use `_github_graphql`. One tool (`github_project_update_item`) uses `JSON::true`/`JSON::false` for boolean fields since GraphQL expects native booleans, not strings.

**Known GraphQL schema fix (2026-05-23):** The `github_project_list_fields` query referenced `ProjectV2DateField` and `ProjectV2NumberField` types that no longer exist in the GitHub GraphQL schema — removed. The `github_project_update_item` response query used `option { name }` on `ProjectV2ItemFieldSingleSelectValue` — corrected to `name` (the `option` wrapper field was removed from the schema).

### 9. Pull Request Tools (added 2026-05-23)

Six PR tools were added using the GitHub REST API:

- `github_pull_request_get` — uses `GET /repos/{o}/{r}/pulls/{n}` for full PR metadata
- `github_pull_request_list` — uses `GET /repos/{o}/{r}/pulls` with state/head/base/sort/direction filters
- `github_pull_request_get_files` — uses `GET /repos/{o}/{r}/pulls/{n}/files` with per-file patch snippets
- `github_pull_request_list_reviews` — uses `GET /repos/{o}/{r}/pulls/{n}/reviews` for review history and `GET /repos/{o}/{r}/pulls/{n}/comments` for line-level review comments
- `github_pull_request_create_review` — uses `POST /repos/{o}/{r}/pulls/{n}/reviews` with body, event, and optional line comments
- `github_pull_request_create` — uses `POST /repos/{o}/{r}/pulls` to create a PR with title, head, base (required) and optional body/draft

**Graceful degradation:** The create_review tool detects 401/403 responses and returns a descriptive error
with required token scopes instead of a generic failure. REST API validation errors preserve the GitHub
response body details in `reason`, so HTTP 422 failures include actionable messages such as self-approval
being rejected. GitHub does not allow approving your own pull request; callers should use `event=COMMENT`
for self-authored PRs or ask another user to review.

**Why REST not GraphQL:** PR REST endpoints are mature, well-documented, and return all needed data
in a single call (unlike Projects V2 which required GraphQL for nested data access).

### 10. Project Item Search with Status Filter

`github_project_search_items` (tool #29) provides a high-level search interface over Project V2 items:

**Why a separate tool instead of extending `github_project_list_items`:**
- Accepts project **title** (human-readable) instead of opaque project number
- Automatically resolves project by name across all user/organization projects
- Returns consistently formatted items with extracted Status field value
- Supports cursor-based pagination via `after` parameter

**Status filtering is client-side:**
GitHub GraphQL `ProjectV2.items` does **not** support the `filterBy` argument. Attempting to pass `filterBy: {fieldId, operator, value}` results in a GraphQL validation error (`Field 'items' doesn't accept argument 'filterBy'`). Instead, all items are fetched (without server-side filtering) and the status is compared client-side in Perl against the `Status` field value extracted from `fieldValues`. This works correctly but means pagination cursors reflect the unfiltered result set.

**Workflow:**
```
tools/call → github_project_search_items({owner, project, status?, limit?, after?})
  → _github_graphql: list projects → find by title → get project number
  → _github_graphql: items(first:N, after:CURSOR) — no filterBy
  → client-side: filter by status matching items with Status == $status
  → format items with {title, number, type, status, url, repo}
  → return {items, count, has_next_page, end_cursor}
```

**Pagination support:**
Both `github_project_list_items` and `github_project_search_items` support:
- `limit` (up to 100) — number of items per page
- `after` — cursor from previous response's `end_cursor`
- Response includes `end_cursor` and `has_next_page` for pagination state
- `status` parameter for filtering by Status field value (case-insensitive)

## Future Considerations

- Add `github_create_repository` tool
- Add `github_delete_repository` tool
- Add rate limit checking (X-RateLimit-Remaining header)
- Add branch protection API tools
- Add `github_project_remove_item` tool (deletes item from project)
- Add `github_project_create_status_update` tool
