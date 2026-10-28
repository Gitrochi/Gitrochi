// Command gitrochi-hub is Gitrochi's team collaboration server and
// repository monitoring daemon in one static binary. See README.md.
package main

import (
	"os"

	"github.com/Gitrochi/Gitrochi/services/hub/internal/cli"
)

// version is set at build time with -ldflags "-X main.version=…".
var version = "dev"

func main() {
	os.Exit(cli.Main(os.Args[1:], os.Stdout, os.Stderr, version))
}
