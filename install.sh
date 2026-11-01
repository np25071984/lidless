#!/bin/sh
# Installs or upgrades lidless from its latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/np25071984/lidless/main/install.sh | sh
#
# Downloads the release, checks its checksum, installs the binary to
# ~/.local/bin/lidless and starts (or restarts) the service. Running it again
# upgrades. Nothing else on the system is touched.
#
#   LIDLESS_VERSION=v0.2.0   install that release instead of the latest
#   LIDLESS_PREFIX=/opt/x    install to /opt/x/bin/lidless instead of ~/.local/bin
set -eu

repo="np25071984/lidless"
asset="lidless-macos.tar.gz"
prefix="${LIDLESS_PREFIX:-$HOME/.local}"
target="$prefix/bin/lidless"

fail() { echo "lidless install: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "lidless runs on macOS only"
command -v curl >/dev/null || fail "curl is required"

if [ -n "${LIDLESS_VERSION:-}" ]; then
  url="https://github.com/$repo/releases/download/$LIDLESS_VERSION/$asset"
else
  url="https://github.com/$repo/releases/latest/download/$asset"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

echo "downloading $url"
curl -fsSL -o "$work/$asset" "$url" || fail "download failed"
curl -fsSL -o "$work/$asset.sha256" "$url.sha256" || fail "checksum download failed"
(cd "$work" && shasum -a 256 -c "$asset.sha256" >/dev/null 2>&1) || fail "checksum does not match"

tar -xzf "$work/$asset" -C "$work" lidless || fail "unexpected archive contents"
codesign --verify --strict "$work/lidless" 2>/dev/null || fail "the binary's signature is invalid"

mkdir -p "$prefix/bin"
# Replaced by rename, never rewritten in place: rewriting a signed binary in
# place while it runs can get it killed.
cp "$work/lidless" "$target.new"
chmod 755 "$target.new"
mv -f "$target.new" "$target"
echo "installed $target ($("$target" version))"

"$target" restart

case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo
     echo "note: $prefix/bin is not on your PATH. Add it, or call $target directly." ;;
esac
