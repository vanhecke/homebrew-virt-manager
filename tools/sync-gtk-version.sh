#!/bin/bash
# Keep gtk+3-virt-viewer's version in step with Homebrew core's gtk+3.
#
# Why this matters: spice-gtk and gtk-vnc are core bottles, built against core's
# gtk+3, but virt-viewer's wrapper redirects them to our private copy at
# runtime. If core moves ahead and those bottles are rebuilt against a newer
# gtk, they can reference symbols our older private copy does not export, and
# dyld will refuse to launch remote-viewer at all.
#
#   ./tools/sync-gtk-version.sh          # report only
#   ./tools/sync-gtk-version.sh --bump   # rewrite url/sha256 and check patches
set -euo pipefail
cd "$(dirname "$0")/.."
FORMULA="gtk+3-virt-viewer.rb"

json() { brew info --json=v2 "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["formulae"][0]["versions"]["stable"])'; }
core=$(json gtk+3)
ours=$(grep -m1 '^  url ' "$FORMULA" | sed -E 's|.*/gtk-([0-9.]+)\.tar\.xz.*|\1|')

echo "core gtk+3        : $core"
echo "gtk+3-virt-viewer : $ours"

if [ "$core" = "$ours" ]; then
  echo "in step, nothing to do"
  exit 0
fi

echo
echo "VERSION SKEW. remote-viewer may fail to launch after core's spice-gtk or"
echo "gtk-vnc bottles are rebuilt against gtk+3 $core."

if [ "${1:-}" != "--bump" ]; then
  echo "re-run with --bump to update the formula to $core"
  exit 1
fi

series="${core%.*}"
url="https://download.gnome.org/sources/gtk/${series}/gtk-${core}.tar.xz"
echo
echo "fetching $url"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/gtk.tar.xz" "$url"
sha=$(shasum -a 256 "$tmp/gtk.tar.xz" | cut -d' ' -f1)
echo "sha256 $sha"

# Do the patches still apply to the new tarball? Never bump blindly.
tar xf "$tmp/gtk.tar.xz" -C "$tmp"
sed -n '/^__END__$/,$p' "$FORMULA" | tail -n +2 > "$tmp/p.patch"
if ! ( cd "$tmp/gtk-$core" && patch -p1 --dry-run < "$tmp/p.patch" >/dev/null 2>&1 ); then
  echo
  echo "REFUSING TO BUMP: the patches do not apply cleanly to gtk $core."
  echo "Rebase them by hand (see Maintenance in README.md), then re-run."
  ( cd "$tmp/gtk-$core" && patch -p1 --dry-run < "$tmp/p.patch" 2>&1 | head -20 )
  exit 1
fi
echo "patches still apply cleanly"

python3 - "$FORMULA" "$core" "$sha" "$url" <<'PY'
import re, sys
f, ver, sha, url = sys.argv[1:5]
s = open(f).read()
s = re.sub(r'^  url ".*"$', f'  url "{url}"', s, count=1, flags=re.M)
s = re.sub(r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{sha}"', s, count=1, flags=re.M)
open(f, "w").write(s)
PY
echo
echo "formula bumped to $core. Now:"
echo "  brew unpin vanhecke/virt-manager/gtk+3-virt-viewer"
echo "  brew reinstall --build-from-source vanhecke/virt-manager/gtk+3-virt-viewer"
echo "  brew pin vanhecke/virt-manager/gtk+3-virt-viewer"
