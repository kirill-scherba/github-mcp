#!/usr/bin/env perl
# =============================================================================
# github-mcp — Standalone MCP server for GitHub API tools
#
# Repository: github.com/kirill-scherba/github-mcp
#
# Features:
#   - 12 GitHub API tools (issues, files, search, repos, labels)
#   - Direct GITHUB_TOKEN from environment (no Safe sandbox limitations)
#   - JSON-RPC 2.0 over stdin/stdout (MCP protocol)
#   - Detailed logging to stderr
# =============================================================================

use strict;
use warnings;
use utf8;
use JSON;
use POSIX qw(strftime);
use MIME::Base64;

use English '-no_match_vars';

# ---------------------------------------------------------------------------
# UTF-8 encoding
# ---------------------------------------------------------------------------
binmode(STDIN,  ":utf8");
binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
my $GITHUB_TOKEN = $ENV{GITHUB_TOKEN} // '';
log_message("INFO", "GITHUB_TOKEN " . ($GITHUB_TOKEN ? 'found' : 'NOT found'));

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
sub log_message {
    my ($level, $message) = @_;
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[$timestamp] [$level] $message\n";
    STDERR->flush();
}

# ---------------------------------------------------------------------------
# JSON-RPC helpers
# ---------------------------------------------------------------------------
my $json = JSON->new->allow_nonref;

sub respond {
    my ($id, $result) = @_;
    my $response = { jsonrpc => "2.0", id => $id, result => $result };
    print $json->encode($response) . "\n";
    STDOUT->flush();
}

sub respond_error {
    my ($id, $code, $message, $data) = @_;
    my $error = { code => $code, message => $message };
    $error->{data} = $data if defined $data;
    my $response = { jsonrpc => "2.0", id => $id, error => $error };
    print $json->encode($response) . "\n";
    STDOUT->flush();
}

sub send_notification {
    my ($method, $params) = @_;
    my $notification = { jsonrpc => "2.0", method => $method };
    $notification->{params} = $params if defined $params;
    print $json->encode($notification) . "\n";
    STDOUT->flush();
    log_message("INFO", "Notification: $method");
}

our $json_pp_decoder = JSON->new->allow_nonref;

