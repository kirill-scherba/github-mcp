# Context: github-mcp

## What is github-mcp?

GitHub MCP server extracted from [ai-hub](https://github.com/kirill-scherba/ai-hub) into a dedicated standalone server. Provides 28 GitHub API tools (18 REST + 10 GraphQL) via MCP protocol.

## Why it exists

ai-hub grew too large — mixing utility tools, MCP hub, and GitHub API in one codebase. The GitHub tools required a `GITHUB_TOKEN` hardcoded in the Perl script, which was problematic for security and deployment. Extracting into a separate MCP server:

- Clean separation of concerns
- Environment-based auth (no hardcoded tokens)
- Standalone deployment
- No Safe sandbox restrictions

## Repository

- **URL:** <https://github.com/kirill-scherba/github-mcp>
- **Language:** Perl (single file: `github-mcp.pl`)
- **Protocol:** MCP over stdin/stdout (JSON-RPC 2.0)
- **Auth:** `GITHUB_TOKEN` environment variable

## Tools (28)

| # | Tool | Purpose |
| --- | ------ | --------- |
| 1 | `github_issue_create` | Create issue |
| 2 | `github_issue_list` | List issues — supports single repo (string) or multiple repos (array) |
| 3 | `github_issue_get` | Get issue details |
| 4 | `github_issue_update` | Update issue |
| 5 | `github_issue_add_comment` | Add comment |
| 6 | `github_issue_list_comments` | List comments |
| 7 | `github_get_file` | Get file content |
| 8 | `github_create_or_update_file` | Create/update file |
| 9 | `github_search_issues` | Search issues |
| 10 | `github_search_code` | Search code |
| 11 | `github_list_labels` | List labels |
| 12 | `github_list_repos` | List repos |
| 13 | `github_project_list` | List GitHub Projects V2 for user/org |
| 14 | `github_project_get` | Get Project V2 details |
| 15 | `github_project_create` | Create Project V2 |
| 16 | `github_project_update` | Update Project V2 settings |
| 17 | `github_project_delete` | Delete Project V2 |
| 18 | `github_project_list_fields` | List fields in a Project V2 |
| 19 | `github_project_list_items` | List items (issues/PRs) in a Project V2 |
| 20 | `github_project_add_item` | Add existing issue/PR to a Project V2 |
| 21 | `github_project_update_item` | Update field value on a Project V2 item |
| 22 | `github_project_create_draft` | Create a draft issue in a Project V2 |
| 23 | `github_pull_request_get` | Get PR metadata (title, author, base/head, draft, mergeable, stats) |
| 24 | `github_pull_request_list` | List PRs with filters (state, head, base, sort) |
| 25 | `github_pull_request_get_files` | Get changed files with patch snippets |
| 26 | `github_pull_request_list_reviews` | List reviews and line-level review comments |
| 27 | `github_pull_request_create_review` | Create a review (APPROVE/REQUEST_CHANGES/COMMENT) |
| 28 | `github_pull_request_create` | Create a pull request (owner, repo, title, head, base, optional body/draft) |

## History

- **2026-05-09:** Extracted from ai-hub commit `3e366ce`. Created as standalone repo with `github-mcp.pl`.
- **2026-05-09:** Removed GitHub tools from ai-hub (commit `b0bce45`).
- **2026-05-09:** Added README.md, docs/, .gitignore.
- **2026-05-11:** `github_issue_list` now accepts array of repos — single call across all projects.
- **2026-05-21:** Added GitHub Projects V2 support (10 tools via GraphQL API, including draft issue creation).
- **2026-05-21:** Discovered GITHUB_TOKEN lacks `read:project` scope — Projects V2 tools blocked until token is regenerated with `read:project` + `write:project`.
- **2026-05-23:** Added 5 Pull Request tools (get, list, files, reviews, create review). Updated README with token scopes documentation and graceful degradation for write operations.
- **2026-05-23:** Added `github_pull_request_create` tool (#6) — full PR creation via MCP without bash/curl workarounds.
