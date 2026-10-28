//go:build !unix && !windows

package gitexec

import "os/exec"

// killTree keeps the default: cancellation kills the child only.
func killTree(*exec.Cmd) {}
