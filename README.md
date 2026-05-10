# github-mcp

[![Perl](https://img.shields.io/badge/perl-5.40+-blue.svg)](https://www.perl.org/)
[![MCP](https://img.shields.io/badge/MCP-2024--11--05-green.svg)](https://modelcontextprotocol.io)
[![License](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

> **Standalone MCP server for GitHub API — 12 tools for issues, files, search, labels, and repositories.**

Extracted from [ai-hub](https://github.com/kirill-scherba/ai-hub) into a dedicated MCP server for better separation of concerns. Uses direct `GITHUB_TOKEN` from environment — no sandbox limitations, full GitHub API access.

## Features

- **12 GitHub API tools** — issues (CRUD + comments + list), files (get, create/update), search (issues, code), labels (list), repositories (list)
- **Direct authentication** — `GITHUB_TOKEN` from environment variable, no Safe sandbox limitations
- **Clean JSON-RPC 2.0** — MCP protocol over stdin/stdout
- **Structured logging** — all logs to stderr, stdout clean for JSON-RPC
- **Zero external dependencies** — `perl`, `JSON`, `MIME::Base64` (core), and `curl` are all you need

## Tools

| Tool | Description |
|------|-------------|
| `github_issue_create` | Create a new issue |
| `github_issue_list` | List issues with filters |
| `github_issue_get` | Get issue details |
| `github_issue_update` | Update issue (title, body, state, labels, assignees) |
| `github_issue_add_comment` | Add a comment to an issue |
| `github_issue_list_comments` | List comments on an issue |
| `github_get_file` | Get file contents from a repository |
| `github_create_or_update_file` | Create or update a file |
| `github_search_issues` | Search issues and pull requests |
| `github_search_code` | Search code across repositories |
| `github_list_labels` | List labels in a repository |
| `github_list_repos` | List repositories for a user or org |

## Installation

### Prerequisites

```bash
# Perl modules (JSON is in core since 5.38+)
# curl for GitHub API calls
sudo apt install curl   # Debian/Ubuntu
sudo pacman -S curl     # Arch Linux
```

### Setup

1. Clone the repository:

```bash
git clone https://github.com/kirill-scherba/github-mcp.git
cd github-mcp
chmod +x github-mcp.pl
```

2. Set your GitHub token:

```bash
export GITHUB_TOKEN="github_pat_..."
```

3. Add to your MCP settings:

```json
{
  "mcpServers": {
    "github-mcp": {
      "command": "perl",
      "args": ["/path/to/github-mcp/github-mcp.pl"],
      "env": {
        "GITHUB_TOKEN": "github_pat_..."
      },
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

## Usage

### Create an Issue

```json
{
  "owner": "kirill-scherba",
  "repo": "memory-store-mcp",
  "title": "Test task: MCP integration check",
  "body": "Created via github-mcp MCP server",
  "labels": ["test"]
}
```

### List Issues

```json
{
  "owner": "kirill-scherba",
  "repo": "memory-store-mcp",
  "state": "open",
  "limit": 10
}
```

### Get File Contents

```json
{
  "owner": "kirill-scherba",
  "repo": "github-mcp",
  "path": "github-mcp.pl",
  "ref": "main"
}
```

### Search Code

```json
{
  "query": "github_issue_create",
  "repo": "kirill-scherba/github-mcp",
  "language": "Perl"
}
```

### Search Issues

```json
{
  "query": "bug authentication",
  "repo": "kirill-scherba/memory-store-mcp"
}
```

### List Repositories

```json
{
  "type": "owner",
  "limit": 30
}
```

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      MCP Client (AI)                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │initialize│  │tools/list│  │tools/call│  │tools/call│ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘ │
│       │             │             │             │        │
│       ▼             ▼             ▼             ▼        │
│              JSON-RPC 2.0 over stdin/stdout              │
└──────────────────────────┬───────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────┐
│                   github-mcp (Perl)                       │
│                                                           │
│  ┌──────────┐   ┌──────────────┐   ┌──────────────────┐  │
│  │ MCP Main │──>│  Request      │──>│  GitHub REST API │  │
│  │ Loop     │   │  Dispatcher   │   │  via curl        │  │
│  │          │   │              │   │                  │  │
│  │ while    │   │ • 12 tools   │   │  + auth via      │  │
│  │ <STDIN>  │   │ • JSON-RPC   │   │  GITHUB_TOKEN    │  │
│  │          │   │ • structured  │   │                  │  │
│  │          │   │   responses  │   │                  │  │
│  └──────────┘   └──────────────┘   └──────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## Why Separate from ai-hub?

| Aspect | ai-hub (before) | github-mcp (now) |
|--------|----------------|-------------------|
| Auth | Hardcoded `GITHUB_TOKEN` in `our` variable | Environment variable, clean |
| Sandbox | Safe sandbox — GitHub API restricted | Direct curl, no restrictions |
| Surface area | 6 GitHub + 10 util tools = 16 | 12 GitHub-only tools, focused |
| Dependency | ai-hub needs both | Standalone, independent |
| Deployment | Full ai-hub server | Single-file Perl script |

## Protocol

This server implements the **Model Context Protocol (MCP)** using **JSON-RPC 2.0** over stdin/stdout.

| Method | Description |
|--------|-------------|
| `initialize` | Handshake with protocol version and capabilities |
| `ping` | Health check |
| `tools/list` | Returns all 12 tool definitions with JSON Schema |
| `tools/call` | Executes a tool by name with provided arguments |

All logging goes to **stderr**, leaving **stdout** clean for JSON-RPC messages.

## Quick Test

```bash
cd /path/to/github-mcp
export GITHUB_TOKEN="github_pat_..."

# Test initialization
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' | perl github-mcp.pl 2>/dev/null

# Full test sequence
printf '{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"github_list_repos","arguments":{"type":"owner","limit":5}}}
' | perl github-mcp.pl 2>/dev/null
```

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

## License

MIT © Kirill Scherba

---

*Built with 🐪 — standalone GitHub MCP server in pure Perl.*