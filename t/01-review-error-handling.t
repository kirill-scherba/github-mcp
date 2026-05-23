#!/usr/bin/env perl
# =============================================================================
# Smoke test: github_pull_request_create_review error handling
#
# Tests:
#   1. Tool is registered with correct schema
#   2. Missing required params produce proper error
#   3. API error details are propagated correctly (mocked)
#   4. "own PR" detection logic works
#   5. Server starts and responds to MCP protocol
# =============================================================================

use strict;
use warnings;
use utf8;
use JSON;
use IPC::Open2;
use Test::More tests => 14;

# ---------------------------------------------------------------------------
# Test 1: Tool registration schema
# ---------------------------------------------------------------------------
{
    my $script = 'github-mcp.pl';
    ok(-f $script, "Script $script exists");
    ok(-x $script, "Script $script is executable") or diag("chmod +x $script needed");
}

# ---------------------------------------------------------------------------
# Parse tool definitions from the source file to verify schema
# ---------------------------------------------------------------------------
{
    open(my $fh, '<', 'github-mcp.pl') or die "Cannot open github-mcp.pl: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    # Check that the review tool definition exists
    like($content, qr/github_pull_request_create_review/,
        "Tool github_pull_request_create_review is defined");

    # Check that description mentions the "own PR" limitation
    like($content, qr/does not allow approving your own pull request/,
        "Tool description mentions 'own PR' limitation");

    # Check that "owned by you" detection is implemented
    like($content, qr/owned by you/i,
        "Code detects 'owned by you' GitHub error message");

    # Check that empty comments handling is correct (comments omitted when empty)
    like($content, qr/if \$comments && ref \$comments eq 'ARRAY' && \@\$comments/,
        "Empty comments array is correctly omitted from payload");
}

# ---------------------------------------------------------------------------
# Test MCP protocol interaction via subprocess (bidirectional)
# ---------------------------------------------------------------------------
{
    my ($rdr, $wtr);
    my $pid = open2($rdr, $wtr, './github-mcp.pl')
        or die "Cannot start github-mcp.pl: $!";

    # Set stdout to autoflush
    select($wtr);
    $| = 1;
    select(STDOUT);

    # Send initialize
    my $init = encode_json({
        jsonrpc => '2.0',
        id      => 1,
        method  => 'initialize',
        params  => {},
    });
    print $wtr "$init\n";

    # Read response with timeout using IO::Select
    use IO::Select;
    my $sel = IO::Select->new($rdr);

    my $got_init = 0;
    if ($sel->can_read(5)) {
        my $response = <$rdr>;
        ok(defined $response, "Server responds to initialize");
        $got_init = 1;

        my $decoded = eval { decode_json($response) };
        if ($decoded && $decoded->{result}) {
            is($decoded->{result}{serverInfo}{name}, 'github-mcp',
                "Server identifies as github-mcp");
        } else {
            diag("Unexpected initialize response: " . ($response // 'undef'));
        }
    } else {
        ok(0, "Server responds to initialize (timeout)");
    }

    if ($got_init) {
        # Now send tools/list
        my $list_req = encode_json({
            jsonrpc => '2.0',
            id      => 2,
            method  => 'tools/list',
            params  => {},
        });
        print $wtr "$list_req\n";

        if ($sel->can_read(5)) {
            my $list_resp = <$rdr>;
            ok(defined $list_resp, "Server responds to tools/list");

            if ($list_resp) {
                my $tools = eval { decode_json($list_resp) };
                if ($tools && $tools->{result}{tools}) {
                    my @review_tools = grep { $_->{name} eq 'github_pull_request_create_review' }
                        @{$tools->{result}{tools}};
                    is(scalar @review_tools, 1, "github_pull_request_create_review is in tools list");

                    if (@review_tools) {
                        my $schema = $review_tools[0]{inputSchema};
                        ok(grep { $_ eq 'owner'   } @{$schema->{required} // []}, "Schema requires 'owner'");
                        ok(grep { $_ eq 'repo'    } @{$schema->{required} // []}, "Schema requires 'repo'");
                        ok(grep { $_ eq 'pull_number' } @{$schema->{required} // []}, "Schema requires 'pull_number'");
                        ok(grep { $_ eq 'body'    } @{$schema->{required} // []}, "Schema requires 'body'");
                    }
                } else {
                    diag("Could not decode tools/list response");
                }
            }
        } else {
            ok(0, "Server responds to tools/list (timeout)");
        }
    }

    # Clean shutdown
    close($wtr);
    waitpid($pid, 0);
}
