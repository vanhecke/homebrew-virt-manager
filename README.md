homebrew-virt-manager
=====================

A [homebrew][homebrew] tap providing `virt-viewer` on macOS with the patches that
make its SPICE clipboard work.

**This tap provides `virt-viewer` only.** [`virt-manager`][virt-manager] is in
homebrew-core (`brew install virt-manager`); the upstream tap dropped its formula
long ago. The repository keeps its name for continuity with the fork point.

Fork of [jeffreywildman/homebrew-virt-manager][upstream].

## Usage

    brew tap vanhecke/virt-manager
    brew install --build-from-source vanhecke/virt-manager/virt-viewer
    brew pin vanhecke/virt-manager/gtk+3-virt-viewer
    brew pin vanhecke/virt-manager/virt-viewer

**The pins matter.** Without them a later `brew upgrade` replaces these builds with
Homebrew's unpatched bottles and the crash comes back months later with no obvious
cause. `brew list --pinned` will remind you.

## The patches

Stock `remote-viewer` aborts the moment you copy anything in the guest, never pastes
anything from the host, and behaves like a Linux application bolted onto macOS. Each
commit below carries the full analysis — root cause, why the fix is shaped the way it
is, and how it was verified.

Making the clipboard work:

- [**gtk3-0001** — the Quartz event loop aborts on a nested poll][p1] ·
  `gdk/quartz/gdkeventloop-quartz.c` · [GNOME/gtk#2961][gtk2961], closed wontfix
- [**gtk3-0002** — host-to-guest paste never arrives][p2] ·
  `gtk/gtkclipboard-quartz.c` · [GNOME/gtk#1757][gtk1757], open since 2019
- [**gtk3-0003** — no icon in the Dock][p3] ·
  `gdk/quartz/gdkwindow-quartz.c` · unimplemented upstream stub
- [**virt-viewer-0001** — `accel_key_to_keys` warning spam][p4] ·
  `src/virt-viewer-window.c` · not reported upstream

Making it behave like a macOS application:

- [**gtk3-0004** — GTK cannot see the system light/dark appearance][p5] ·
  `gdk/quartz/gdkevents-quartz.c` · another unimplemented upstream `FIXME`
- [**virt-viewer-0002** — dark theme forced on regardless][p6] ·
  `src/virt-viewer-app.c` · outranks every configuration source, so only a patch fixes it
- [**virt-viewer-0003** — native titlebar and macOS menu bar][p7] ·
  `virt-viewer.ui`, `src/virt-viewer-window.c` · drops client-side decoration
- [**virt-viewer-0004** — fullscreen behaves like macOS fullscreen][p8] ·
  `src/virt-viewer-window.c` · no overlay toolbar, guest resizes from the allocation

`patches/` holds the readable, individually rebasable diffs. Each formula carries its
patches concatenated into a single `patch :DATA` block, because Homebrew allows only
one `__END__` per formula. **If you edit anything under `patches/`, regenerate the
matching formula's `__END__` block** — they are not read from disk at build time.

## The patched GTK is private

Two of the patches are GTK bugs, so this tap ships a patched `gtk+3-virt-viewer`. It is
**keg-only**: never linked into the prefix, never on a `pkgconf` path. Your stock
`gtk+3` is untouched and every other GTK app keeps using it.

Only virt-viewer reaches the patched copy, through a wrapper that puts it on
`DYLD_LIBRARY_PATH`. See [the commit][priv] for why that rather than relinking
virt-viewer alone, and [the wrapper commit][wrap] for the SIP behaviour that makes an
`env`-based wrapper silently do nothing.

The two versions must stay in step; a [daily workflow][drift] opens an issue when they
drift, and `tools/sync-gtk-version.sh --bump` does the update.

## Troubleshooting

- **Blank toolbar icons** — install `adwaita-icon-theme`. It is a dependency now, so
  only machines that had `virt-viewer` before that will be missing it. `gtk+3` does not
  pull it in, yet it is where every themed icon the UI asks for lives. Setting
  `XDG_DATA_DIRS` is *not* the fix, contrary to older guides.
- **The guest display is tiny on a Retina screen** — launch with `--zoom=200`. By
  default virt-viewer asks the guest for twice the window's logical size; `--zoom`
  divides by the same factor just before that multiply, so the two cancel and the SPICE
  widget stretches the image 2x instead. `GDK_SCALE` is ignored on macOS — only the X11
  and Win32 backends read it.
- **Debugging** — `remote-viewer --debug --no-fork`. Note that `--debug` alone prints
  nothing: GLib filters debug messages unless `G_MESSAGES_DEBUG=all` is set too.
- **Appearance** — light/dark follows System Settings, the titlebar and window controls
  are drawn by macOS, and the controls live in the menu bar.

## Tests

`tests/` has standalone checks for gtk3-0002, gtk3-0003 and virt-viewer-0001; each
fails against stock gtk and passes against the patched one. gtk3-0001 needs a live
SPICE session, so `tests/ab/` builds two gtk prefixes and swaps them under a real run.
Run `tests/ab/run.sh <variant> --check` before trusting any comparison. See
`tests/README.md`.

## Maintenance

Both kegs are pinned, so editing a formula has no effect until you unpin and reinstall
explicitly — `brew upgrade` skips them silently:

    brew unpin vanhecke/virt-manager/virt-viewer
    HOMEBREW_NO_AUTOREMOVE=1 brew reinstall --build-from-source vanhecke/virt-manager/virt-viewer
    brew pin vanhecke/virt-manager/virt-viewer

`HOMEBREW_NO_AUTOREMOVE=1` is not optional: a plain uninstall/reinstall here has
previously swept away ten unrelated leaf formulae. Bumping `revision` is pointless
while a keg is pinned — the explicit reinstall is what applies changes.

To rebase onto a new upstream release, bump `url`/`sha256`, extract the tarball, apply
each patch with `patch -p1`, fix any rejects, regenerate with `diff -u`, and rebuild.

[homebrew]: http://brew.sh/
[virt-manager]: https://virt-manager.org/
[upstream]: https://github.com/jeffreywildman/homebrew-virt-manager
[p1]: https://github.com/vanhecke/homebrew-virt-manager/commit/f94c82c4876b27a593ed429a425dcb7c118fc304
[p2]: https://github.com/vanhecke/homebrew-virt-manager/commit/c261f4c0e57fdf3a149c2fe847e1a0a41b4788f4
[p3]: https://github.com/vanhecke/homebrew-virt-manager/commit/c2e04501b408575b7994b37c79c3bd0ed295eaa2
[p4]: https://github.com/vanhecke/homebrew-virt-manager/commit/e6fe32bd887f84576820aba779442f25fa7ee3b5
[priv]: https://github.com/vanhecke/homebrew-virt-manager/commit/4ad8d56e026e4769f42d19b1202e61b49c8929e5
[wrap]: https://github.com/vanhecke/homebrew-virt-manager/commit/42833f4a9db40b114011b8473833ab9ded0b9fa2
[drift]: https://github.com/vanhecke/homebrew-virt-manager/commit/d7172dc6ea26813ec01a25f5c817bfbb663db672
[p5]: https://github.com/vanhecke/homebrew-virt-manager/commit/d508a6ef2adb6a5b9aa31bc0bafc8e3a222023f4
[p6]: https://github.com/vanhecke/homebrew-virt-manager/commit/e7ddc1f2045b8f86fb824fed1f2ac77168790323
[p7]: https://github.com/vanhecke/homebrew-virt-manager/commit/2f770a89df75f3a6ebf794337ce3258f29a4be4f
[p8]: https://github.com/vanhecke/homebrew-virt-manager/commit/d07863da4f44766c9f6e0ee1dab9777b5550352a
[gtk2961]: https://gitlab.gnome.org/GNOME/gtk/-/issues/2961
[gtk1757]: https://gitlab.gnome.org/GNOME/gtk/-/issues/1757
