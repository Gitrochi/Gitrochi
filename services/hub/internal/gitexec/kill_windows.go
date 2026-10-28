//go:build windows

package gitexec

import (
	"os/exec"
	"strconv"
	"syscall"
)

// createNoWindow keeps a console window from opening for each process.
const createNoWindow = 0x08000000

// killTree ends the helpers git starts (ssh, git-remote-https) together
// with git: taskkill /T walks the process tree.
func killTree(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow, HideWindow: true}
	cmd.Cancel = func() error {
		kill := exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(cmd.Process.Pid))
		kill.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow, HideWindow: true}
		if err := kill.Run(); err != nil {
			return cmd.Process.Kill()
		}
		return nil
	}
}