# ---------------------------------------------------------------------------
# GitHub API helper
# ---------------------------------------------------------------------------
# Calls GitHub REST API, returns { success, status, data, reason }.
# Auth from $GITHUB_TOKEN (environment variable).
# ---------------------------------------------------------------------------
sub _github_api {
    my ($method, $path, $body) = @_;
    $method = uc($method // 'GET');
    $path   //= '/';
    my $token = $GITHUB_TOKEN;
    my $url = "https://api.github.com$path";

    log_message("DEBUG", "_github_api: $method $url");

    my $body_arg = '';
    my $header_arg = '-s';
    if (defined $body) {
        my $tmp = "/tmp/_github_body_$$.json";
        open(my $fh, '>', $tmp) or return { success => 0, status => 0, reason => "Cannot write temp file: $!" };
        print $fh $body;
        close $fh;
        $body_arg = "--data-binary \@'$tmp'";
    }
    if ($token) {
        $header_arg .= " -H 'Authorization: Bearer $token' -H 'Accept: application/vnd.github+json' -H 'User-Agent: github-mcp/1.0'";
    }
    $header_arg .= ' -H ' . (defined $body ? "'Content-Type: application/json'" : "'Accept: application/vnd.github+json'");

    my $result = `curl -s -w '%{http_code}' -X $method $header_arg $body_arg --connect-timeout 10 --max-time 30 '$url' 2>/dev/null`;
    unlink "/tmp/_github_body_$$.json" if defined $body && -f "/tmp/_github_body_$$.json";

    my $http_code = '';
    if (length($result) >= 3) {
        $http_code = substr($result, -3, 3);
        $result = substr($result, 0, -3);
    }
    $http_code =~ s/\s+//g;
    log_message("DEBUG", "_github_api: HTTP $http_code, response_len=" . length($result));

    my $data = eval { $json_pp_decoder->decode($result) };
    if ($@) {
        return { success => ($http_code =~ /^2/ ? 1 : 0), status => $http_code, reason => "JSON decode error: $@" };
    }

    return { success => ($http_code =~ /^2/ ? 1 : 0), status => $http_code, data => $data };
}

# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

# 1. github_issue_create
sub tool_github_issue_create {
    my ($args) = @_;
    my $owner    = $args->{owner}    or die "Missing required: owner";
    my $repo     = $args->{repo}     or die "Missing required: repo";
    my $title    = $args->{title}    or die "Missing required: title";
    my $body     = $args->{body}     // '';
    my $labels   = $args->{labels}   // undef;
    my $assignees = $args->{assignees} // undef;

    my %payload = (title => $title, body => $body);
    $payload{labels}    = $labels    if $labels;
    $payload{assignees} = $assignees if $assignees;

    my $body_str = $json->encode(\%payload);
    my $res = _github_api("POST", "/repos/$owner/$repo/issues", $body_str);

    if ($res->{success}) {
        my $issue = $res->{data};
        return {
            issue_number => $issue->{number},
            issue_url    => $issue->{html_url},
            state        => $issue->{state},
            title        => $issue->{title},
            created_at   => $issue->{created_at},
        };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 2. github_issue_list - single or multiple repositories
sub tool_github_issue_list {
    my ($args) = @_;
    my $owner  = $args->{owner}  or die "Missing required: owner";
    my $repo   = $args->{repo}   or die "Missing required: repo";
    my $state  = $args->{state}  // "open";
    my $labels = $args->{labels} // undef;
    my $limit  = $args->{limit}  // 30;

    # Normalize repo to an array (single string or array ref)
    my @repos = ref $repo eq 'ARRAY' ? @$repo : ($repo);

    my @all_issues;
    REPO: for my $r (@repos) {
        my $path = "/repos/$owner/$r/issues?state=$state&per_page=$limit&sort=created&direction=desc";
        $path .= "&labels=" . join(",", ref $labels ? @$labels : ($labels)) if $labels;

        my $res = _github_api("GET", $path);
        unless ($res->{success}) {
            log_message("WARN", "github_issue_list: error for $owner/$r: " . ($res->{reason} // "HTTP $res->{status}"));
            next REPO;
        }

        for my $issue (@{$res->{data} // []}) {
            push @all_issues, {
                number     => $issue->{number},
                title      => $issue->{title},
                state      => $issue->{state},
                url        => $issue->{html_url},
                labels     => [map { $_->{name} } @{$issue->{labels} // []}],
                repo       => $r,
                created_at => $issue->{created_at},
                updated_at => $issue->{updated_at},
            };
        }
    }
    return { issues => \@all_issues, count => scalar @all_issues };
}

# 3. github_issue_get
sub tool_github_issue_get {
    my ($args) = @_;
    my $owner  = $args->{owner}  or die "Missing required: owner";
    my $repo   = $args->{repo}   or die "Missing required: repo";
    my $number = $args->{issue_number} or die "Missing required: issue_number";

    my $res = _github_api("GET", "/repos/$owner/$repo/issues/$number");
    if ($res->{success}) {
        my $issue = $res->{data};
        return {
            number         => $issue->{number},
            title          => $issue->{title},
            body           => $issue->{body} // '',
            state          => $issue->{state},
            url            => $issue->{html_url},
            labels         => [map { $_->{name} } @{$issue->{labels} // []}],
            assignees      => [map { $_->{login} } @{$issue->{assignees} // []}],
            created_at     => $issue->{created_at},
            updated_at     => $issue->{updated_at},
            closed_at      => $issue->{closed_at} // undef,
            comments_count => $issue->{comments} // 0,
        };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 4. github_issue_update
sub tool_github_issue_update {
    my ($args) = @_;
    my $owner    = $args->{owner}    or die "Missing required: owner";
    my $repo     = $args->{repo}     or die "Missing required: repo";
    my $number   = $args->{issue_number} or die "Missing required: issue_number";

    my %payload;
    $payload{title}     = $args->{title}     if defined $args->{title};
    $payload{body}      = $args->{body}      if defined $args->{body};
    $payload{state}     = $args->{state}     if defined $args->{state};
    $payload{labels}    = $args->{labels}    if defined $args->{labels};
    $payload{assignees} = $args->{assignees} if defined $args->{assignees};

    die "Nothing to update" unless scalar keys %payload;

    my $body_str = $json->encode(\%payload);
    my $res = _github_api("PATCH", "/repos/$owner/$repo/issues/$number", $body_str);
    if ($res->{success}) {
        return {
            issue_number => $res->{data}{number},
            title        => $res->{data}{title},
            state        => $res->{data}{state},
            updated_at   => $res->{data}{updated_at},
        };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 5. github_issue_add_comment
sub tool_github_issue_add_comment {
    my ($args) = @_;
    my $owner  = $args->{owner}  or die "Missing required: owner";
    my $repo   = $args->{repo}   or die "Missing required: repo";
    my $number = $args->{issue_number} or die "Missing required: issue_number";
    my $body   = $args->{body}   or die "Missing required: body";

    my $body_str = $json->encode({ body => $body });
    my $res = _github_api("POST", "/repos/$owner/$repo/issues/$number/comments", $body_str);
    if ($res->{success}) {
        return {
            comment_id  => $res->{data}{id},
            comment_url => $res->{data}{html_url},
            created_at  => $res->{data}{created_at},
        };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 6. github_issue_list_comments
sub tool_github_issue_list_comments {
    my ($args) = @_;
    my $owner  = $args->{owner}  or die "Missing required: owner";
    my $repo   = $args->{repo}   or die "Missing required: repo";
    my $number = $args->{issue_number} or die "Missing required: issue_number";
    my $limit  = $args->{limit}  // 30;

    my $path = "/repos/$owner/$repo/issues/$number/comments?per_page=$limit&sort=created&direction=desc";
    my $res = _github_api("GET", $path);
    if ($res->{success}) {
        my @comments;
        for my $c (@{$res->{data} // []}) {
            push @comments, {
                id         => $c->{id},
                body       => $c->{body} // '',
                author     => $c->{user}{login},
                created_at => $c->{created_at},
                updated_at => $c->{updated_at},
            };
        }
        return { comments => \@comments, count => scalar @comments };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 7. github_get_file
sub tool_github_get_file {
    my ($args) = @_;
    my $owner = $args->{owner} or die "Missing required: owner";
    my $repo  = $args->{repo}  or die "Missing required: repo";
    my $path  = $args->{path}  or die "Missing required: path";
    my $ref   = $args->{ref}   // undef;

    my $api_path = "/repos/$owner/$repo/contents/$path";
    $api_path .= "?ref=$ref" if $ref;

    my $res = _github_api("GET", $api_path);
    if ($res->{success}) {
        my $data = $res->{data};
        my $content = '';
        my $size = 0;
        if ($data->{encoding} && $data->{encoding} eq 'base64') {
            my $decoded = decode_base64($data->{content});
            utf8::decode($decoded);
            $content = $decoded;
            $size = length($content);
        }
        return {
            name         => $data->{name},
            path         => $data->{path},
            size         => $size,
            sha          => $data->{sha},
            encoding     => $data->{encoding} // '',
            content      => $content,
            download_url => $data->{download_url} // '',
            html_url     => $data->{html_url} // '',
        };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 8. github_create_or_update_file
sub tool_github_create_or_update_file {
    my ($args) = @_;
    my $owner   = $args->{owner}   or die "Missing required: owner";
    my $repo    = $args->{repo}    or die "Missing required: repo";
    my $path    = $args->{path}    or die "Missing required: path";
    my $content = $args->{content} // '';
    my $message = $args->{message} // "Update $path via github-mcp";
    my $branch  = $args->{branch}  // undef;
    my $sha     = $args->{sha}     // undef;

    my $encoded = encode_base64($content, '');
    my %payload = (message => $message, content => $encoded);
    $payload{branch} = $branch if $branch;
    $payload{sha}    = $sha    if $sha;

    my $body_str = $json->encode(\%payload);
    my $res = _github_api("PUT", "/repos/$owner/$repo/contents/$path", $body_str);
    if ($res->{success}) {
        return {
            path       => $res->{data}{content}{path} // $path,
            sha        => $res->{data}{content}{sha} // '',
            commit_sha => $res->{data}{commit}{sha} // '',
            commit_url => $res->{data}{commit}{html_url} // '',
        };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 9. github_search_issues
sub tool_github_search_issues {
    my ($args) = @_;
    my $query = $args->{query} or die "Missing required: query";
    my $limit = $args->{limit} // 10;
    my $repo  = $args->{repo}  // undef;

    my $q = $query;
    $q = "repo:$repo $q" if $repo;
    $q =~ s/ /+/g;

    my $path = "/search/issues?q=$q&per_page=$limit&sort=created&order=desc";
    my $res = _github_api("GET", $path);
    if ($res->{success}) {
        my @issues;
        for my $issue (@{$res->{data}{items} // []}) {
            push @issues, {
                number     => $issue->{number},
                title      => $issue->{title},
                state      => $issue->{state},
                repo       => ($issue->{repository_url} =~ m|/repos/(.+)$| ? $1 : ''),
                url        => $issue->{html_url},
                labels     => [map { $_->{name} } @{$issue->{labels} // []}],
                created_at => $issue->{created_at},
                updated_at => $issue->{updated_at},
            };
        }
        return { issues => \@issues, total_count => ($res->{data}{total_count} // 0), count => scalar @issues };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 10. github_search_code
sub tool_github_search_code {
    my ($args) = @_;
    my $query    = $args->{query}    or die "Missing required: query";
    my $limit    = $args->{limit}    // 10;
    my $repo     = $args->{repo}     // undef;
    my $language = $args->{language} // undef;

    my $q = $query;
    $q = "repo:$repo $q" if $repo;
    $q = "$q+language:$language" if $language;
    $q =~ s/ /+/g;

    my $path = "/search/code?q=$q&per_page=$limit";
    my $res = _github_api("GET", $path);
    if ($res->{success}) {
        my @results;
        for my $item (@{$res->{data}{items} // []}) {
            push @results, {
                name     => $item->{name},
                path     => $item->{path},
                repo     => ($item->{repository}{full_name} // ''),
                html_url => $item->{html_url},
                git_url  => $item->{git_url},
            };
        }
        return { results => \@results, total_count => ($res->{data}{total_count} // 0), count => scalar @results };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 11. github_list_labels
sub tool_github_list_labels {
    my ($args) = @_;
    my $owner = $args->{owner} or die "Missing required: owner";
    my $repo  = $args->{repo}  or die "Missing required: repo";

    my $res = _github_api("GET", "/repos/$owner/$repo/labels?per_page=100");
    if ($res->{success}) {
        my @labels;
        for my $label (@{$res->{data} // []}) {
            push @labels, {
                name        => $label->{name},
                color       => $label->{color},
                description => $label->{description} // '',
                default     => $label->{default} // 0,
            };
        }
        return { labels => \@labels, count => scalar @labels };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 12. github_list_repos
sub tool_github_list_repos {
    my ($args) = @_;
    my $type  = $args->{type}  // 'owner';
    my $org   = $args->{org}   // undef;
    my $limit = $args->{limit} // 30;

    my $path;
    if ($org) {
        $path = "/orgs/$org/repos?type=$type&per_page=$limit&sort=updated&direction=desc";
    } else {
        $path = "/user/repos?type=$type&per_page=$limit&sort=updated&direction=desc";
    }

    my $res = _github_api("GET", $path);
    if ($res->{success}) {
        my @repos;
        for my $repo (@{$res->{data} // []}) {
            push @repos, {
                full_name   => $repo->{full_name},
                description => $repo->{description} // '',
                private     => $repo->{private} // 0,
                html_url    => $repo->{html_url},
                language    => $repo->{language} // '',
                stars       => $repo->{stargazers_count} // 0,
                forks       => $repo->{forks_count} // 0,
                open_issues => $repo->{open_issues_count} // 0,
                updated_at  => $repo->{updated_at},
            };
        }
        return { repositories => \@repos, count => scalar @repos };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# ---------------------------------------------------------------------------
# Tool definitions for tools/list
# ---------------------------------------------------------------------------
my %tool_handlers = (
    github_issue_create => {
        description => "Create a new GitHub issue in a repository",
        handler     => \&tool_github_issue_create,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "title"],
            properties => {
                owner      => { type => "string", description => "Repository owner (user or org)" },
                repo       => { type => "string", description => "Repository name" },
                title      => { type => "string", description => "Issue title" },
                body       => { type => "string", description => "Issue body text (optional)" },
                labels     => { type => "array",  items => { type => "string" }, description => "Label names (optional)" },
                assignees  => { type => "array",  items => { type => "string" }, description => "Usernames to assign (optional)" },
            },
        },
    },
    github_issue_list => {
        description => "List GitHub issues in repositories with optional filters. Accept single repo (string) or multiple repos (array).",
        handler     => \&tool_github_issue_list,
        inputSchema => {
            type => "object",
            required => ["owner", "repo"],
            properties => {
                owner  => { type => "string", description => "Repository owner (user or org)" },
                repo   => { oneOf => [
                    { type => "string", description => "Single repository name" },
                    { type => "array",  items => { type => "string" }, description => "Array of repository names" },
                ], description => "Repository name, or array of repository names" },
                state  => { type => "string", description => "Issue state: open, closed, all (default: open)" },
                labels => { type => "string", description => "Comma-separated label names (optional)" },
                limit  => { type => "number", description => "Max results per repo (default: 30)" },
            },
        },
    },
    github_issue_get => {
        description => "Get details of a specific GitHub issue",
        handler     => \&tool_github_issue_get,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "issue_number"],
            properties => {
                owner        => { type => "string", description => "Repository owner (user or org)" },
                repo         => { type => "string", description => "Repository name" },
                issue_number => { type => "number", description => "Issue number" },
            },
        },
    },
    github_issue_update => {
        description => "Update a GitHub issue (title, body, state, labels, assignees)",
        handler     => \&tool_github_issue_update,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "issue_number"],
            properties => {
                owner        => { type => "string", description => "Repository owner (user or org)" },
                repo         => { type => "string", description => "Repository name" },
                issue_number => { type => "number", description => "Issue number" },
                title        => { type => "string", description => "New title (optional)" },
                body         => { type => "string", description => "New body text (optional)" },
                state        => { type => "string", description => "New state: open or closed (optional)" },
                labels       => { type => "array",  items => { type => "string" }, description => "New labels array (optional)" },
                assignees    => { type => "array",  items => { type => "string" }, description => "New assignees array (optional)" },
            },
        },
    },
    github_issue_add_comment => {
        description => "Add a comment to a GitHub issue",
        handler     => \&tool_github_issue_add_comment,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "issue_number", "body"],
            properties => {
                owner        => { type => "string", description => "Repository owner (user or org)" },
                repo         => { type => "string", description => "Repository name" },
                issue_number => { type => "number", description => "Issue number" },
                body         => { type => "string", description => "Comment body text" },
            },
        },
    },
    github_issue_list_comments => {
        description => "List comments on a GitHub issue",
        handler     => \&tool_github_issue_list_comments,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "issue_number"],
            properties => {
                owner        => { type => "string", description => "Repository owner (user or org)" },
                repo         => { type => "string", description => "Repository name" },
                issue_number => { type => "number", description => "Issue number" },
                limit        => { type => "number", description => "Max results (default: 30)" },
            },
        },
    },
    github_get_file => {
        description => "Get file contents from a GitHub repository",
        handler     => \&tool_github_get_file,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "path"],
            properties => {
                owner => { type => "string", description => "Repository owner (user or org)" },
                repo  => { type => "string", description => "Repository name" },
                path  => { type => "string", description => "File path in repository" },
                ref   => { type => "string", description => "Branch name or commit SHA (optional, defaults to default branch)" },
            },
        },
    },
    github_create_or_update_file => {
        description => "Create or update a file in a GitHub repository",
        handler     => \&tool_github_create_or_update_file,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "path", "content"],
            properties => {
                owner   => { type => "string", description => "Repository owner (user or org)" },
                repo    => { type => "string", description => "Repository name" },
                path    => { type => "string", description => "File path to create/update" },
                content => { type => "string", description => "File content (text)" },
                message => { type => "string", description => "Commit message (optional)" },
                branch  => { type => "string", description => "Branch name (optional, defaults to default branch)" },
                sha     => { type => "string", description => "File SHA (required for update, optional for create)" },
            },
        },
    },
    github_search_issues => {
        description => "Search GitHub issues and pull requests",
        handler     => \&tool_github_search_issues,
        inputSchema => {
            type => "object",
            required => ["query"],
            properties => {
                query => { type => "string", description => "Search query (GitHub search syntax)" },
                limit => { type => "number", description => "Max results (default: 10)" },
                repo  => { type => "string", description => "Optional: limit search to repo (owner/name)" },
            },
        },
    },
    github_search_code => {
        description => "Search code across GitHub repositories",
        handler     => \&tool_github_search_code,
        inputSchema => {
            type => "object",
            required => ["query"],
            properties => {
                query    => { type => "string", description => "Search query (GitHub search syntax)" },
                limit    => { type => "number", description => "Max results (default: 10)" },
                repo     => { type => "string", description => "Optional: limit search to repo (owner/name)" },
                language => { type => "string", description => "Optional: filter by language (e.g. Perl, Go, Python)" },
            },
        },
    },
    github_list_labels => {
        description => "List labels in a GitHub repository",
        handler     => \&tool_github_list_labels,
        inputSchema => {
            type => "object",
            required => ["owner", "repo"],
            properties => {
                owner => { type => "string", description => "Repository owner (user or org)" },
                repo  => { type => "string", description => "Repository name" },
            },
        },
    },
    github_list_repos => {
        description => "List GitHub repositories for a user or organization",
        handler     => \&tool_github_list_repos,
        inputSchema => {
            type => "object",
            required => [],
            properties => {
                type  => { type => "string", description => "Type: owner, public, private, all (default: owner)" },
                org   => { type => "string", description => "Organization name (optional, omit for user repos)" },
                limit => { type => "number", description => "Max results (default: 30)" },
            },
        },
    },
);

# ---------------------------------------------------------------------------
# MCP Main Loop
# ---------------------------------------------------------------------------

log_message("INFO", "github-mcp server started");


LINE: while (my $line = <STDIN>) {
    chomp $line;
    next LINE unless $line && $line =~ /\S/;

    log_message("DEBUG", "Received: $line");

    my $msg = eval { $json->decode($line) };
    if ($@ || !$msg) {
        log_message("ERROR", "Invalid JSON-RPC message: $@");
        next LINE;
    }

    my $id     = $msg->{id};
    my $method = $msg->{method} // '';
    my $params = $msg->{params} // {};

    # Handle notifications (no id)
    if (!defined $id) {
        log_message("INFO", "Received notification: $method");
        next LINE;
    }

    if ($method eq 'initialize') {
        respond($id, {
            protocolVersion => '2024-11-05',
            capabilities    => { tools => {} },
            serverInfo      => {
                name    => 'github-mcp',
                version => '1.0.0',
            },
        });
        log_message("INFO", "Initialized");
    }
    elsif ($method eq 'ping') {
        respond($id, {});
    }
    elsif ($method eq 'tools/list') {
        my @tool_defs;
        for my $name (sort keys %tool_handlers) {
            push @tool_defs, {
                name        => $name,
                description => $tool_handlers{$name}{description},
                inputSchema => $tool_handlers{$name}{inputSchema},
            };
        }
        respond($id, { tools => \@tool_defs });
        log_message("INFO", "Sent tool list (" . scalar(@tool_defs) . " tools)");
    }
    elsif ($method eq 'tools/call') {
        my $tool_name = $params->{name} // '';
        my $tool_args = $params->{arguments} // {};

        unless (exists $tool_handlers{$tool_name}) {
            respond_error($id, -32601, "Method not found: tool '$tool_name' not found");
            next LINE;
        }

        log_message("INFO", "Executing tool: $tool_name");

        eval {
            my $result = $tool_handlers{$tool_name}{handler}->($tool_args);
            log_message("INFO", "Tool '$tool_name' execution successful");
            respond($id, {
                content => [
                    {
                        type => "text",
                        text => $json->encode($result),
                    },
                ],
            });
        };
        if ($@) {
            my $error_msg = $@;
            chomp $error_msg;
            log_message("ERROR", "Tool '$tool_name' execution error: $error_msg");
            respond_error($id, -32603, "Internal error: $error_msg");
        }
    }
    elsif ($method eq "resources/list") {
        respond($id, { resources => [] });
        log_message("INFO", "Sent empty resource list");
    }
    elsif ($method eq "prompts/list") {
        respond($id, { prompts => [] });
        log_message("INFO", "Sent empty prompt list");
    }
    else {
        log_message("WARN", "Unknown method: $method");
        respond_error($id, -32601, "Method not found: $method");
    }
}

