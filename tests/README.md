# Tests

Standalone checks for the patches in this tap. Build them against the installed
patched gtk+3:

```sh
clang clipboard-owner-change-test.m -o cliptest -framework Cocoa $(pkgconf --cflags --libs gtk+-3.0)
clang accel-modifier-test.c        -o acceltest                 $(pkgconf --cflags --libs gtk+-3.0)
clang dock-icon-test.m             -o dockicontest -framework Cocoa $(pkgconf --cflags --libs gtk+-3.0)
```

## clipboard-owner-change-test.m — covers gtk3-0002

Posts the Cocoa notifications the patch observes and asserts the resulting
`GtkClipboard::owner-change` behaviour:

1. a foreign copy followed by app activation emits `owner-change` with
   `GDK_OWNER_CHANGE_NEW_OWNER` and the new text;
2. a second activation with an unchanged pasteboard stays silent;
3. `NSWindowDidBecomeKey` works as a trigger too;
4. **when GTK owns the clipboard, activation does not revoke it** — this is the
   regression that would silently break guest-to-host copy.

It posts the notifications itself rather than waiting for real activation,
because a process launched from a non-interactive shell never becomes the
active application. It overwrites the system clipboard, so save and restore it
around the run:

```sh
pbpaste > /tmp/clip && ./cliptest; pbcopy < /tmp/clip
```

## accel-modifier-test.c — covers virt-viewer-0001

Prints the modifier mask `gtk_accelerator_parse()` produces for each
accelerator virt-viewer feeds to `accel_key_to_keys()`, and whether the old and
new masks accept it. On Quartz `<Primary>` yields `GDK_META_MASK` (0x10000000),
which is what the patch adds.

## dock-icon-test.m — covers gtk3-0003

Asserts that realizing a window after `gtk_window_set_default_icon_name()`
replaces the pixels of `[NSApp applicationIconImage]`. Build once and run it
against both gtks — stock fails, patched passes:

```sh
./dockicontest                                                    # -> FAIL
DYLD_LIBRARY_PATH="$(brew --prefix gtk+3-virt-viewer)/lib" ./dockicontest   # -> PASS
```

It compares the rendered TIFF bytes rather than object identity or image size,
because neither is sound here: AppKit keeps handing back the same NSImage
object from `applicationIconImage`, and it re-renders what you give it — the
largest pixbuf GTK loads for `virt-viewer` is 256x256 (`icon_list_from_theme()`
renders scalable icons at 48 and each fixed size at itself), but it comes back
as a 512x512 representation.
