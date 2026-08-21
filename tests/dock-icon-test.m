/*
 * Covers gtk3-0003-quartz-dock-icon.patch.
 *
 * gdk_quartz_window_set_icon_list() is an empty stub upstream, so the icon a
 * GTK application sets never reaches the Dock. The patch maps the window icon
 * onto the application icon. This asserts that realizing a window after
 * gtk_window_set_default_icon_name() actually replaces the pixels of
 * [NSApp applicationIconImage].
 *
 * The comparison is on the rendered bytes, not on object identity or on size:
 * AppKit keeps returning the same NSImage object from applicationIconImage and
 * re-renders whatever you hand it (a 256x256 pixbuf comes back as a 512x512
 * representation), so neither pointer nor dimensions are a sound signal.
 *
 * Build once, run against both gtks:
 *   clang dock-icon-test.m -o dockicontest -framework Cocoa \
 *       $(pkgconf --cflags --libs gtk+-3.0)
 *   ./dockicontest                                              # stock gtk -> FAIL
 *   DYLD_LIBRARY_PATH="$(brew --prefix gtk+3-virt-viewer)/lib" \
 *       ./dockicontest                                          # patched   -> PASS
 */
#include <gtk/gtk.h>
#import <AppKit/AppKit.h>

#define ICON_NAME "virt-viewer"

static NSData *
snapshot (NSImage *image)
{
    if (image == nil)
        return nil;
    /* TIFFRepresentation renders the current representations into a fresh
     * buffer, so this survives AppKit mutating the image in place.
     */
    return [[image TIFFRepresentation] copy];
}

static void
describe (const char *label, NSImage *image, NSData *bytes)
{
    if (image == nil) {
        g_print ("  %-7s (nil)\n", label);
        return;
    }
    NSArray *reps = [image representations];
    long w = 0, h = 0;
    if ([reps count] > 0) {
        NSImageRep *rep = [reps objectAtIndex:0];
        w = (long) [rep pixelsWide];
        h = (long) [rep pixelsHigh];
    }
    g_print ("  %-7s %ldx%ld, %lu byte(s) of TIFF\n", label, w, h,
             (unsigned long) (bytes ? [bytes length] : 0));
}

int
main (int argc, char **argv)
{
    gtk_init (&argc, &argv);

    if (!gtk_icon_theme_has_icon (gtk_icon_theme_get_default (), ICON_NAME)) {
        g_print ("SKIP: the '%s' icon is not in the icon theme; is virt-viewer installed?\n",
                 ICON_NAME);
        return 77;
    }

    NSImage *icon = [NSApp applicationIconImage];
    NSData *before = snapshot (icon);

    g_print ("application icon\n");
    describe ("before", icon, before);

    gtk_window_set_default_icon_name (ICON_NAME);

    GtkWidget *window = gtk_window_new (GTK_WINDOW_TOPLEVEL);
    gtk_widget_realize (window);

    icon = [NSApp applicationIconImage];
    NSData *after = snapshot (icon);
    describe ("after", icon, after);

    gboolean ok = (after != nil) && (before == nil || ![after isEqualToData:before]);

    g_print ("\n  pixels changed: %s\n", ok ? "yes" : "no");
    g_print ("\nRESULT: %s\n", ok ? "PASS" : "FAIL");

    [before release];
    [after release];
    return ok ? 0 : 1;
}
