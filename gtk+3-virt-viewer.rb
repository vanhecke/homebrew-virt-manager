class Gtkx3VirtViewer < Formula
  desc "GTK+3 patched for virt-viewer's SPICE clipboard (private, keg-only)"
  homepage "https://gtk.org/"
  url "https://download.gnome.org/sources/gtk/3.24/gtk-3.24.52.tar.xz"
  sha256 "80931fa472a77b9a164f6740e3c0b444fac6770054632d35a7ff9d679e5e7b9f"
  license "LGPL-2.0-or-later"
  compatibility_version 1

  livecheck do
    url :stable
    regex(/gtk\+?[._-](3\.([0-8]\d*?)?[02468](?:\.\d+)*?)\.t/i)
  end

  # Deliberately keg-only. These patches change GTK behaviour process-wide --
  # gtk3-0002 makes every GtkClipboard emit ::owner-change on app activation --
  # and there is no reason to impose that on every GTK app on the machine. Only
  # virt-viewer's own wrapper puts this copy on DYLD_LIBRARY_PATH.
  keg_only "it is a patched GTK for virt-viewer only and must not shadow the stock gtk+3"

  depends_on "docbook" => :build
  depends_on "docbook-xsl" => :build
  depends_on "gettext" => :build
  depends_on "gobject-introspection" => :build
  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkgconf" => [:build, :test]

  depends_on "at-spi2-core"
  depends_on "cairo"
  depends_on "fribidi"
  depends_on "gdk-pixbuf"
  depends_on "glib"
  depends_on "gsettings-desktop-schemas"
  # The stock gtk+3 of the same version supplies the compiled GSettings schemas
  # and icon cache in the shared prefix, which this copy reads at runtime.
  depends_on "gtk+3"
  depends_on "harfbuzz"
  depends_on "hicolor-icon-theme"
  depends_on "libepoxy"
  depends_on "pango"

  uses_from_macos "libxslt" => :build # for xsltproc

  on_macos do
    depends_on "gettext"
  end

  on_linux do
    depends_on "cmake" => :build

    depends_on "fontconfig"
    depends_on "iso-codes"
    depends_on "libx11"
    depends_on "libxdamage"
    depends_on "libxext"
    depends_on "libxfixes"
    depends_on "libxi"
    depends_on "libxinerama"
    depends_on "libxkbcommon"
    depends_on "libxrandr"
    depends_on "wayland"
    depends_on "wayland-protocols"
    depends_on "xorgproto"
  end

  # See patches/ and README.md.
  patch :DATA

  def install
    # spice-gtk and gtk-vnc are core bottles built against core's gtk+3, but
    # virt-viewer's wrapper redirects them to this copy at runtime. Building a
    # version that differs from core's is how you get a remote-viewer that dyld
    # refuses to launch, so refuse here instead, where the message is useful.
    stock = Formula["gtk+3"]
    if stock.version.to_s != version.to_s
      odie <<~EOS
        This tap is out of date: gtk+3-virt-viewer is #{version} but Homebrew's
        gtk+3 is now #{stock.version}.

        spice-gtk and gtk-vnc are built against gtk+3 #{stock.version} and would be
        redirected to this #{version} copy at runtime, which can fail to load, so
        installing this combination is refused rather than shipping something
        broken.

        Please report it at
          https://github.com/vanhecke/homebrew-virt-manager/issues

        Maintainers: ./tools/sync-gtk-version.sh --bump
      EOS
    end

    args = %w[
      -Dgtk_doc=false
      -Dman=true
      -Dintrospection=true
    ]

    if OS.mac?
      args << "-Dquartz_backend=true"
      args << "-Dx11_backend=false"
    end

    # tests/gtkgears.c calls sincos(), which meson detects as present but which
    # is not declared in any macOS header, so clang 21 and later reject the
    # call outright. Homebrew's bottles predate that and were built with tests
    # on; building from source here needs them off. Nothing under tests/ is
    # installed, so the resulting keg is unchanged.
    args << "-Dtests=false"

    # ensure that we don't run the meson post install script
    ENV["DESTDIR"] = "/"

    # Find our docbook catalog
    ENV["XML_CATALOG_FILES"] = "#{etc}/xml/catalog"

    system "meson", "setup", "build", *args, *std_meson_args
    system "meson", "compile", "-C", "build", "--verbose"
    system "meson", "install", "-C", "build"

    bin.install_symlink bin/"gtk-update-icon-cache" => "gtk3-update-icon-cache"
    man1.install_symlink man1/"gtk-update-icon-cache.1" => "gtk3-update-icon-cache.1"
  end

  # No post_install: the stock gtk+3 owns the shared schemas, icon cache and
  # immodules.cache. Writing them from here would leak this build's effects out
  # to every other GTK application, which is exactly what being keg-only avoids.

  test do
    (testpath/"test.c").write <<~C
      #include <gtk/gtk.h>

      int main(int argc, char *argv[]) {
        gtk_disable_setlocale();
        return 0;
      }
    C

    ENV.prepend_path "PKG_CONFIG_PATH", lib/"pkgconfig"
    flags = shell_output("pkgconf --cflags --libs gtk+-3.0").chomp.split
    system ENV.cc, "test.c", "-o", "test", *flags
    system "./test"
    assert_match version.to_s, shell_output("cat #{lib}/pkgconfig/gtk+-3.0.pc").strip

    # The whole point of this formula: the patches must actually be in the build.
    assert_match "GtkClipboardPasteboardWatcher",
                 shell_output("strings -a #{lib}/libgtk-3.0.dylib")
  end
