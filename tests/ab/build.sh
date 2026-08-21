#!/usr/bin/env bash
# Build gtk+3 3.24.52 into ./patched and ./vanilla for side-by-side testing.
# Does not touch the Homebrew keg.
set -euo pipefail
cd "$(dirname "$0")"
BASE="$PWD"

# Take the patch straight from the formula that Homebrew installs, so the A/B
# comparison always tests exactly what the tap ships.
TAP="$(brew --repository vanhecke/virt-manager)"
sed -n '/^__END__$/,$p' "$TAP/gtk+3-virt-viewer.rb" | tail -n +2 > gtk3.patch
echo "patch refreshed from $TAP/gtk+3.rb ($(grep -c '^@@' gtk3.patch) hunks)"

# Fetch the tarball on first run.
[ -f gtk-3.24.52.tar.xz ] || curl -fLO https://download.gnome.org/sources/gtk/3.24/gtk-3.24.52.tar.xz

# Homebrew's gettext is keg-only and ships no .pc file, so meson cannot find
# libintl on its own and silently falls back to downloading a subproject.
# Point it at the keg and forbid downloads so a miss is a hard error.
GETTEXT="$(brew --prefix gettext)"
HB="$(brew --prefix)"

ARGS=(
  --buildtype=release
  --wrap-mode=nodownload
  # -I$HB/include is what Homebrew's compiler shim adds; gtk includes
  # <cairo/cairo-quartz.h>, which cairo's own pkg-config -I does not satisfy.
  "-Dc_args=-I$GETTEXT/include -I$HB/include"
  "-Dc_link_args=-L$GETTEXT/lib -L$HB/lib"
  -Dgtk_doc=false -Dman=false -Dintrospection=false
  -Dtests=false -Ddemos=false -Dexamples=false
  -Dquartz_backend=true -Dx11_backend=false
)

build() {
  local name=$1 apply=$2
  echo "=== $name ==="
  rm -rf "src-$name" "$name"
  tar xf gtk-3.24.52.tar.xz
  mv gtk-3.24.52 "src-$name"
  if [ "$apply" = yes ]; then
    ( cd "src-$name" && patch -p1 < "$BASE/gtk3.patch" )
  fi
  ( cd "src-$name" \
    && meson setup build --prefix="$BASE/$name" "${ARGS[@]}" \
    && meson compile -C build > "$BASE/compile-$name.log" 2>&1 \
    && meson install -C build > "$BASE/install-$name.log" 2>&1 )
  echo "installed -> $BASE/$name/lib"
  ls -l "$BASE/$name/lib/libgtk-3.0.dylib" "$BASE/$name/lib/libgdk-3.0.dylib"
}

build vanilla no
build patched yes
