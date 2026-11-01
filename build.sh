#!/bin/bash
# Builds the `lidless` binary into build/.
#
#   ./build.sh                          build for this Mac's architecture
#   ./build.sh --universal              Apple Silicon and Intel in one binary,
#                                       as releases are
#   ./build.sh --install [--prefix P]   also install to P/bin/lidless (default
#                                       ~/.local) and start or restart the service
#
# lidless needs no privacy permission, so an ad-hoc signature is all it needs:
# Apple Silicon runs nothing unsigned, and the signature is per build.
set -euo pipefail

cd "$(dirname "$0")"

prefix="$HOME/.local"
install=false
archs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --install) install=true ;;
    --universal) archs=(--arch arm64 --arch x86_64) ;;
    --prefix) prefix="${2:?--prefix needs a directory}"; shift ;;
    --prefix=*) prefix="${1#--prefix=}" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
target="$prefix/bin/lidless"

swift build -c release ${archs[@]+"${archs[@]}"}
mkdir -p build
cp "$(swift build -c release ${archs[@]+"${archs[@]}"} --show-bin-path)/lidless" build/lidless
codesign --force --identifier lidless --sign - build/lidless
echo "built $PWD/build/lidless ($(build/lidless version), $(lipo -archs build/lidless))"

$install || exit 0

mkdir -p "$prefix/bin"
# Replaced by rename, never rewritten in place: rewriting a signed binary in
# place while it runs can get it killed.
cp build/lidless "$target.new"
mv -f "$target.new" "$target"
echo "installed $target"

"$target" restart
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "note: $prefix/bin is not on your PATH" ;;
esac
