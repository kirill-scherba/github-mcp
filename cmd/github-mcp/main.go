// Copyright 2026 Kirill Scherba. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// github-mcp as a single binary.
//
// The server itself is a Perl program (github-mcp.pl, embedded below); this wrapper runs it on a Perl
// interpreter compiled into the executable, so a machine needs nothing installed - no Perl, no CPAN,
// no configuration of an interpreter. The same source builds for Linux and Windows, and both read
// their settings from the environment the MCP host passes to this process.
//
// The sandbox is deliberate: the guest sees exactly the environment it was given, only the filesystem
// it needs (the real one, because the server writes request bodies to temp files), and may spawn only
// curl - the network is reached through that subprocess, never from the interpreter's own sockets.
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	perl "github.com/goccy/go-perl"

	githubmcp "github.com/kirill-scherba/github-mcp"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "github-mcp: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	// The guest works on the real filesystem, exactly like `perl github-mcp.pl` would: the server asks
	// curl to write responses to files, and those files have to be the same ones both sides see. A
	// private filesystem here would mean curl writes to the host while the script reads its own memory
	// (curl exit 23 / empty responses, found the hard way).
	stdlib, err := perl.ExtractStdlib()
	if err != nil {
		return err
	}
	defer os.RemoveAll(stdlib)

	scriptPath, err := os.CreateTemp("", "github-mcp-*.pl")
	if err != nil {
		return err
	}
	if _, err := scriptPath.Write(githubmcp.Script); err != nil {
		scriptPath.Close()
		return err
	}
	if err := scriptPath.Close(); err != nil {
		return err
	}
	defer os.Remove(scriptPath.Name())

	// A private directory for the script and for curl's temporary files: the guest and the host then
	// agree on one place, and nothing of the user's is touched.
	workDir, err := os.MkdirTemp("", "github-mcp-work-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(workDir)
	scriptName := filepath.Join(workDir, "github-mcp.pl")
	if err := os.WriteFile(scriptName, githubmcp.Script, 0o600); err != nil {
		return err
	}

	// Slashes, not backslashes: the guest builds its temp paths with File::Spec (which uses "/") and
	// passes them to curl, so a path with mixed separators reaches the child as-is. curl then fails to
	// create the file (exit 23) on Windows.
	slashWork := filepath.ToSlash(workDir)
	env := append([]string{}, os.Environ()...)
	env = append(env, "TMPDIR="+slashWork, "TMP="+slashWork, "TEMP="+slashWork,
		"GITHUB_MCP_TMPDIR="+slashWork)

	p, err := perl.New(perl.Config{
		FS:        hostFS{},
		StdlibDir: filepath.ToSlash(stdlib),
		Env:       env, // whatever the MCP host passed: tokens never live on the host system
		Stdin:     os.Stdin,
		Stdout:    os.Stdout,
		Stderr:    os.Stderr,
		Exec: func(path string, argv []string) bool {
			if os.Getenv("GITLAB_MCP_DEBUG_FS") != "" {
				fmt.Fprintf(os.Stderr, "exec: %s %q\n", path, argv)
			}
			switch strings.ToLower(filepath.Base(path)) {
			case "curl", "curl.exe":
				return true
			}
			fmt.Fprintf(os.Stderr, "github-mcp: refusing to run %q\n", path)
			return false
		},
		Dial:    func(network, host, ip string, port int) bool { return false },
		Resolve: func(host string) bool { return false },
	})
	if err != nil {
		return err
	}
	defer p.Close()

	// The server runs from source, not from a file: the guest cannot open a host path (the library
	// resolves `do $path` outside the configured filesystem), while open() calls the script makes later
	// do go through it. The launcher is defined once, then called - Eval would capture the output, Call
	// streams it, which is what an MCP server on stdio needs.
	if _, err := p.Eval(context.Background(), runSourceGlue); err != nil {
		return err
	}
	args := make([]perl.Value, 0, len(os.Args))
	args = append(args, perl.ValueOf(string(githubmcp.Script)))
	for _, a := range os.Args[1:] {
		args = append(args, perl.ValueOf(a))
	}
	_, err = p.Call(context.Background(), "__run_source", args...)
	return err
}

// runSourceGlue runs a Perl program given as text, with @ARGV set, without capturing its output.
const runSourceGlue = `
sub main::__run_source {
    my ($src, @args) = @_;
    local @ARGV = @args;
    my $ok = eval $src;
    die $@ if $@;
    return $ok;
}
1;
`
