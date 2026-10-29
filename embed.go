// Copyright 2026 Kirill Scherba. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Package githubmcp carries the Perl source of the server, so the binary and the script can never
// drift apart: both are built from this repository in one step.
package githubmcp

import _ "embed"

// Script is github-mcp.pl, embedded at build time.
//
//go:embed github-mcp.pl
var Script []byte
