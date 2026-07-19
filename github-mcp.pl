#!/usr/bin/env perl
# =============================================================================
# github-mcp — Standalone MCP server for GitHub API tools
#
# Repository: github.com/kirill-scherba/github-mcp
#
# Features:
#   - 34 GitHub API tools (issues, PRs, files, search, repos, labels, projects)
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
# GitHub API helpers
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

    my $success = $http_code =~ /^2/;
    if (!$success && ref $data eq 'HASH') {
        # Extract GitHub API error details from response body
        my $reason = $data->{message} // "HTTP $http_code";
        if ($data->{errors} && ref $data->{errors} eq 'ARRAY') {
            my @msgs = map { ref $_ eq 'HASH' ? ($_->{message} // $_->{code} // '') : ($_ // '') } @{$data->{errors}};
            $reason .= ': ' . join('; ', grep { $_ } @msgs) if @msgs;
        }
        return { success => 0, status => $http_code, data => $data, reason => $reason };
    }
    return { success => ($success ? 1 : 0), status => $http_code, data => $data };
}

# ---------------------------------------------------------------------------
# Calls GitHub GraphQL API, returns { success, data, errors, reason }.
# ---------------------------------------------------------------------------
sub _github_graphql {
    my ($query, $variables) = @_;
    my $token = $GITHUB_TOKEN;
    my $url = 'https://api.github.com/graphql';

    log_message("DEBUG", "_github_graphql: GraphQL query (len=" . length($query) . ")");

    my $payload = { query => $query };
    $payload->{variables} = $variables if $variables;
    my $body = $json->encode($payload);

    my $tmp = "/tmp/_github_gql_body_$$.json";
    open(my $fh, '>', $tmp) or return { success => 0, reason => "Cannot write temp file: $!" };
    print $fh $body;
    close $fh;

    my $cmd = "curl -s -X POST -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -H 'User-Agent: github-mcp/1.0' --connect-timeout 10 --max-time 30 --data-binary \@'$tmp' '$url' 2>/dev/null";
    my $result = `$cmd`;
    unlink $tmp if -f $tmp;

    my $data = eval { $json_pp_decoder->decode($result) };
    if ($@) {
        return { success => 0, reason => "GraphQL response decode error: $@" };
    }

    if ($data->{errors} && ref $data->{errors} eq 'ARRAY') {
        my @messages = map { $_->{message} } @{$data->{errors}};
        return { success => 0, errors => $data->{errors}, reason => "GraphQL error: " . join("; ", @messages) };
    }

    log_message("DEBUG", "_github_graphql: success");
    return { success => 1, data => $data->{data} };
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
    # DO NOT add labels here — use github_issue_add_labels / github_issue_remove_labels instead
    # $payload{labels} = $args->{labels} if defined $args->{labels};
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

# 4b. github_issue_add_labels
sub tool_github_issue_add_labels {
    my ($args) = @_;
    my $owner  = $args->{owner}        or die "Missing required: owner";
    my $repo   = $args->{repo}         or die "Missing required: repo";
    my $number = $args->{issue_number} or die "Missing required: issue_number";
    my $new_labels = $args->{labels}   or die "Missing required: labels";
    $new_labels = [ $new_labels ] unless ref $new_labels eq 'ARRAY';

    # Read current labels
    my $res = _github_api("GET", "/repos/$owner/$repo/issues/$number");
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}") unless $res->{success};
    my %current = map { $_ => 1 } map { $_->{name} } @{$res->{data}{labels} // []};

    # Add new labels (no duplicates)
    for my $l (@$new_labels) { $current{$l} = 1; }
    my @merged = sort keys %current;

    # Update via PATCH
    my $body_str = $json->encode({ labels => \@merged });
    my $upd = _github_api("PATCH", "/repos/$owner/$repo/issues/$number", $body_str);
    die "GitHub API error: " . ($upd->{reason} // "HTTP $upd->{status}") unless $upd->{success};

    return {
        added  => $new_labels,
        labels => [map { $_->{name} } @{$upd->{data}{labels} // []}],
    };
}

# 4c. github_issue_remove_labels
sub tool_github_issue_remove_labels {
    my ($args) = @_;
    my $owner  = $args->{owner}        or die "Missing required: owner";
    my $repo   = $args->{repo}         or die "Missing required: repo";
    my $number = $args->{issue_number} or die "Missing required: issue_number";
    my $remove_labels = $args->{labels} or die "Missing required: labels";
    $remove_labels = [ $remove_labels ] unless ref $remove_labels eq 'ARRAY';

    # Read current labels
    my $res = _github_api("GET", "/repos/$owner/$repo/issues/$number");
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}") unless $res->{success};

    # Build remove set (case-insensitive)
    my %remove = map { lc($_) => 1 } @$remove_labels;
    my @remaining = grep { !$remove{lc($_->{name})} } @{$res->{data}{labels} // []};
    my @remaining_names = map { $_->{name} } @remaining;

    # Update via PATCH
    my $body_str = $json->encode({ labels => \@remaining_names });
    my $upd = _github_api("PATCH", "/repos/$owner/$repo/issues/$number", $body_str);
    die "GitHub API error: " . ($upd->{reason} // "HTTP $upd->{status}") unless $upd->{success};

    return {
        removed => $remove_labels,
        labels  => [map { $_->{name} } @{$upd->{data}{labels} // []}],
    };
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
# Tool: github_repo_create
# ---------------------------------------------------------------------------
sub tool_github_repo_create {
    my ($args) = @_;
    my $name        = $args->{name}        or die "Missing required: name";
    my $description = $args->{description} // '';
    my $is_private  = $args->{private}     // 0;
    my $org         = $args->{org}         // undef;

    my $payload = { name => $name, description => $description, private => ($is_private ? JSON::true : JSON::false) };
    my $body = $json->encode($payload);

    my $path = $org ? "/orgs/$org/repos" : "/user/repos";
    my $res = _github_api("POST", $path, $body);
    if ($res->{success}) {
        my $r = $res->{data};
        return {
            full_name   => $r->{full_name},
            description => $r->{description} // '',
            private     => $r->{private} // 0,
            html_url    => $r->{html_url},
            clone_url   => $r->{clone_url},
            ssh_url     => $r->{ssh_url},
            git_url     => $r->{git_url},
        };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# ============================================================================
# GitHub Projects V2 Tools (GraphQL API)
# ============================================================================

# Helper: resolve owner login to type and node ID
sub _resolve_owner {
    my ($owner) = @_;
    # Try organization first
    my $res = _github_graphql(
        'query($login: String!) { organization(login: $login) { id } }',
        { login => $owner }
    );
    if ($res->{success} && $res->{data}{organization}{id}) {
        return ('organization', $res->{data}{organization}{id});
    }
    # Try user
    $res = _github_graphql(
        'query($login: String!) { user(login: $login) { id } }',
        { login => $owner }
    );
    if ($res->{success} && $res->{data}{user}{id}) {
        return ('user', $res->{data}{user}{id});
    }
    die "Could not resolve owner '$owner' to a user or organization";
}

# Helper: resolve status option ID for a given project and status name.
# Queries project Status field and finds the matching option by name (case-insensitive).
# Returns { field_id, option_id, option_name } on success.
sub _resolve_status_option_id {
    my ($owner, $project_number, $status_name) = @_;

    my $field = '';
    (my $t, undef) = _resolve_owner($owner);
    $field = $t;

    my $query = qq{
        query(\$owner: String!, \$number: Int!) {
            \$field(login: \$owner) {
                projectV2(number: \$number) {
                    field(name: "Status") {
                        ... on ProjectV2SingleSelectField {
                            id
                            options { id name }
                        }
                    }
                }
            }
        }
    };
    # Dynamically substitute field name since GraphQL doesn't support field name variables
    $query =~ s/\$field/$field/g;

    my $res = _github_graphql($query, { owner => $owner, number => $project_number });
    die "Failed to query project fields: " . ($res->{reason} // 'unknown') unless $res->{success};

    my $status_field = $res->{data}{$field}{projectV2}{field};
    die "Project #$project_number has no Status field" unless $status_field && $status_field->{options};

    my $field_id = $status_field->{id};
    my @options = @{$status_field->{options}};
    my ($matched) = grep { lc($_->{name}) eq lc($status_name) } @options;
    die "Status '$status_name' not found in project #$project_number (available: " . join(', ', map { $_->{name} } @options) . ")" unless $matched;

    return {
        field_id    => $field_id,
        option_id   => $matched->{id},
        option_name => $matched->{name},
    };
}

# Helper: resolve pull request GraphQL node ID by owner/repo/pull_number.
sub _resolve_pull_request_node_id {
    my ($owner, $repo, $pull_number) = @_;

    my $query = qq{
        query(\$owner: String!, \$repo: String!, \$number: Int!) {
            repository(owner: \$owner, name: \$repo) {
                pullRequest(number: \$number) {
                    id
                }
            }
        }
    };
    my $res = _github_graphql($query, {
        owner  => $owner,
        repo   => $repo,
        number => $pull_number,
    });
    die "Failed to resolve pull request node ID: " . ($res->{reason} // 'unknown') unless $res->{success};
    my $node_id = $res->{data}{repository}{pullRequest}{id};
    die "Pull request #$pull_number not found in $owner/$repo" unless $node_id;
    return $node_id;
}

# Helper: resolve issue GraphQL node ID by owner/repo/issue_number.
sub _resolve_issue_node_id {
    my ($owner, $repo, $issue_number) = @_;

    my $query = qq{
        query(\$owner: String!, \$repo: String!, \$number: Int!) {
            repository(owner: \$owner, name: \$repo) {
                issue(number: \$number) {
                    id
                }
            }
        }
    };
    my $res = _github_graphql($query, {
        owner  => $owner,
        repo   => $repo,
        number => $issue_number,
    });
    die "Failed to resolve issue node ID: " . ($res->{reason} // 'unknown') unless $res->{success};
    my $node_id = $res->{data}{repository}{issue}{id};
    die "Issue #$issue_number not found in $owner/$repo" unless $node_id;
    return $node_id;
}

# Helper: resolve project node ID by owner and project number.
sub _resolve_project_node_id {
    my ($owner, $project_number) = @_;

    my $field = '';
    (my $t, undef) = _resolve_owner($owner);
    $field = $t;

    my $query = qq{
        query(\$owner: String!, \$number: Int!) {
            \$field(login: \$owner) {
                projectV2(number: \$number) {
                    id
                }
            }
        }
    };
    $query =~ s/\$field/$field/g;

    my $res = _github_graphql($query, { owner => $owner, number => $project_number });
    die "Failed to resolve project node ID: " . ($res->{reason} // 'unknown') unless $res->{success};
    my $node_id = $res->{data}{$field}{projectV2}{id};
    die "Project #$project_number not found for owner '$owner'" unless $node_id;
    return $node_id;
}

# ============================================================================
# New Task/Project Helper Tools
# ============================================================================

# 30. github_resolve_issue_node_id — Resolve issue GraphQL node ID
sub tool_github_resolve_issue_node_id {
    my ($args) = @_;
    my $owner        = $args->{owner}        or die "Missing required: owner";
    my $repo         = $args->{repo}         or die "Missing required: repo";
    my $issue_number = $args->{issue_number} or die "Missing required: issue_number";

    my $node_id = _resolve_issue_node_id($owner, $repo, $issue_number);
    return {
        node_id     => $node_id,
        owner       => $owner,
        repo        => $repo,
        issue_number => $issue_number,
    };
}

# 31. github_project_add_issue — Add an existing issue to a GitHub Project V2
# by owner/repo/issue_number (no manual GraphQL node ID required).
sub tool_github_project_add_issue {
    my ($args) = @_;
    my $owner           = $args->{owner}           or die "Missing required: owner";
    my $repo            = $args->{repo}            or die "Missing required: repo";
    my $issue_number    = $args->{issue_number}    or die "Missing required: issue_number";
    my $project_owner   = $args->{project_owner}   // 'kirill-scherba';
    my $project_number  = $args->{project_number}  // 9;
    my $project_status  = $args->{project_status}  // 'Backlog';

    # Resolve issue node ID
    my $content_id = _resolve_issue_node_id($owner, $repo, $issue_number);

    # Resolve project node ID
    my $project_id = _resolve_project_node_id($project_owner, $project_number);

    # Preflight: validate status before adding to project (no side effect yet)
    my $status = _resolve_status_option_id($project_owner, $project_number, $project_status);

    # Add issue to project
    my $add_res = tool_github_project_add_item({
        project_id => $project_id,
        content_id => $content_id,
    });
    my $item_id = $add_res->{id};

    # Set project status
    tool_github_project_update_item({
        project_id => $project_id,
        item_id    => $item_id,
        field_id   => $status->{field_id},
        option_id  => $status->{option_id},
    });

    return {
        issue_url       => "https://github.com/$owner/$repo/issues/$issue_number",
        issue_number    => $issue_number,
        project_id      => $project_id,
        project_item_id => $item_id,
        project_owner   => $project_owner,
        project_number  => $project_number,
        project_status  => $status->{option_name},
    };
}

# 31b. github_project_add_pull_request — Add an existing pull request to a
# GitHub Project V2 by owner/repo/pull_number (no manual GraphQL node ID
# required).
sub tool_github_project_add_pull_request {
    my ($args) = @_;
    my $owner           = $args->{owner}           or die "Missing required: owner";
    my $repo            = $args->{repo}            or die "Missing required: repo";
    my $pull_number     = $args->{pull_number}     or die "Missing required: pull_number";
    my $project_owner   = $args->{project_owner}   // 'kirill-scherba';
    my $project_number  = $args->{project_number}  // 9;
    my $project_status  = $args->{project_status}  // 'In review';

    # Resolve pull request node ID
    my $content_id = _resolve_pull_request_node_id($owner, $repo, $pull_number);

    # Resolve project node ID
    my $project_id = _resolve_project_node_id($project_owner, $project_number);

    # Preflight: validate status before adding to project (no side effect yet)
    my $status = _resolve_status_option_id($project_owner, $project_number, $project_status);

    # Add pull request to project
    my $add_res = tool_github_project_add_item({
        project_id => $project_id,
        content_id => $content_id,
    });
    my $item_id = $add_res->{id};

    # Set project status
    tool_github_project_update_item({
        project_id => $project_id,
        item_id    => $item_id,
        field_id   => $status->{field_id},
        option_id  => $status->{option_id},
    });

    return {
        pr_url          => "https://github.com/$owner/$repo/pull/$pull_number",
        pull_number     => $pull_number,
        project_id      => $project_id,
        project_item_id => $item_id,
        project_owner   => $project_owner,
        project_number  => $project_number,
        project_status  => $status->{option_name},
    };
}

# 32. github_issue_create_task — Create a task issue and attach it to a
# GitHub Project V2 board in one workflow.
sub tool_github_issue_create_task {
    my ($args) = @_;
    my $owner           = $args->{owner}           or die "Missing required: owner";
    my $repo            = $args->{repo}            or die "Missing required: repo";
    my $title           = $args->{title}           or die "Missing required: title";
    my $body            = $args->{body}            // '';
    my $labels          = $args->{labels}          // undef;
    my $assignees       = $args->{assignees}       // undef;
    my $project_owner   = $args->{project_owner}   // 'kirill-scherba';
    my $project_number  = $args->{project_number}  // 9;
    my $project_status  = $args->{project_status}  // 'Backlog';

    # Step 1: Preflight — resolve project and validate status before creating issue
    # (no side effects yet, so configuration/auth errors fail before any mutation)
    my $project_id = _resolve_project_node_id($project_owner, $project_number);
    my $status     = _resolve_status_option_id($project_owner, $project_number, $project_status);

    # Step 2: Create the issue
    my $issue = tool_github_issue_create({
        owner     => $owner,
        repo      => $repo,
        title     => $title,
        body      => $body,
        labels    => $labels,
        assignees => $assignees,
    });

    my $issue_number = $issue->{issue_number};

    # Step 3: Resolve issue GraphQL node ID
    my $content_id = _resolve_issue_node_id($owner, $repo, $issue_number);

    # Step 4: Add issue to project
    my $add_res = tool_github_project_add_item({
        project_id => $project_id,
        content_id => $content_id,
    });
    my $item_id = $add_res->{id};

    # Step 5: Set project status
    tool_github_project_update_item({
        project_id => $project_id,
        item_id    => $item_id,
        field_id   => $status->{field_id},
        option_id  => $status->{option_id},
    });

    return {
        issue_url       => $issue->{issue_url},
        issue_number    => $issue_number,
        title           => $issue->{title},
        state           => $issue->{state},
        issue_node_id   => $content_id,
        project_id      => $project_id,
        project_item_id => $item_id,
        project_owner   => $project_owner,
        project_number  => $project_number,
        project_status  => $status->{option_name},
    };
}

# 13. github_project_list — List GitHub Projects V2 for user or organization
sub tool_github_project_list {
    my ($args) = @_;
    my $owner  = $args->{owner}       or die "Missing required: owner";
    my $limit  = $args->{limit}       // 10;
    my $type   = $args->{owner_type}  // 'auto';  # user, org, auto

    my $field = '';
    if ($type eq 'auto') {
        (my $t, undef) = _resolve_owner($owner);
        $field = $t;
    } elsif ($type eq 'org') {
        $field = 'organization';
    } elsif ($type eq 'user') {
        $field = 'user';
    } else {
        die "Invalid owner_type '$type' (expected 'user', 'org', or 'auto')";
    }

    my $query = qq{
        query(\$owner: String!, \$limit: Int!) {
            $field(login: \$owner) {
                projectsV2(first: \$limit) {
                    nodes {
                        id
                        number
                        title
                        url
                        public
                        closed
                        createdAt
                        updatedAt
                        creator { login }
                    }
                    pageInfo { hasNextPage endCursor }
                }
            }
        }
    };
    my $res = _github_graphql($query, { owner => $owner, limit => $limit });
    if ($res->{success}) {
        my $projects = $res->{data}{$field}{projectsV2}{nodes} // [];
        return { owner_type => $field, projects => $projects, count => scalar @$projects };
    }
    die "GraphQL error: " . ($res->{reason} // 'unknown');
}

# 14. github_project_get — Get details of a specific GitHub Project V2
sub tool_github_project_get {
    my ($args) = @_;
    my $owner  = $args->{owner}       or die "Missing required: owner";
    my $number = $args->{number}      or die "Missing required: number";
    my $type   = $args->{owner_type}  // 'auto';

    my $field = '';
    if ($type eq 'auto') {
        (my $t, undef) = _resolve_owner($owner);
        $field = $t;
    } elsif ($type eq 'org') {
        $field = 'organization';
    } elsif ($type eq 'user') {
        $field = 'user';
    } else {
        die "Invalid owner_type '$type'";
    }

    my $query = qq{
        query(\$owner: String!, \$number: Int!) {
            $field(login: \$owner) {
                projectV2(number: \$number) {
                    id
                    number
                    title
                    url
                    shortDescription
                    readme
                    public
                    closed
                    createdAt
                    updatedAt
                    creator { login }
                }
            }
        }
    };
    my $res = _github_graphql($query, { owner => $owner, number => $number });
    if ($res->{success} && $res->{data}{$field}{projectV2}) {
        return $res->{data}{$field}{projectV2};
    }
    die "GraphQL error: " . ($res->{reason} // 'Project not found');
}

# 15. github_project_create — Create a new GitHub Project V2
sub tool_github_project_create {
    my ($args) = @_;
    my $owner   = $args->{owner}  or die "Missing required: owner";
    my $title   = $args->{title}  or die "Missing required: title";
    my $body    = $args->{body}   // '';

    my $owner_type = '';
    my $owner_id   = '';
    ($owner_type, $owner_id) = _resolve_owner($owner);

    my $query = <<'EOF';
    mutation($ownerId: ID!, $title: String!, $body: String) {
        createProjectV2(input: {ownerId: $ownerId, title: $title, body: $body}) {
            projectV2 {
                id
                number
                title
                url
                public
                closed
                createdAt
                updatedAt
            }
        }
    }
EOF
    my $res = _github_graphql($query, { ownerId => $owner_id, title => $title, body => $body });
    if ($res->{success} && $res->{data}{createProjectV2}{projectV2}) {
        return $res->{data}{createProjectV2}{projectV2};
    }
    die "GraphQL error: " . ($res->{reason} // 'Failed to create project');
}

# 16. github_project_update — Update a GitHub Project V2
sub tool_github_project_update {
    my ($args) = @_;
    my $project_id = $args->{project_id}  or die "Missing required: project_id";

    my %updatable = ();
    $updatable{title}   = $args->{title}  if defined $args->{title};
    $updatable{public}  = $args->{public} ? JSON::true : JSON::false if defined $args->{public};
    $updatable{closed}  = $args->{closed} ? JSON::true : JSON::false if defined $args->{closed};
    $updatable{readme}  = $args->{readme}  if defined $args->{readme};
    $updatable{shortDescription} = $args->{description} if defined $args->{description};

    die "Nothing to update" unless keys %updatable;

    # Build the update payload inline since _github_graphql JSON-encodes variables
    $updatable{projectId} = $project_id;

    my $query = <<'EOF';
    mutation($input: UpdateProjectV2Input!) {
        updateProjectV2(input: $input) {
            projectV2 {
                id
                number
                title
                url
                public
                closed
                shortDescription
            }
        }
    }
EOF
    my $res = _github_graphql($query, { input => \%updatable });
    if ($res->{success} && $res->{data}{updateProjectV2}{projectV2}) {
        return $res->{data}{updateProjectV2}{projectV2};
    }
    die "GraphQL error: " . ($res->{reason} // 'Failed to update project');
}

# 17. github_project_delete — Delete a GitHub Project V2
sub tool_github_project_delete {
    my ($args) = @_;
    my $project_id = $args->{project_id} or die "Missing required: project_id";

    my $query = <<'EOF';
    mutation($projectId: ID!) {
        deleteProjectV2(input: {projectId: $projectId}) {
            projectV2 { id }
        }
    }
EOF
    my $res = _github_graphql($query, { projectId => $project_id });
    if ($res->{success} && $res->{data}{deleteProjectV2}{projectV2}) {
        return { deleted => JSON::true, project_id => $project_id };
    }
    die "GraphQL error: " . ($res->{reason} // 'Failed to delete project');
}

# 18. github_project_list_fields — List fields in a GitHub Project V2
sub tool_github_project_list_fields {
    my ($args) = @_;
    my $owner   = $args->{owner}       or die "Missing required: owner";
    my $number  = $args->{number}      or die "Missing required: number";
    my $limit   = $args->{limit}       // 50;
    my $type    = $args->{owner_type}  // 'auto';

    my $field = '';
    if ($type eq 'auto') {
        (my $t, undef) = _resolve_owner($owner);
        $field = $t;
    } elsif ($type eq 'org') {
        $field = 'organization';
    } elsif ($type eq 'user') {
        $field = 'user';
    } else {
        die "Invalid owner_type '$type'";
    }

    my $query = qq{
        query(\$owner: String!, \$number: Int!, \$limit: Int!) {
            $field(login: \$owner) {
                projectV2(number: \$number) {
                    fields(first: \$limit) {
                        nodes {
                            ... on ProjectV2Field { __typename id name dataType }
                            ... on ProjectV2SingleSelectField { __typename id name dataType options { id name color } }
                            ... on ProjectV2IterationField { __typename id name dataType configuration { iterations { id title startDate duration } } }
                        }
                        pageInfo { hasNextPage endCursor }
                    }
                }
            }
        }
    };
    my $res = _github_graphql($query, { owner => $owner, number => $number, limit => $limit });
    if ($res->{success} && $res->{data}{$field}{projectV2}) {
        my $fields = $res->{data}{$field}{projectV2}{fields}{nodes} // [];
        return { fields => $fields, count => scalar @$fields };
    }
    die "GraphQL error: " . ($res->{reason} // 'Failed to list fields');
}

# 19. github_project_list_items — List items in a GitHub Project V2
sub tool_github_project_list_items {
    my ($args) = @_;
    my $owner   = $args->{owner}       or die "Missing required: owner";
    my $number  = $args->{number}      or die "Missing required: number";
    my $limit   = $args->{limit}       // 20;
    my $type    = $args->{owner_type}  // 'auto';
    my $after   = $args->{after}       // undef;   # cursor for pagination
    my $status  = $args->{status}      // undef;   # optional status filter

    my $field = '';
    if ($type eq 'auto') {
        (my $t, undef) = _resolve_owner($owner);
        $field = $t;
    } elsif ($type eq 'org') {
        $field = 'organization';
    } elsif ($type eq 'user') {
        $field = 'user';
    } else {
        die "Invalid owner_type '$type'";
    }

    # Include after cursor in query only when provided
    my $has_after = defined $after && $after ne '';
    my $after_arg = $has_after ? ', after: $after' : '';

    my $query = qq{
        query(\$owner: String!, \$number: Int!, \$limit: Int!${\($has_after ? ', $after: String!' : '')}) {
            $field(login: \$owner) {
                projectV2(number: \$number) {
                    items(first: \$limit$after_arg) {
                        nodes {
                            id
                            content {
                                ... on Issue { __typename title number state url repository { nameWithOwner } }
                                ... on PullRequest { __typename title number state url repository { nameWithOwner } }
                                ... on DraftIssue { __typename title body }
                            }
                            fieldValues(first: 8) {
                                nodes {
                                    ... on ProjectV2ItemFieldTextValue { field { ... on ProjectV2FieldCommon { id name } } text }
                                    ... on ProjectV2ItemFieldSingleSelectValue { field { ... on ProjectV2FieldCommon { id name } } name color }
                                    ... on ProjectV2ItemFieldNumberValue { field { ... on ProjectV2FieldCommon { id name } } number }
                                    ... on ProjectV2ItemFieldDateValue { field { ... on ProjectV2FieldCommon { id name } } date }
                                    ... on ProjectV2ItemFieldIterationValue { field { ... on ProjectV2FieldCommon { id name } } title startDate duration }
                                }
                            }
                        }
                        pageInfo { hasNextPage endCursor }
                    }
                }
            }
        }
    };
    my %vars = ( owner => $owner, number => $number, limit => $limit );
    $vars{after} = $after if $has_after;
    my $res = _github_graphql($query, \%vars);
    if ($res->{success} && $res->{data}{$field}{projectV2}) {
        my $raw_items = $res->{data}{$field}{projectV2}{items}{nodes} // [];
        my $page_info = $res->{data}{$field}{projectV2}{items}{pageInfo};

        # Format items with status extracted from fieldValues
        my @formatted;
        for my $item (@$raw_items) {
            my $content = $item->{content} // {};
            my $type = $content->{__typename} // 'Unknown';

            # Extract Status from fieldValues
            my $item_status = '';
            my $field_values = $item->{fieldValues}{nodes} // [];
            for my $fv (@$field_values) {
                if ($fv->{field} && $fv->{field}{name} eq 'Status') {
                    $item_status = $fv->{name} // '';
                    last;
                }
            }

            # Apply status filter if requested
            if (defined $status && $status ne '') {
                next unless lc($item_status) eq lc($status);
            }

            my $entry = {
                id          => $item->{id},
                type        => $type,
                status      => $item_status,
                content     => $item->{content},
                fieldValues => $item->{fieldValues},
            };

            if ($type eq 'Issue') {
                $entry->{title}  = $content->{title} // '';
                $entry->{number} = $content->{number};
                $entry->{state}  = $content->{state} // '';
                $entry->{url}    = $content->{url} // '';
                $entry->{repo}   = $content->{repository}{nameWithOwner} // '';
            } elsif ($type eq 'PullRequest') {
                $entry->{title}  = $content->{title} // '';
                $entry->{number} = $content->{number};
                $entry->{state}  = $content->{state} // '';
                $entry->{url}    = $content->{url} // '';
                $entry->{repo}   = $content->{repository}{nameWithOwner} // '';
            } elsif ($type eq 'DraftIssue') {
                $entry->{title}  = $content->{title} // '';
                $entry->{body}   = $content->{body} // '';
            }

            push @formatted, $entry;
        }

        return {
            items         => \@formatted,
            count         => scalar @formatted,
            has_next_page => $page_info->{hasNextPage} ? JSON::true : JSON::false,
            end_cursor    => $page_info->{endCursor} // undef,
        };
    }
    die "GraphQL error: " . ($res->{reason} // 'Failed to list items');
}

# 29. github_project_search_items — Find items in a Project V2 by name and optional status filter
# Status filtering is done client-side (GraphQL filterBy is not supported on items).
sub tool_github_project_search_items {
    my ($args) = @_;
    my $owner   = $args->{owner}       or die "Missing required: owner";
    my $project = $args->{project}     or die "Missing required: project";
    my $status  = $args->{status}      // undef;
    my $limit   = $args->{limit}       // 50;
    my $type    = $args->{owner_type}  // 'auto';
    my $after   = $args->{after}       // undef;   # cursor for pagination

    # Step 1: Resolve owner type
    my $field = '';
    if ($type eq 'auto') {
        (my $t, undef) = _resolve_owner($owner);
        $field = $t;
    } elsif ($type eq 'org') {
        $field = 'organization';
    } elsif ($type eq 'user') {
        $field = 'user';
    } else {
        die "Invalid owner_type '$type'";
    }

    # Step 2: List projects to find the one matching by title
    my $list_query = qq{
        query(\$owner: String!, \$limit: Int!) {
            $field(login: \$owner) {
                projectsV2(first: \$limit) {
                    nodes {
                        id
                        number
                        title
                    }
                }
            }
        }
    };
    my $list_res = _github_graphql($list_query, { owner => $owner, limit => 100 });
    die "GraphQL error listing projects: " . ($list_res->{reason} // 'unknown') unless $list_res->{success};

    my $projects = $list_res->{data}{$field}{projectsV2}{nodes} // [];
    my ($project_node) = grep { lc($_->{title}) eq lc($project) } @$projects;
    die "Project '$project' not found for owner '$owner'" unless $project_node;

    my $project_id     = $project_node->{id};
    my $project_number = $project_node->{number};

    # Step 3: Query items (without filterBy — not supported on items connection)
    # Filter by status is done client-side below.
    my $has_after = defined $after && $after ne '';
    my $after_arg = $has_after ? ', after: $after' : '';

    my $items_query = qq{
        query(\$owner: String!, \$number: Int!, \$limit: Int!${\($has_after ? ', $after: String!' : '')}) {
            $field(login: \$owner) {
                projectV2(number: \$number) {
                    items(first: \$limit$after_arg) {
                        nodes {
                            id
                            content {
                                ... on Issue { __typename title number state url repository { nameWithOwner } }
                                ... on PullRequest { __typename title number state url repository { nameWithOwner } }
                                ... on DraftIssue { __typename title body }
                            }
                            fieldValues(first: 8) {
                                nodes {
                                    ... on ProjectV2ItemFieldSingleSelectValue {
                                        field { ... on ProjectV2FieldCommon { id name } }
                                        name
                                    }
                                }
                            }
                        }
                        pageInfo { hasNextPage endCursor }
                    }
                }
            }
        }
    };
    my %query_vars = ( owner => $owner, number => $project_number, limit => $limit );
    $query_vars{after} = $after if $has_after;

    my $items_res = _github_graphql($items_query, \%query_vars);
    die "GraphQL error listing items: " . ($items_res->{reason} // 'unknown') unless $items_res->{success};

    my $raw_items = $items_res->{data}{$field}{projectV2}{items}{nodes} // [];
    my $page_info = $items_res->{data}{$field}{projectV2}{items}{pageInfo};

    # Format items with status extracted from fieldValues, applying client-side filter
    my @formatted;
    for my $item (@$raw_items) {
        my $content = $item->{content} // {};
        my $type = $content->{__typename} // 'Unknown';

        # Extract Status from fieldValues
        my $item_status = '';
        my $field_values = $item->{fieldValues}{nodes} // [];
        for my $fv (@$field_values) {
            if ($fv->{field} && $fv->{field}{name} eq 'Status') {
                $item_status = $fv->{name} // '';
                last;
            }
        }

        # Apply client-side status filter
        if (defined $status && $status ne '') {
            next unless lc($item_status) eq lc($status);
        }

        my $entry = {
            id          => $item->{id},
            type        => $type,
            status      => $item_status,
            content     => $item->{content},
            fieldValues => $item->{fieldValues},
        };

        if ($type eq 'Issue') {
            $entry->{title}  = $content->{title} // '';
            $entry->{number} = $content->{number};
            $entry->{state}  = $content->{state} // '';
            $entry->{url}    = $content->{url} // '';
            $entry->{repo}   = $content->{repository}{nameWithOwner} // '';
        } elsif ($type eq 'PullRequest') {
            $entry->{title}  = $content->{title} // '';
            $entry->{number} = $content->{number};
            $entry->{state}  = $content->{state} // '';
            $entry->{url}    = $content->{url} // '';
            $entry->{repo}   = $content->{repository}{nameWithOwner} // '';
        } elsif ($type eq 'DraftIssue') {
            $entry->{title}  = $content->{title} // '';
            $entry->{body}   = $content->{body} // '';
        }

        push @formatted, $entry;
    }

    return {
        project => {
            id     => $project_id,
            number => $project_number,
            title  => $project_node->{title},
        },
        status_filter => (defined $status && $status ne '') ? $status : undef,
        items    => \@formatted,
        count    => scalar @formatted,
        has_next_page => $page_info->{hasNextPage} ? JSON::true : JSON::false,
        end_cursor    => $page_info->{endCursor} // undef,
    };
}

# 20. github_project_add_item — Add an issue or PR to a GitHub Project V2
sub tool_github_project_add_item {
    my ($args) = @_;
    my $project_id  = $args->{project_id}  or die "Missing required: project_id";
    my $content_id  = $args->{content_id}  or die "Missing required: content_id";

    my $query = <<'EOF';
    mutation($projectId: ID!, $contentId: ID!) {
        addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
            item {
                id
                content {
                    ... on Issue { title number }
                    ... on PullRequest { title number }
                    ... on DraftIssue { title }
                }
            }
        }
    }
EOF
    my $res = _github_graphql($query, { projectId => $project_id, contentId => $content_id });
    if ($res->{success} && $res->{data}{addProjectV2ItemById}{item}) {
        return $res->{data}{addProjectV2ItemById}{item};
    }
    die "GraphQL error: " . ($res->{reason} // 'Failed to add item');
}

# 22. github_project_create_draft — Create a draft issue in a GitHub Project V2
sub tool_github_project_create_draft {
    my ($args) = @_;
    my $project_id = $args->{project_id} or die "Missing required: project_id";
    my $title      = $args->{title}      or die "Missing required: title";
    my $body       = $args->{body}       // '';

    my $query = <<'EOF';
    mutation($projectId: ID!, $title: String!, $body: String) {
        addProjectV2DraftIssue(input: {projectId: $projectId, title: $title, body: $body}) {
            projectItem {
                id
                content {
                    ... on DraftIssue {
                        id
                        title
                        body
                        creator { login }
                        createdAt
                    }
                }
            }
        }
    }
EOF
    my $res = _github_graphql($query, { projectId => $project_id, title => $title, body => $body });
    if ($res->{success} && $res->{data}{addProjectV2DraftIssue}{projectItem}) {
        return $res->{data}{addProjectV2DraftIssue}{projectItem};
    }
    die "GraphQL error: " . ($res->{reason} // 'Failed to create draft issue');
}

# 23. github_project_update_item — Update a field value on a project item
sub tool_github_project_update_item {
    my ($args) = @_;
    my $project_id  = $args->{project_id}  or die "Missing required: project_id";
    my $item_id     = $args->{item_id}     or die "Missing required: item_id";
    my $field_id    = $args->{field_id}    or die "Missing required: field_id";
    my $value        = $args->{value}        // undef;
    my $number       = $args->{number}       // undef;
    my $text         = $args->{text}         // undef;
    my $date         = $args->{date}         // undef;
    my $option_id    = $args->{option_id}    // undef;
    my $iteration_id = $args->{iteration_id} // undef;

    # Determine which explicit fields were actually provided
    my $has_option_id    = defined $option_id    && $option_id    ne '';
    my $has_iteration_id = defined $iteration_id && $iteration_id ne '';
    my $has_text         = defined $text         && $text         ne '';
    my $has_date         = defined $date         && $date         ne '';
    my $has_number       = defined $number && $number != 0;  # 0 is likely a JS/JSON default
    my $has_value        = defined $value      && $value         ne '';

    # Build the value object — explicit named fields take priority over generic $value
    my %value_obj = ();
    if ($has_option_id || $has_iteration_id || $has_text || $has_date || $has_number) {
        $value_obj{singleSelectOptionId} = $option_id    if $has_option_id;
        $value_obj{iterationId}         = $iteration_id if $has_iteration_id;
        $value_obj{text}                = $text         if $has_text;
        $value_obj{date}                = $date         if $has_date;
        $value_obj{number}              = int($number)  if $has_number;
    } elsif ($has_value) {
        # Auto-inference from generic value (fallback only)
        if ($value =~ /^\d+$/) {
            $value_obj{number} = int($value);
        } elsif ($value =~ /^\d{4}-\d{2}-\d{2}$/) {
            $value_obj{date} = $value;
        } else {
            $value_obj{text} = $value;
        }
    }

    die "Nothing to update (provide value, number, text, date, option_id, or iteration_id)" unless keys %value_obj;

    my $query = <<'EOF';
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: ProjectV2FieldValue!) {
        updateProjectV2ItemFieldValue(
            input: { projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: $value }
        ) {
            projectV2Item {
                id
                fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
            }
        }
    }
EOF
    my $res = _github_graphql($query, {
        projectId => $project_id,
        itemId    => $item_id,
        fieldId   => $field_id,
        value     => \%value_obj,
    });
    if ($res->{success} && $res->{data}{updateProjectV2ItemFieldValue}{projectV2Item}) {
        return $res->{data}{updateProjectV2ItemFieldValue}{projectV2Item};
    }
    die "GraphQL error: " . ($res->{reason} // 'Failed to update item');
}

# ============================================================================
# Pull Request Tools (REST API)
# ============================================================================

# 24. github_pull_request_get — Get PR metadata by number
sub tool_github_pull_request_get {
    my ($args) = @_;
    my $owner        = $args->{owner}        or die "Missing required: owner";
    my $repo         = $args->{repo}         or die "Missing required: repo";
    my $pull_number  = $args->{pull_number}  or die "Missing required: pull_number";

    my $res = _github_api("GET", "/repos/$owner/$repo/pulls/$pull_number");
    if ($res->{success}) {
        my $pr = $res->{data};
        return {
            pull_number  => $pr->{number},
            title        => $pr->{title},
            body         => $pr->{body} // '',
            state        => $pr->{state},
            author       => $pr->{user}{login},
            draft        => $pr->{draft} // 0,
            mergeable    => $pr->{mergeable},
            merged       => $pr->{merged} // 0,
            merged_by    => $pr->{merged_by}{login} // undef,
            merge_commit_sha => $pr->{merge_commit_sha} // undef,
            base         => {
                ref  => $pr->{base}{ref},
                sha  => $pr->{base}{sha},
                repo => $pr->{base}{repo}{full_name},
            },
            head         => {
                ref  => $pr->{head}{ref},
                sha  => $pr->{head}{sha},
                repo => $pr->{head}{repo}{full_name},
            },
            labels       => [map { $_->{name} } @{$pr->{labels} // []}],
            additions    => $pr->{additions} // 0,
            deletions    => $pr->{deletions} // 0,
            changed_files => $pr->{changed_files} // 0,
            commits      => $pr->{commits} // 0,
            comments     => $pr->{comments} // 0,
            review_comments => $pr->{review_comments} // 0,
            created_at   => $pr->{created_at},
            updated_at   => $pr->{updated_at},
            closed_at    => $pr->{closed_at} // undef,
            merged_at    => $pr->{merged_at} // undef,
            html_url     => $pr->{html_url},
            issue_url    => $pr->{issue_url} // '',
            diff_url     => $pr->{diff_url} // '',
            patch_url    => $pr->{patch_url} // '',
        };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 25. github_pull_request_list — List PRs with filters
sub tool_github_pull_request_list {
    my ($args) = @_;
    my $owner     = $args->{owner}     or die "Missing required: owner";
    my $repo      = $args->{repo}      or die "Missing required: repo";
    my $state     = $args->{state}     // 'open';
    my $head      = $args->{head}      // undef;
    my $base      = $args->{base}      // undef;
    my $sort      = $args->{sort}      // 'created';
    my $direction = $args->{direction} // 'desc';
    my $limit     = $args->{limit}     // 30;

    my $path = "/repos/$owner/$repo/pulls?state=$state&per_page=$limit&sort=$sort&direction=$direction";
    $path .= "&head=$head" if $head;
    $path .= "&base=$base" if $base;

    my $res = _github_api("GET", $path);
    if ($res->{success}) {
        my @prs;
        for my $pr (@{$res->{data} // []}) {
            push @prs, {
                pull_number  => $pr->{number},
                title        => $pr->{title},
                state        => $pr->{state},
                author       => $pr->{user}{login},
                draft        => $pr->{draft} // 0,
                base         => { ref => $pr->{base}{ref}, repo => $pr->{base}{repo}{full_name} },
                head         => { ref => $pr->{head}{ref}, repo => $pr->{head}{repo}{full_name} },
                labels       => [map { $_->{name} } @{$pr->{labels} // []}],
                created_at   => $pr->{created_at},
                updated_at   => $pr->{updated_at},
                html_url     => $pr->{html_url},
            };
        }
        return { pull_requests => \@prs, count => scalar @prs };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 26. github_pull_request_get_files — Get changed files with patch snippets
sub tool_github_pull_request_get_files {
    my ($args) = @_;
    my $owner        = $args->{owner}        or die "Missing required: owner";
    my $repo         = $args->{repo}         or die "Missing required: repo";
    my $pull_number  = $args->{pull_number}  or die "Missing required: pull_number";
    my $limit        = $args->{limit}        // 100;

    my $res = _github_api("GET", "/repos/$owner/$repo/pulls/$pull_number/files?per_page=$limit");
    if ($res->{success}) {
        my @files;
        for my $f (@{$res->{data} // []}) {
            push @files, {
                filename          => $f->{filename},
                status            => $f->{status},  # added, modified, removed, renamed
                additions         => $f->{additions},
                deletions         => $f->{deletions},
                changes           => $f->{changes},
                patch             => $f->{patch} // '',
                contents_url      => $f->{contents_url},
                blob_url          => $f->{blob_url},
                raw_url           => $f->{raw_url},
                sha               => $f->{sha},
                previous_filename => $f->{previous_filename} // undef,
            };
        }
        return { files => \@files, count => scalar @files };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 27. github_pull_request_list_reviews — List reviews and line-level review comments on a PR
sub tool_github_pull_request_list_reviews {
    my ($args) = @_;
    my $owner        = $args->{owner}        or die "Missing required: owner";
    my $repo         = $args->{repo}         or die "Missing required: repo";
    my $pull_number  = $args->{pull_number}  or die "Missing required: pull_number";
    my $limit        = $args->{limit}        // 50;

    my $reviews_res = _github_api("GET", "/repos/$owner/$repo/pulls/$pull_number/reviews?per_page=$limit");
    my $comments_res = _github_api("GET", "/repos/$owner/$repo/pulls/$pull_number/comments?per_page=$limit");

    if ($reviews_res->{success} && $comments_res->{success}) {
        my @reviews;
        for my $r (@{$reviews_res->{data} // []}) {
            push @reviews, {
                id           => $r->{id},
                user         => $r->{user}{login},
                body         => $r->{body} // '',
                state        => $r->{state},  # APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, PENDING
                author_association => $r->{author_association} // '',
                commit_id    => $r->{commit_id},
                submitted_at => $r->{submitted_at},
                html_url     => $r->{html_url} // '',
            };
        }

        my @review_comments;
        for my $c (@{$comments_res->{data} // []}) {
            push @review_comments, {
                id           => $c->{id},
                user         => $c->{user}{login},
                body         => $c->{body} // '',
                path         => $c->{path} // '',
                diff_hunk    => $c->{diff_hunk} // '',
                line         => $c->{line} // undef,
                side         => $c->{side} // '',
                start_line   => $c->{start_line} // undef,
                start_side   => $c->{start_side} // '',
                original_line => $c->{original_line} // undef,
                commit_id    => $c->{commit_id} // '',
                pull_request_review_id => $c->{pull_request_review_id} // undef,
                author_association => $c->{author_association} // '',
                created_at   => $c->{created_at},
                updated_at   => $c->{updated_at},
                html_url     => $c->{html_url} // '',
            };
        }

        return {
            reviews               => \@reviews,
            review_comments       => \@review_comments,
            count                 => scalar @reviews,
            reviews_count         => scalar @reviews,
            review_comments_count => scalar @review_comments,
        };
    }

    my $failed = $reviews_res->{success} ? $comments_res : $reviews_res;
    die "GitHub API error: " . ($failed->{reason} // "HTTP $failed->{status}");
}

# 28. github_pull_request_create_review — Create a review on a PR (write scope required)
# Graceful degradation: returns helpful message if token lacks write scopes.
sub tool_github_pull_request_create_review {
    my ($args) = @_;
    my $owner        = $args->{owner}        or die "Missing required: owner";
    my $repo         = $args->{repo}         or die "Missing required: repo";
    my $pull_number  = $args->{pull_number}  or die "Missing required: pull_number";
    my $body         = $args->{body}         or die "Missing required: body";
    my $event        = $args->{event}        // 'COMMENT';  # APPROVE, REQUEST_CHANGES, COMMENT
    my $comments     = $args->{comments}     // undef;       # array of {path, body, line, side}

    my %payload = (body => $body, event => $event);
    $payload{comments} = $comments if $comments && ref $comments eq 'ARRAY' && @$comments;

    my $body_str = $json->encode(\%payload);
    my $res = _github_api("POST", "/repos/$owner/$repo/pulls/$pull_number/reviews", $body_str);

    if ($res->{success}) {
        my $review = $res->{data};
        return {
            review_id    => $review->{id},
            user         => $review->{user}{login},
            body         => $review->{body} // '',
            state        => $review->{state},
            commit_id    => $review->{commit_id},
            submitted_at => $review->{submitted_at},
            html_url     => $review->{html_url} // '',
        };
    }

    # Check for specific GitHub validation errors from API response body
    if ($res->{data} && ref $res->{data} eq 'HASH') {
        my $data = $res->{data};
        if ($data->{errors} && ref $data->{errors} eq 'ARRAY') {
            for my $err (@{$data->{errors}}) {
                my $msg = ref $err eq 'HASH'
                    ? ($err->{message} // $err->{code} // '')
                    : ($err // '');
                if ($msg =~ /owned by you/i || $msg =~ /request changes on own/i) {
                    die "GitHub does not allow approving or requesting changes on your own pull request. "
                        . "Use event=COMMENT to leave a comment instead, or ask another user to review.";
                }
            }
        }
    }

    # Graceful degradation: detect auth/permission errors
    if ($res->{status} eq '401' || $res->{status} eq '403') {
        die "GitHub API error ($res->{status}): Your GITHUB_TOKEN lacks write permissions for pull request reviews. "
            . "Required scope: 'repo' for private repos or 'public_repo' for public repos. "
            . "See: https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps";
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 28. github_pull_request_create — Create a pull request
sub tool_github_pull_request_create {
    my ($args) = @_;
    my $owner    = $args->{owner}    or die "Missing required: owner";
    my $repo     = $args->{repo}     or die "Missing required: repo";
    my $title    = $args->{title}    or die "Missing required: title";
    my $head     = $args->{head}     or die "Missing required: head";
    my $base     = $args->{base}     or die "Missing required: base";
    my $body     = $args->{body}     // undef;
    my $draft    = $args->{draft}    // undef;

    my %payload = (title => $title, head => $head, base => $base);
    $payload{body}  = $body  if defined $body;
    $payload{draft} = $draft ? JSON::true : JSON::false if defined $draft;

    my $body_str = $json->encode(\%payload);
    my $res = _github_api("POST", "/repos/$owner/$repo/pulls", $body_str);

    if ($res->{success}) {
        my $pr = $res->{data};
        return {
            pull_number      => $pr->{number},
            title            => $pr->{title},
            body             => $pr->{body} // '',
            state            => $pr->{state},
            author           => $pr->{user}{login},
            draft            => $pr->{draft} // 0,
            mergeable        => $pr->{mergeable},
            merged           => $pr->{merged} // 0,
            merged_by        => $pr->{merged_by}{login} // undef,
            merge_commit_sha => $pr->{merge_commit_sha} // undef,
            base             => {
                ref  => $pr->{base}{ref},
                sha  => $pr->{base}{sha},
                repo => $pr->{base}{repo}{full_name},
            },
            head             => {
                ref  => $pr->{head}{ref},
                sha  => $pr->{head}{sha},
                repo => $pr->{head}{repo}{full_name},
            },
            labels           => [map { $_->{name} } @{$pr->{labels} // []}],
            additions        => $pr->{additions} // 0,
            deletions        => $pr->{deletions} // 0,
            changed_files    => $pr->{changed_files} // 0,
            commits          => $pr->{commits} // 0,
            comments         => $pr->{comments} // 0,
            review_comments  => $pr->{review_comments} // 0,
            created_at       => $pr->{created_at},
            updated_at       => $pr->{updated_at},
            closed_at        => $pr->{closed_at} // undef,
            merged_at        => $pr->{merged_at} // undef,
            html_url         => $pr->{html_url},
            issue_url        => $pr->{issue_url} // '',
            diff_url         => $pr->{diff_url} // '',
            patch_url        => $pr->{patch_url} // '',
        };
    }
    die "GitHub API error: " . ($res->{reason} // "HTTP $res->{status}");
}

# 29. github_resolve_thread — Resolve a PR review conversation thread via GraphQL
sub tool_github_resolve_thread {
    my ($args) = @_;
    my $thread_id = $args->{thread_id} or die "Missing required: thread_id";

    my $query = <<'EOF';
    mutation($threadId: ID!) {
        resolveReviewThread(input: { threadId: $threadId }) {
            thread {
                id
                isResolved
            }
        }
    }
EOF
    my $res = _github_graphql($query, { threadId => $thread_id });

    if ($res->{success} && $res->{data}{resolveReviewThread}{thread}) {
        my $thread = $res->{data}{resolveReviewThread}{thread};
        return {
            success     => JSON::true,
            thread_id   => $thread->{id},
            is_resolved => $thread->{isResolved} ? JSON::true : JSON::false,
        };
    }

    # Surface GraphQL errors (already resolved, invalid thread ID, etc.)
    my $reason = $res->{reason} // 'Failed to resolve review thread';
    die "GitHub API error: $reason";
}

# 34. github_pull_request_merge — Merge a PR and delete the source branch
sub tool_github_pull_request_merge {
    my ($args) = @_;
    my $owner          = $args->{owner}          or die "Missing required: owner";
    my $repo           = $args->{repo}           or die "Missing required: repo";
    my $pull_number    = $args->{pull_number}    or die "Missing required: pull_number";
    my $merge_method   = $args->{merge_method}   // 'merge';
    my $commit_title   = $args->{commit_title}   // undef;
    my $commit_message = $args->{commit_message} // undef;

    # Step 1: Fetch PR details to get head branch name and source repo
    my $pr_res = _github_api("GET", "/repos/$owner/$repo/pulls/$pull_number");
    die "GitHub API error fetching PR: " . ($pr_res->{reason} // "HTTP $pr_res->{status}") unless $pr_res->{success};

    my $pr_data     = $pr_res->{data};
    my $head_branch = $pr_data->{head}{ref};
    my $pr_url      = $pr_data->{html_url} // "https://github.com/$owner/$repo/pull/$pull_number";

    # Determine the source repo for branch deletion
    # For fork PRs, head.repo differs from base repo; for same-repo PRs they match.
    my $head_repo_owner = $pr_data->{head}{repo}{owner}{login}  // $owner;
    my $head_repo_name  = $pr_data->{head}{repo}{name}           // $repo;
    my $head_repo_full  = $pr_data->{head}{repo}{full_name}      // "$owner/$repo";

    # Validate merge_method
    my %valid_methods = map { $_ => 1 } qw(merge squash rebase);
    die "Invalid merge_method '$merge_method'. Valid: merge, squash, rebase" unless $valid_methods{$merge_method};

    # Step 2: Perform merge
    my %merge_payload = (merge_method => $merge_method);
    $merge_payload{commit_title}   = $commit_title   if defined $commit_title;
    $merge_payload{commit_message} = $commit_message if defined $commit_message;

    my $body_str = $json->encode(\%merge_payload);
    my $merge_res = _github_api("PUT", "/repos/$owner/$repo/pulls/$pull_number/merge", $body_str);

    unless ($merge_res->{success}) {
        # Surface specific GitHub error messages for common failure modes
        my $reason = $merge_res->{reason} // "HTTP $merge_res->{status}";
        my $status = $merge_res->{status};

        # Check for specific error conditions
        if ($status eq '405') {
            die "Pull request #$pull_number cannot be merged (already merged, or merge not allowed): $reason";
        }
        if ($status eq '409') {
            die "Pull request #$pull_number has merge conflicts and cannot be merged: $reason";
        }
        if ($status eq '404') {
            die "Pull request #$pull_number not found in $owner/$repo: $reason";
        }
        die "GitHub API error merging PR #$pull_number: $reason";
    }

    my $merge_data = $merge_res->{data};
    my $merged     = $merge_data->{merged} // 0;
    my $message    = $merge_data->{message} // '';
    my $sha        = $merge_data->{sha} // '';

    # Step 3: Delete source branch from the PR head repository (only on successful merge)
    # Uses pull.head.repo (which differs from base repo for fork PRs).
    my $branch_deleted = 0;
    my $deleted_branch = $head_branch;
    if ($merged) {
        my $delete_res = _github_api("DELETE", "/repos/$head_repo_owner/$head_repo_name/git/refs/heads/$head_branch");
        if ($delete_res->{success}) {
            $branch_deleted = 1;
        } else {
            # Branch deletion failure is non-fatal — log and report in response
            log_message("WARN", "Failed to delete branch '$head_branch' from $head_repo_full after merge: " . ($delete_res->{reason} // "HTTP $delete_res->{status}"));
        }
    }

    return {
        merged         => ($merged ? JSON::true : JSON::false),
        message        => $message,
        sha            => $sha,
        pr_url         => $pr_url,
        branch_deleted => ($branch_deleted ? JSON::true : JSON::false),
        deleted_branch => $deleted_branch,
    };
}

# ---------------------------------------------------------------------------
# Tool definitions for tools/list (34 tools: 12 issue/search/file + 10 project
# + 12 pull request / review / merge)
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
        description => "Update a GitHub issue (title, body, state, assignees). For label changes use github_issue_add_labels / github_issue_remove_labels.",
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
                # labels deliberately excluded — use github_issue_add_labels / github_issue_remove_labels
                assignees    => { type => "array",  items => { type => "string" }, description => "New assignees array (optional)" },
            },
        },
    },
    github_issue_add_labels => {
        description => "Add labels to a GitHub issue without removing existing ones (incremental). Reads current labels, merges new ones, updates.",
        handler     => \&tool_github_issue_add_labels,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "issue_number", "labels"],
            properties => {
                owner        => { type => "string", description => "Repository owner (user or org)" },
                repo         => { type => "string", description => "Repository name" },
                issue_number => { type => "number", description => "Issue number" },
                labels       => { type => "array", items => { type => "string" }, description => "Labels to add (each must be a string)" },
            },
        },
    },
    github_issue_remove_labels => {
        description => "Remove labels from a GitHub issue without affecting other labels (incremental). Reads current labels, removes specified ones, updates.",
        handler     => \&tool_github_issue_remove_labels,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "issue_number", "labels"],
            properties => {
                owner        => { type => "string", description => "Repository owner (user or org)" },
                repo         => { type => "string", description => "Repository name" },
                issue_number => { type => "number", description => "Issue number" },
                labels       => { type => "array", items => { type => "string" }, description => "Labels to remove (each must be a string, case-insensitive)" },
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
    github_repo_create => {
        description => "Create a new GitHub repository",
        handler     => \&tool_github_repo_create,
        inputSchema => {
            type => "object",
            required => ["name"],
            properties => {
                name        => { type => "string", description => "Repository name" },
                description => { type => "string", description => "Repository description (optional)" },
                private     => { type => "boolean", description => "Private repository (default: false)" },
                org         => { type => "string", description => "Organization name (optional, creates under user if omitted)" },
            },
        },
    },

    # === GitHub Projects V2 (GraphQL) ===

    github_project_list => {
        description => "List GitHub Projects V2 for a user or organization",
        handler     => \&tool_github_project_list,
        inputSchema => {
            type => "object",
            required => ["owner"],
            properties => {
                owner       => { type => "string", description => "User or organization login" },
                owner_type  => { type => "string", description => "Owner type: 'user', 'org', or 'auto' (default: auto)" },
                limit       => { type => "number", description => "Max projects to list (default: 10)" },
            },
        },
    },
    github_project_get => {
        description => "Get details of a GitHub Project V2",
        handler     => \&tool_github_project_get,
        inputSchema => {
            type => "object",
            required => ["owner", "number"],
            properties => {
                owner       => { type => "string", description => "User or organization login" },
                number      => { type => "number", description => "Project number" },
                owner_type  => { type => "string", description => "Owner type: 'user', 'org', or 'auto' (default: auto)" },
            },
        },
    },
    github_project_create => {
        description => "Create a new GitHub Project V2",
        handler     => \&tool_github_project_create,
        inputSchema => {
            type => "object",
            required => ["owner", "title"],
            properties => {
                owner  => { type => "string", description => "User or organization to create project for" },
                title  => { type => "string", description => "Project title" },
                body   => { type => "string", description => "Project description / README (optional)" },
            },
        },
    },
    github_project_update => {
        description => "Update a GitHub Project V2",
        handler     => \&tool_github_project_update,
        inputSchema => {
            type => "object",
            required => ["project_id"],
            properties => {
                project_id  => { type => "string", description => "GraphQL node ID of the project" },
                title       => { type => "string", description => "New title (optional)" },
                description => { type => "string", description => "Short description (optional)" },
                public      => { type => "boolean", description => "Make project public (optional)" },
                closed      => { type => "boolean", description => "Close project (optional)" },
                readme      => { type => "string", description => "Project body / readme content (optional)" },
            },
        },
    },
    github_project_delete => {
        description => "Delete a GitHub Project V2",
        handler     => \&tool_github_project_delete,
        inputSchema => {
            type => "object",
            required => ["project_id"],
            properties => {
                project_id  => { type => "string", description => "GraphQL node ID of the project" },
            },
        },
    },
    github_project_list_fields => {
        description => "List fields (columns) in a GitHub Project V2",
        handler     => \&tool_github_project_list_fields,
        inputSchema => {
            type => "object",
            required => ["owner", "number"],
            properties => {
                owner       => { type => "string", description => "User or organization login" },
                number      => { type => "number", description => "Project number" },
                owner_type  => { type => "string", description => "Owner type: 'user', 'org', or 'auto' (default: auto)" },
                limit       => { type => "number", description => "Max fields to list (default: 50)" },
            },
        },
    },
    github_project_list_items => {
        description => "List items (issues, PRs, draft issues) in a GitHub Project V2. Supports cursor-based pagination and optional status filtering.",
        handler     => \&tool_github_project_list_items,
        inputSchema => {
            type => "object",
            required => ["owner", "number"],
            properties => {
                owner       => { type => "string", description => "User or organization login" },
                number      => { type => "number", description => "Project number" },
                owner_type  => { type => "string", description => "Owner type: 'user', 'org', or 'auto' (default: auto)" },
                limit       => { type => "number", description => "Max items to list (default: 20, max: 100)" },
                after       => { type => "string", description => "Cursor for pagination (from end_cursor of previous response)" },
                status      => { type => "string", description => "Optional: filter by Status field value (e.g. 'Backlog', 'In Progress', 'Done'). Case-insensitive." },
            },
        },
    },
    github_project_search_items => {
        description => "Search for items in a GitHub Project V2 by project name and optional status filter. Resolves project by title, then optionally filters by a Status field value (e.g. 'Backlog', 'In Progress', 'Done'). Filtering is client-side. Supports cursor-based pagination.",
        handler     => \&tool_github_project_search_items,
        inputSchema => {
            type => "object",
            required => ["owner", "project"],
            properties => {
                owner       => { type => "string", description => "User or organization login" },
                project     => { type => "string", description => "Project title (name) to search in" },
                status      => { type => "string", description => "Filter by Status field value (e.g. 'Backlog', 'In Progress', 'Done'). Case-insensitive" },
                owner_type  => { type => "string", description => "Owner type: 'user', 'org', or 'auto' (default: auto)" },
                limit       => { type => "number", description => "Max items to return (default: 50, max: 100)" },
                after       => { type => "string", description => "Cursor for pagination (from end_cursor of previous response)" },
            },
        },
    },
    github_project_add_item => {
        description => "Add an existing issue, PR, or draft issue to a GitHub Project V2",
        handler     => \&tool_github_project_add_item,
        inputSchema => {
            type => "object",
            required => ["project_id", "content_id"],
            properties => {
                project_id  => { type => "string", description => "GraphQL node ID of the project (use github_project_get)" },
                content_id  => { type => "string", description => "GraphQL node ID of the issue/PR/draft to add" },
            },
        },
    },
    github_project_create_draft => {
        description => "Create a draft issue in a GitHub Project V2",
        handler     => \&tool_github_project_create_draft,
        inputSchema => {
            type => "object",
            required => ["project_id", "title"],
            properties => {
                project_id  => { type => "string", description => "GraphQL node ID of the project" },
                title       => { type => "string", description => "Draft issue title" },
                body        => { type => "string", description => "Draft issue body (optional)" },
            },
        },
    },
    github_project_update_item => {
        description => "Update a field value on a GitHub Project V2 item",
        handler     => \&tool_github_project_update_item,
        inputSchema => {
            type => "object",
            required => ["project_id", "item_id", "field_id"],
            properties => {
                project_id    => { type => "string", description => "GraphQL node ID of the project" },
                item_id       => { type => "string", description => "GraphQL node ID of the item" },
                field_id      => { type => "string", description => "GraphQL node ID of the field" },
                value         => { type => "string", description => "Value to set (auto-detected type: number, date, or text)" },
                number        => { type => "number", description => "Numeric value (overrides value)" },
                text          => { type => "string", description => "Text value (overrides value)" },
                date          => { type => "string", description => "Date value YYYY-MM-DD (overrides value)" },
                option_id     => { type => "string", description => "Single select option ID (overrides value)" },
                iteration_id  => { type => "string", description => "Iteration ID (overrides value)" },
            },
        },
    },

    # === Task / Project Helper Tools ===

    github_resolve_issue_node_id => {
        description => "Resolve a GitHub issue's GraphQL node ID by owner/repo/issue_number",
        handler     => \&tool_github_resolve_issue_node_id,
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
    github_project_add_issue => {
        description => "Add an existing issue to a GitHub Project V2 by owner/repo/issue_number without requiring manual GraphQL node IDs. Sets the project status to Backlog by default.",
        handler     => \&tool_github_project_add_issue,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "issue_number"],
            properties => {
                owner           => { type => "string", description => "Repository owner (user or org)" },
                repo            => { type => "string", description => "Repository name" },
                issue_number    => { type => "number", description => "Issue number" },
                project_owner   => { type => "string", description => "Project owner (default: kirill-scherba)" },
                project_number  => { type => "number", description => "Project number (default: 9 — Matrica)" },
                project_status  => { type => "string", description => "Project status to set (default: Backlog)" },
            },
        },
    },
    github_project_add_pull_request => {
        description => "Add an existing pull request to a GitHub Project V2 by owner/repo/pull_number without requiring manual GraphQL node IDs. Sets the project status to In review by default.",
        handler     => \&tool_github_project_add_pull_request,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "pull_number"],
            properties => {
                owner           => { type => "string", description => "Repository owner (user or org)" },
                repo            => { type => "string", description => "Repository name" },
                pull_number     => { type => "number", description => "Pull request number" },
                project_owner   => { type => "string", description => "Project owner (default: kirill-scherba)" },
                project_number  => { type => "number", description => "Project number (default: 9 — Matrica)" },
                project_status  => { type => "string", description => "Project status to set (default: In review)" },
            },
        },
    },
    github_issue_create_task => {
        description => "Create a task issue and attach it to GitHub Project V2 Matrica board in one workflow. Creates the issue, resolves its GraphQL node ID, adds to project, and sets project status.",
        handler     => \&tool_github_issue_create_task,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "title"],
            properties => {
                owner           => { type => "string", description => "Repository owner (user or org)" },
                repo            => { type => "string", description => "Repository name" },
                title           => { type => "string", description => "Issue title" },
                body            => { type => "string", description => "Issue body (optional)" },
                labels          => { type => "array",  items => { type => "string" }, description => "Label names (optional)" },
                assignees       => { type => "array",  items => { type => "string" }, description => "Usernames to assign (optional)" },
                project_owner   => { type => "string", description => "Project owner (default: kirill-scherba)" },
                project_number  => { type => "number", description => "Project number (default: 9 — Matrica)" },
                project_status  => { type => "string", description => "Project status to set (default: Backlog)" },
            },
        },
    },

    # === Pull Request Tools (REST) ===

    github_pull_request_get => {
        description => "Get details of a specific GitHub pull request",
        handler     => \&tool_github_pull_request_get,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "pull_number"],
            properties => {
                owner        => { type => "string", description => "Repository owner (user or org)" },
                repo         => { type => "string", description => "Repository name" },
                pull_number  => { type => "number", description => "Pull request number" },
            },
        },
    },
    github_pull_request_list => {
        description => "List GitHub pull requests with optional filters",
        handler     => \&tool_github_pull_request_list,
        inputSchema => {
            type => "object",
            required => ["owner", "repo"],
            properties => {
                owner      => { type => "string", description => "Repository owner (user or org)" },
                repo       => { type => "string", description => "Repository name" },
                state      => { type => "string", description => "PR state: open, closed, all (default: open)" },
                head       => { type => "string", description => "Filter by head branch name (optional)" },
                base       => { type => "string", description => "Filter by base branch name (optional)" },
                sort       => { type => "string", description => "Sort: created, updated, popularity, long-running (default: created)" },
                direction  => { type => "string", description => "Direction: asc, desc (default: desc)" },
                limit      => { type => "number", description => "Max results (default: 30)" },
            },
        },
    },
    github_pull_request_get_files => {
        description => "Get changed files and patch snippets for a pull request",
        handler     => \&tool_github_pull_request_get_files,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "pull_number"],
            properties => {
                owner        => { type => "string", description => "Repository owner (user or org)" },
                repo         => { type => "string", description => "Repository name" },
                pull_number  => { type => "number", description => "Pull request number" },
                limit        => { type => "number", description => "Max files (default: 100)" },
            },
        },
    },
    github_pull_request_list_reviews => {
        description => "List reviews and line-level review comments on a pull request",
        handler     => \&tool_github_pull_request_list_reviews,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "pull_number"],
            properties => {
                owner        => { type => "string", description => "Repository owner (user or org)" },
                repo         => { type => "string", description => "Repository name" },
                pull_number  => { type => "number", description => "Pull request number" },
                limit        => { type => "number", description => "Max reviews (default: 50)" },
            },
        },
    },
    github_pull_request_create_review => {
        description => "Create a review on a pull request (requires write scope). Supports APPROVE, REQUEST_CHANGES, and COMMENT events. Note: GitHub does not allow approving your own pull request — use event=COMMENT in that case.",
        handler     => \&tool_github_pull_request_create_review,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "pull_number", "body"],
            properties => {
                owner        => { type => "string", description => "Repository owner (user or org)" },
                repo         => { type => "string", description => "Repository name" },
                pull_number  => { type => "number", description => "Pull request number" },
                body         => { type => "string", description => "Review body text" },
                event        => { type => "string", description => "Review event: APPROVE, REQUEST_CHANGES, COMMENT (default: COMMENT)" },
                comments     => { type => "array", items => {
                    type => "object",
                    properties => {
                        path => { type => "string", description => "File path the comment applies to" },
                        body => { type => "string", description => "Comment text" },
                        line => { type => "number", description => "Line number (optional)" },
                        side => { type => "string", description => "Side: LEFT, RIGHT (optional)" },
                    },
                    required => ["path", "body"],
                }, description => "Optional line-specific comments (array of {path, body, line, side})" },
            },
        },
    },
    github_pull_request_create => {
        description => "Create a pull request. Returns the created PR with full details.",
        handler     => \&tool_github_pull_request_create,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "title", "head", "base"],
            properties => {
                owner => { type => "string", description => "Repository owner (user or org)" },
                repo  => { type => "string", description => "Repository name" },
                title => { type => "string", description => "Pull request title" },
                head  => { type => "string", description => "Head branch name (source)" },
                base  => { type => "string", description => "Base branch name (target)" },
                body  => { type => "string", description => "Pull request body / description (optional)" },
                draft => { type => "boolean", description => "Create as draft PR (optional, default: false)" },
            },
        },
    },
    github_resolve_thread => {
        description => "Resolve a PR review conversation thread via the GitHub GraphQL API. Accepts a thread_id (GraphQL node ID, e.g. TIR_...) and marks the thread as resolved. Returns success/failure with the thread status. Handles already-resolved threads and invalid thread IDs with descriptive error messages.",
        handler     => \&tool_github_resolve_thread,
        inputSchema => {
            type => "object",
            required => ["thread_id"],
            properties => {
                thread_id => { type => "string", description => "GraphQL node ID of the review thread to resolve (e.g. TIR_...)" },
            },
        },
    },
    github_pull_request_merge => {
        description => "Merge a pull request and delete the source branch. Merges via GitHub API and always deletes the source branch afterwards.",
        handler     => \&tool_github_pull_request_merge,
        inputSchema => {
            type => "object",
            required => ["owner", "repo", "pull_number"],
            properties => {
                owner          => { type => "string", description => "Repository owner (user or org)" },
                repo           => { type => "string", description => "Repository name" },
                pull_number    => { type => "number", description => "Pull request number" },
                merge_method   => { type => "string", description => "Merge method: merge (default), squash, rebase" },
                commit_title   => { type => "string", description => "Custom commit title (optional)" },
                commit_message => { type => "string", description => "Custom commit message (optional)" },
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
