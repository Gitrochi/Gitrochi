#!/usr/bin/env bash
# Builds gitrochi-hub as a static binary: for this machine into dist/, or
# with --all for every release target (plus dist/SHA256SUMS). --check first
# runs gofmt, go vet and the race-enabled tests.
#   services/hub/build.sh [--all] [--check]
# Go comes from $GITROCHI_GO, else the repository's .build/go-tools
# toolchain, else go on PATH. VERSION overrides the stamped version.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

all=0
check=0
for arg in "$@"; do
  case $arg in
    --all) all=1 ;;
    --check) check=1 ;;
    -h | --help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "build.sh: unknown option $arg (use --all, --check)" >&2
      exit 2
      ;;
  esac
done

# The project-local toolchain lives in the main checkout; a linked worktree
# reaches it through the shared git directory.
find_go() {
  if [ -n "${GITROCHI_GO:-}" ]; then
    echo "$GITROCHI_GO"
    return
  fi
  local common dir
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null || true)
  case $common in
    "" | /* | [A-Za-z]:*) ;;
    *) common="$root/$common" ;;
  esac
  for dir in "$root" "${common:+$(dirname "$common")}"; do
    if [ -n "$dir" ] && [ -x "$dir/.build/go-tools/go/bin/go" ]; then
      echo "$dir/.build/go-tools/go/bin/go"
      return
    fi
  done
  if command -v go >/dev/null 2>&1; then
    command -v go
    return
  fi
  echo "build.sh: no Go toolchain found; set GITROCHI_GO" >&2
  exit 1
}

GO=$(find_go)
case $GO in
  */.build/go-tools/go/bin/go)
    # Keep the project toolchain's caches next to it, as the other tools do.
    tools=${GO%/go/bin/go}
    export GOPATH=${GOPATH:-$tools/gopath}
    export GOMODCACHE=${GOMODCACHE:-$tools/gopath/pkg/mod}
    export GOCACHE=${GOCACHE:-$tools/cache}
    ;;
esac
# The module has no dependencies: never download a toolchain or a module.
export GOTOOLCHAIN=${GOTOOLCHAIN:-local}
export GOPROXY=${GOPROXY:-off}

version=${VERSION:-$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)}
ldflags="-s -w -X main.version=$version"
cd "$here"
echo "gitrochi-hub $version with $("$GO" version)"

if [ $check -eq 1 ]; then
  gofmt_bin="$(dirname "$GO")/gofmt"
  [ -x "$gofmt_bin" ] || gofmt_bin=gofmt
  unformatted=$("$gofmt_bin" -l .)
  if [ -n "$unformatted" ]; then
    echo "build.sh: gofmt would change:" >&2
    echo "$unformatted" >&2
    exit 1
  fi
  "$GO" vet ./...
  GOOS=windows "$GO" vet ./...
  "$GO" test -race ./...
fi

build() { # GOOS GOARCH OUTPUT
  echo "  $1/$2 -> services/hub/$3"
  CGO_ENABLED=0 GOOS=$1 GOARCH=$2 "$GO" build -trimpath -ldflags "$ldflags" -o "$3" ./cmd/gitrochi-hub
}

mkdir -p dist
if [ $all -eq 1 ]; then
  for target in linux/amd64 linux/arm64 darwin/arm64 darwin/amd64 windows/amd64; do
    os=${target%/*}
    arch=${target#*/}
    ext=""
    if [ "$os" = windows ]; then
      ext=.exe
    fi
    build "$os" "$arch" "dist/gitrochi-hub-$os-$arch$ext"
  done
  (
    cd dist
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum gitrochi-hub-* >SHA256SUMS
    else
      shasum -a 256 gitrochi-hub-* >SHA256SUMS
    fi
  )
  echo "  checksums -> services/hub/dist/SHA256SUMS"
else
  os=$("$GO" env GOOS)
  ext=""
  if [ "$os" = windows ]; then
    ext=.exe
  fi
  build "$os" "$("$GO" env GOARCH)" "dist/gitrochi-hub$ext"
fi
