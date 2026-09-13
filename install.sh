#!/bin/sh
set -eu

usage() {
    printf '%s\n' \
        'Usage: ./install.sh [-prefix directory] [-version version]' \
        'Defaults: prefix=/usr/local, version=0.3.0'
}

fail() {
    printf 'flux installer: %s\n' "$1" >&2
    exit 1
}

invocation_root=$(pwd -P)
install_prefix=/usr/local
release_version=0.3.0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -help|-h) usage; exit 0 ;;
        -prefix|-version)
            [ "$#" -ge 2 ] || fail "missing option value"
            [ -n "$2" ] || fail "empty option value"
            case "$1" in
                -prefix) install_prefix=$2 ;;
                -version) release_version=$2 ;;
            esac
            shift 2
            ;;
        *) usage >&2; fail "unknown option" ;;
    esac
done

case "$install_prefix" in /*) ;; *) install_prefix="$invocation_root/$install_prefix" ;; esac
printf '%s\n' "$release_version" | grep -Eq '^(0|[1-9][0-9]*)\.[0-9]\.[0-9]$' || fail "invalid version"
case "$(uname -s)" in
    Darwin) operating_system=apple-darwin ;;
    Linux) operating_system=unknown-linux-musl ;;
    *) fail "unsupported operating system" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) architecture=aarch64 ;;
    x86_64|amd64) architecture=x86_64 ;;
    *) fail "unsupported architecture" ;;
esac
command -v curl >/dev/null 2>&1 || fail "curl is required"
if command -v shasum >/dev/null 2>&1; then
    checksum_command=shasum
elif command -v sha256sum >/dev/null 2>&1; then
    checksum_command=sha256sum
else
    fail "shasum or sha256sum is required"
fi
binary_directory="$install_prefix/bin"
mkdir -p "$binary_directory"
[ ! -e "$binary_directory/flux" ] && [ ! -L "$binary_directory/flux" ] || fail "flux is already installed"
binary_temporary=
checksum_temporary=
cleanup() {
    if [ -n "$binary_temporary" ]; then rm -f "$binary_temporary"; fi
    if [ -n "$checksum_temporary" ]; then rm -f "$checksum_temporary"; fi
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

binary_temporary=$(mktemp "$binary_directory/.flux-install.XXXXXX")
checksum_temporary=$(mktemp "$binary_directory/.flux-checksum.XXXXXX")
asset="flux-$architecture-$operating_system"
release_url="https://github.com/Hexadecimall/Flux/releases/download/v$release_version"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --output "$binary_temporary" "$release_url/$asset" || fail "download failed"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --output "$checksum_temporary" "$release_url/$asset.sha256" || fail "checksum download failed"
expected_checksum=$(awk 'NR == 1 { print $1 }' "$checksum_temporary")
printf '%s\n' "$expected_checksum" | grep -Eq '^[0-9a-f]{64}$' || fail "invalid checksum"
if [ "$checksum_command" = shasum ]; then
    checksum_output=$(shasum -a 256 "$binary_temporary") || fail "checksum failed"
else
    checksum_output=$(sha256sum "$binary_temporary") || fail "checksum failed"
fi
actual_checksum=${checksum_output%% *}
[ "$actual_checksum" = "$expected_checksum" ] || fail "checksum mismatch"
chmod 755 "$binary_temporary"
installed_version=$("$binary_temporary" version) || fail "executable failed"
[ "$installed_version" = "Flux $release_version" ] || fail "version mismatch"
ln "$binary_temporary" "$binary_directory/flux" || fail "could not install flux"
printf '%s\n' 'Installed flux.'
