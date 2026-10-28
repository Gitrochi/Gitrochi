#!/usr/bin/env bash
set -euo pipefail

# Check the Linux release artifact itself, without accessing credentials or running a flow.
asset="${1:?usage: verify-linux-asset.sh <asset> <version>}"
version="${2:?usage: verify-linux-asset.sh <asset> <version>}"
[[ $# -eq 2 ]] || { echo "Expected an asset and version." >&2; exit 1; }

fail() { echo "Linux release asset: $*" >&2; exit 1; }
[[ -f "$asset" && -x "$asset" ]] || fail "missing executable: $asset"
directory="$(cd "$(dirname "$asset")" && pwd)"
name="$(basename "$asset")"
asset="$directory/$name"
checksum="$asset.sha256"
[[ -r "$checksum" ]] || fail "missing checksum: $checksum"

header="$(LC_ALL=C readelf -h "$asset")"
program="$(LC_ALL=C readelf -l "$asset")"
dynamic="$(LC_ALL=C readelf -d "$asset")"
grep -Eq 'Class:[[:space:]]+ELF64' <<< "$header" || fail "expected ELF64"
grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' <<< "$header" || fail "expected x86-64"
if grep -Eq '(^|[[:space:]])INTERP([[:space:]]|$)' <<< "$program"; then
    fail "an ELF interpreter is required"
fi
if grep -Eq '\(NEEDED\)' <<< "$dynamic"; then
    fail "a shared library is required"
fi

# build.sh also supports cross-builds, where it cannot require a successful launch; this Linux check must.
actual="$(GITCH_FLOW_NO_KEYSTORE=1 "$asset" version)" || fail "the executable did not run"
[[ "$actual" == "gitch-flow $version" ]] || fail "expected gitch-flow $version, got $actual"

# Only this asset may be named by its sidecar; reject extra entries or paths before checking the bytes.
[[ "$(awk 'END { print NR }' "$checksum")" == 1 ]] || fail "expected one checksum entry"
read -r digest checksum_name extra < "$checksum" || [[ -n "${digest:-}" ]]
[[ "$digest" =~ ^[[:xdigit:]]{64}$ && "${checksum_name#\*}" == "$name" && -z "$extra" ]] || fail "invalid checksum entry"
(cd "$directory" && sha256sum -c "$checksum")
printf 'Verified static Linux x86-64 release asset: %s (%s)\n' "$name" "$actual"