end

__END__
--- a/gdk/quartz/gdkeventloop-quartz.c
+++ b/gdk/quartz/gdkeventloop-quartz.c
@@ -577,6 +577,31 @@
 
   if (select_thread_state == WAITING) /* The poll completed */
     {
+      /* The select thread's poll state is global, but poll_func() is
+       * re-entrant: a nested main loop (spice-gtk runs one from its
+       * clipboard "get" callback, gtk_dialog_run() from a dialog) or the
+       * CFRunLoop observer path in run_loop_before_waiting() can hand the
+       * select thread a different set of descriptors while our asynchronous
+       * poll is still outstanding. The last_ufds check in poll_func() does
+       * not catch that: it compares pointers, and GLib hands back the same
+       * cached poll array with a changed set of file descriptors in it.
+       *
+       * When that has happened the poll that completed is not ours and there
+       * is nothing here to collect. Report no ready descriptors rather than
+       * aborting; poll_func() opens every call with a synchronous poll, so
+       * the activity is picked up on the very next main loop iteration.
+       *
+       * https://gitlab.gnome.org/GNOME/gtk/-/issues/2961
+       */
+      if (current_pollfds == NULL || current_n_pollfds == 0 ||
+	  !pollfds_equal (ufds, nfds, current_pollfds, current_n_pollfds - 1))
+	{
+	  GDK_NOTE (EVENTLOOP, g_message ("EventLoop: Poll result is for a different "
+					  "set of file descriptors, discarding"));
+	  SELECT_THREAD_UNLOCK ();
+	  return 0;
+	}
+
       for (i = 0; i < nfds; i++)
 	{
 	  if (ufds[i].fd == -1)
--- a/gtk/gtkclipboard-quartz.c
+++ b/gtk/gtkclipboard-quartz.c
@@ -46,6 +46,20 @@
 
 @end
 
+/* Cocoa has no equivalent of the X11 owner-change event, and
+ * pasteboardChangedOwner: is documented as unreliable, so a change made to the
+ * system pasteboard by another application is never reported to us. Watching
+ * the pasteboard's changeCount is the supported way to notice; this observer
+ * arranges for that check to happen whenever the application is activated.
+ *
+ * https://gitlab.gnome.org/GNOME/gtk/-/issues/1757
+ */
+@interface GtkClipboardPasteboardWatcher : NSObject {
+  GtkClipboard *clipboard;
+}
+
+@end
+
 typedef struct _GtkClipboardClass GtkClipboardClass;
 
 struct _GtkClipboard
@@ -54,6 +68,7 @@
 
   NSPasteboard *pasteboard;
   GtkClipboardOwner *owner;
+  GtkClipboardPasteboardWatcher *watcher;
   NSInteger change_count;
 
   GdkAtom selection;
@@ -95,6 +110,7 @@
 static GtkClipboard *clipboard_peek       (GdkDisplay       *display,
 					   GdkAtom           selection,
 					   gboolean          only_if_exists);
+static void          clipboard_check_pasteboard_change (GtkClipboard *clipboard);
 
 @implementation GtkClipboardOwner
 -(void)pasteboard:(NSPasteboard *)sender provideDataForType:(NSString *)type
@@ -153,7 +169,26 @@
 
 @end
 
+@implementation GtkClipboardPasteboardWatcher
 
+- (id)initWithClipboard:(GtkClipboard *)aClipboard
+{
+  self = [super init];
+
+  if (self)
+    clipboard = aClipboard;
+
+  return self;
+}
+
+- (void)pasteboardMayHaveChanged:(NSNotification *)notification
+{
+  clipboard_check_pasteboard_change (clipboard);
+}
+
+@end
+
+
 static const gchar clipboards_owned_key[] = "gtk-clipboards-owned";
 static GQuark clipboards_owned_key_id = 0;
 
@@ -225,6 +260,13 @@
   clipboards = g_object_get_data (G_OBJECT (clipboard->display), "gtk-clipboard-list");
   if (g_slist_index (clipboards, clipboard) >= 0)
     g_warning ("GtkClipboard prematurely finalized");
+
+  if (clipboard->watcher)
+    {
+      [[NSNotificationCenter defaultCenter] removeObserver:clipboard->watcher];
+      [clipboard->watcher release];
+      clipboard->watcher = NULL;
+    }
 
   clipboard_unset (clipboard);
 
@@ -568,6 +610,42 @@
   if (old_have_owner &&
       old_n_storable_targets != -1)
     g_object_unref (old_data);
+}
+
+/* If the pasteboard has moved on since we last looked at it, someone else owns
+ * it now. Drop our side of it and emit ::owner-change, which is the signal
+ * applications watch to learn that the clipboard changed underneath them.
+ *
+ * Note that this reports the change when the application is activated rather
+ * than at the instant of the copy, which is the same behaviour GTK has on
+ * Wayland.
+ */
+static void
+clipboard_check_pasteboard_change (GtkClipboard *clipboard)
+{
+  GdkEventOwnerChange *event;
+
+  if (clipboard->change_count >= [clipboard->pasteboard changeCount])
+    return;
+
+  /* Unset first, so that gtk_clipboard_get_owner () already reports NULL by
+   * the time a handler runs.
+   */
+  clipboard_unset (clipboard);
+  clipboard->change_count = [clipboard->pasteboard changeCount];
+
+  event = (GdkEventOwnerChange *) gdk_event_new (GDK_OWNER_CHANGE);
+  event->window = NULL;
+  event->send_event = TRUE;
+  event->owner = NULL;
+  event->reason = GDK_OWNER_CHANGE_NEW_OWNER;
+  event->selection = clipboard->selection;
+  event->time = GDK_CURRENT_TIME;
+  event->selection_time = GDK_CURRENT_TIME;
+
+  g_signal_emit (clipboard, clipboard_signals[OWNER_CHANGE], 0, event);
+
+  gdk_event_free ((GdkEvent *) event);
 }
 
 void
@@ -576,7 +654,7 @@
   clipboard_unset (clipboard);
 #if MAC_OS_X_VERSION_MAX_ALLOWED >= 1060
   if (gdk_quartz_osx_version() >= GDK_OSX_SNOW_LEOPARD)
-    [clipboard->pasteboard clearContents];
+    clipboard->change_count = [clipboard->pasteboard clearContents];
 #if MAC_OS_X_VERSION_MIN_REQUIRED < 1060
   else
 #endif
@@ -1143,6 +1221,24 @@
 
       clipboard->pasteboard = [NSPasteboard pasteboardWithName:pasteboard_name];
 
+      clipboard->watcher =
+	[[GtkClipboardPasteboardWatcher alloc] initWithClipboard:clipboard];
+
+      /* Application activation covers switching back from another app; window
+       * key changes cover regaining focus without the app itself deactivating.
+       * The check is idempotent, so being called from both is harmless.
+       */
+      [[NSNotificationCenter defaultCenter]
+	addObserver:clipboard->watcher
+	   selector:@selector (pasteboardMayHaveChanged:)
+	       name:NSApplicationDidBecomeActiveNotification
+	     object:nil];
+      [[NSNotificationCenter defaultCenter]
+	addObserver:clipboard->watcher
+	   selector:@selector (pasteboardMayHaveChanged:)
+	       name:NSWindowDidBecomeKeyNotification
+	     object:nil];
+
       [pool release];
 
       clipboard->selection = selection;
--- a/gdk/quartz/gdkwindow-quartz.c
+++ b/gdk/quartz/gdkwindow-quartz.c
@@ -32,6 +32,7 @@
 #include "gdkquartzscreen.h"
 #include "gdkquartzcursor.h"
 #include "gdkquartz-cocoa-access.h"
+#include "gdkquartz-gtk-only.h"
 #include "gdkinternal-quartz.h"
 
 #include <Carbon/Carbon.h>
@@ -2496,7 +2497,51 @@
 gdk_quartz_window_set_icon_list (GdkWindow *window,
                                  GList     *pixbufs)
 {
-  /* FIXME: Implement */
+  GdkPixbuf *best = NULL;
+  gint best_area = 0;
+  GList *l;
+  NSImage *image;
+
+  if (GDK_WINDOW_DESTROYED (window) ||
+      !WINDOW_IS_TOPLEVEL (window))
+    return;
+
+  /* macOS has no per-window icon, but what a GTK application sets here is
+   * exactly what the user expects to see in the Dock and the app switcher, so
+   * map it onto the application icon rather than dropping it. Without this a
+   * GTK application started from a terminal keeps the generic executable icon
+   * no matter what gtk_window_set_default_icon_name() says. Cocoa derives
+   * every size it needs from one image, so hand it the largest pixbuf.
+   */
+  for (l = pixbufs; l != NULL; l = l->next)
+    {
+      GdkPixbuf *pixbuf = l->data;
+      gint area;
+
+      if (!GDK_IS_PIXBUF (pixbuf))
+        continue;
+
+      area = gdk_pixbuf_get_width (pixbuf) * gdk_pixbuf_get_height (pixbuf);
+      if (area > best_area)
+        {
+          best = pixbuf;
+          best_area = area;
+        }
+    }
+
+  if (best == NULL)
+    return;
+
+  GDK_QUARTZ_ALLOC_POOL;
+
+  /* The helper returns an autoreleased image; setApplicationIconImage:
+   * retains it, so there is nothing to release here.
+   */
+  image = gdk_quartz_pixbuf_to_ns_image_libgtk_only (best);
+  if (image != NULL)
+    [NSApp setApplicationIconImage:image];
+
+  GDK_QUARTZ_RELEASE_POOL;
 }
 
 static void
--- a/gdk/quartz/gdkevents-quartz.c
+++ b/gdk/quartz/gdkevents-quartz.c
@@ -1914,9 +1914,31 @@
       GDK_QUARTZ_ALLOC_POOL;
 
       g_value_set_boolean (value, TRUE);
+
+      GDK_QUARTZ_RELEASE_POOL;
+
+      return TRUE;
+    }
+  else if (strcmp (name, "gtk-application-prefer-dark-theme") == 0)
+    {
+      NSString *style;
+      gboolean dark;
+
+      GDK_QUARTZ_ALLOC_POOL;
+
+      /* macOS publishes the system appearance in this user default: it is
+       * absent for light and "Dark" for dark. NSAppearance would be more
+       * direct, but it is a per-window property whereas this is the
+       * screen-wide setting GtkSettings is asking about.
+       */
+      style = [[NSUserDefaults standardUserDefaults]
+                stringForKey:@"AppleInterfaceStyle"];
+      dark = (style != nil && [style isEqualToString:@"Dark"]);
 
       GDK_QUARTZ_RELEASE_POOL;
 
+      g_value_set_boolean (value, dark);
+
       return TRUE;
     }
   
