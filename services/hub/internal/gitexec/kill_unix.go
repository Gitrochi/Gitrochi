//go:build unix

package gitexec

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

// killTree starts the child in a new session: git and the helpers it starts
// (ssh, remote helpers) share one process group that can be killed at once,
// and none of them has a terminal to prompt on.
func killTree(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Cancel = func() error {
		// The child leads its group; a negative pid signals the whole group.
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
}
