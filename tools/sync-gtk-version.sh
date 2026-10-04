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
#
# A matching version is not the whole check. Core ships same-version backport
# patches (gtk+3 3.24.52 revision 1 fixed two macOS focus regressions) and the
# wrapper redirects virt-viewer onto our copy, so a missing backport is a bug stock
# gtk+3 no longer has. Those patch URLs are compared here too.
set -euo pipefail
cd "$(dirname "$0")/.."
FORMULA="gtk+3-virt-viewer.rb"
CORE_FORMULA_URL="https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/g/gtk+3.rb"

json() { brew info --json=v2 "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["formulae"][0]["versions"]["stable"])'; }
# Commit-patch URLs only. The tarball url is a different line and must not match.
# grep exits 1 when a formula has no backport patches. That is a normal result,
# not a failed check, so the empty match must not trip set -e / pipefail.
patch_urls() {
  { grep -E '^[[:space:]]*url "https://github.com/GNOME/gtk/commit/' "$1" || true; } \
    | sed -E 's/.*"([^"]+)".*/\1/' | sort
}

core=$(json gtk+3)
ours=$(grep -m1 '^  url ' "${FORMULA}" | sed -E 's|.*/gtk-([0-9.]+)\.tar\.xz.*|\1|')

echo "core gtk+3        : ${core}"
echo "gtk+3-virt-viewer : ${ours}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "${tmp}/core.rb" "${CORE_FORMULA_URL}"
patch_urls "${tmp}/core.rb" >"${tmp}/core-patches.txt"
patch_urls "${FORMULA}" >"${tmp}/ours-patches.txt"

if [[ "${core}" = "${ours}" ]]
then
  if cmp -s "${tmp}/core-patches.txt" "${tmp}/ours-patches.txt"
  then
    echo "in step, nothing to do"
    exit 0
  fi
  echo
  echo "VERSION MATCHES, BACKPORT PATCHES DO NOT."
  echo "The wrapper redirects spice-gtk and gtk-vnc onto this copy, so virt-viewer"
  echo "keeps whatever those patches fix."
  echo
  echo "In core's gtk+3, missing here:"
  comm -13 "${tmp}/ours-patches.txt" "${tmp}/core-patches.txt" | sed 's/^/  /'
  echo "Here, but not in core's gtk+3:"
  comm -23 "${tmp}/ours-patches.txt" "${tmp}/core-patches.txt" | sed 's/^/  /'
  echo
  echo "Copy the patch do blocks from homebrew-core's Formula/g/gtk+3.rb."
  echo "--bump will not do this; the tarball is unchanged."
  exit 1
fi

echo
echo "VERSION SKEW. remote-viewer may fail to launch after core's spice-gtk or"
echo "gtk-vnc bottles are rebuilt against gtk+3 ${core}."

if [[ "${1:-}" != "--bump" ]]
then
  echo "re-run with --bump to update the formula to ${core}"
  exit 1
fi

series="${core%.*}"
url="https://download.gnome.org/sources/gtk/${series}/gtk-${core}.tar.xz"
echo
echo "fetching ${url}"
curl -fsSL -o "${tmp}/gtk.tar.xz" "${url}"
sha=$(shasum -a 256 "${tmp}/gtk.tar.xz" | cut -d' ' -f1)
echo "sha256 ${sha}"

# Do the patches still apply to the new tarball? Never bump blindly.
# Backport patch do blocks are applied first, in formula order, because a later
# one can depend on an earlier one. Then the __END__ data patch.
tar xf "${tmp}/gtk.tar.xz" -C "${tmp}"
n=0
while IFS= read -r patch_url
do
  [[ -z "${patch_url}" ]] && continue
  n=$((n + 1))
  curl -fsSL -o "${tmp}/backport-${n}.patch" "${patch_url}"
  if ! (cd "${tmp}/gtk-${core}" && patch -p1 --dry-run <"${tmp}/backport-${n}.patch" >/dev/null 2>&1)
  then
    echo
    echo "REFUSING TO BUMP: backport patch does not apply to gtk ${core}:"
    echo "  ${patch_url}"
    echo "It is probably already in this release. Remove that patch do block"
    echo "(and revision, if it only existed for the backport) and re-run."
    (cd "${tmp}/gtk-${core}" && patch -p1 --dry-run <"${tmp}/backport-${n}.patch" 2>&1 | head -20)
    exit 1
  fi
  (cd "${tmp}/gtk-${core}" && patch -p1 <"${tmp}/backport-${n}.patch" >/dev/null)
done <"${tmp}/ours-patches.txt"

sed -n '/^__END__$/,$p' "${FORMULA}" | tail -n +2 >"${tmp}/p.patch"
if ! (cd "${tmp}/gtk-${core}" && patch -p1 --dry-run <"${tmp}/p.patch" >/dev/null 2>&1)
then
  echo
  echo "REFUSING TO BUMP: the patches do not apply cleanly to gtk ${core}."
  echo "Rebase them by hand (see Maintenance in README.md), then re-run."
  (cd "${tmp}/gtk-${core}" && patch -p1 --dry-run <"${tmp}/p.patch" 2>&1 | head -20)
  exit 1
fi
echo "patches still apply cleanly"

python3 - "${FORMULA}" "${sha}" "${url}" <<'PY'
import re, sys
f, sha, url = sys.argv[1:4]
s = open(f).read()
s = re.sub(r'^  url ".*"$', f'  url "{url}"', s, count=1, flags=re.M)
s = re.sub(r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{sha}"', s, count=1, flags=re.M)
# The comment marker is the contract with gtk+3-virt-viewer.rb. A revision that
# survives means the marker moved and the bumped formula would still claim the
# old same-version rebuild.
s, _ = re.subn(
    r'^  # Same-version rebuild for the macOS focus backports below\..*(?:\n  #.*)*\n  revision \d+\n',
    '',
    s,
    count=1,
    flags=re.M,
)
if re.search(r'^  revision \d+$', s, re.M):
    sys.exit('revision line survived the bump; the comment marker moved')
open(f, "w").write(s)
PY
echo
echo "formula bumped to ${core}. Now:"
echo "  brew unpin vanhecke/virt-manager/gtk+3-virt-viewer"
echo "  brew reinstall --build-from-source vanhecke/virt-manager/gtk+3-virt-viewer"
echo "  brew pin vanhecke/virt-manager/gtk+3-virt-viewer"
