# Context: github-mcp

## What is github-mcp?

PostgreSQL MCP server extracted from [ai-hub](https://github.com/kirill-scherba/ai-hub) into a dedicated standalone server. Provides 12 GitHub API tools via MCP protocol.

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

## Tools (12)

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

## History

- **2026-05-09:** Extracted from ai-hub commit `3e366ce`. Created as standalone repo with `github-mcp.pl`.
- **2026-05-09:** Removed GitHub tools from ai-hub (commit `b0bce45`).
- **2026-05-09:** Added README.md, docs/, .gitignore.
- **2026-05-11:** `github_issue_list` now accepts array of repos — single call across all projects.
