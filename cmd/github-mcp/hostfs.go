// Copyright 2026 Kirill Scherba. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	perl "github.com/goccy/go-perl"
)

// hostFS is the real filesystem, addressed the way the guest asks for it.
//
// The guest names files as guest paths without a leading slash ("tmp/x", "strict.pm"); the library's
// own host backend joins them to "/" and that is fine on Linux, but a Windows path built that way
// ("/tmp/x") lands on a drive-relative name and the server cannot even read its standard library.
// This backend turns a guest name into a host path, and knows about drive letters.
type hostFS struct{}

// guestPath turns a guest name into a path the operating system opens.
func guestPath(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "/"
	}
	if runtime.GOOS != "windows" {
		if strings.HasPrefix(name, "/") {
			return name
		}
		return "/" + name
	}
	// "C:/Users/x" arrives with or without a leading slash; both mean the same file on Windows.
	trimmed := strings.TrimPrefix(name, "/")
	if len(trimmed) >= 2 && trimmed[1] == ':' {
		return filepath.FromSlash(trimmed)
	}
	return filepath.FromSlash("/" + trimmed)
}

func (hostFS) OpenFile(name string, flag int, perm fs.FileMode) (perl.File, error) {
	if os.Getenv("GITLAB_MCP_DEBUG_FS") != "" {
		println("open:", name, "->", guestPath(name))
	}
	return os.OpenFile(guestPath(name), flag, perm)
}

func (hostFS) Mkdir(name string, perm fs.FileMode) error { return os.Mkdir(guestPath(name), perm) }
func (hostFS) Remove(name string) error                  { return os.Remove(guestPath(name)) }
func (hostFS) Rename(oldName, newName string) error {
	return os.Rename(guestPath(oldName), guestPath(newName))
}
func (hostFS) Stat(name string) (os.FileInfo, error)  { return os.Stat(guestPath(name)) }
func (hostFS) Lstat(name string) (os.FileInfo, error) { return os.Lstat(guestPath(name)) }
func (hostFS) Readlink(name string) (string, error)   { return os.Readlink(guestPath(name)) }
func (hostFS) Chmod(name string, mode fs.FileMode) error {
	return os.Chmod(guestPath(name), mode)
}

// Windows has no POSIX links for an ordinary user; the server never creates them.
func (hostFS) Symlink(oldName, newName string) error {
	return &fs.PathError{Op: "symlink", Path: newName, Err: os.ErrInvalid}
}
func (hostFS) Link(oldName, newName string) error {
	return &fs.PathError{Op: "link", Path: newName, Err: os.ErrInvalid}
}
