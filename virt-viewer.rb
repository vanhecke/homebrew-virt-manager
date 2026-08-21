class VirtViewer < Formula
  desc "App for virtualized guest interaction"
  homepage "https://virt-manager.org/"
  # Not releases.pagure.org: that directory stopped serving a file listing and every
  # tarball under it now 404s. Development moved to gitlab.com/virt-viewer/virt-viewer
  # and the release assets went with it, into GitLab's generic package registry. The
  # URL is ugly, but the project publishes no plainer alias for it.
  url "https://gitlab.com/api/v4/projects/virt-viewer%2Fvirt-viewer/packages/generic/release-assets/v11.0/virt-viewer-11.0.tar.xz"
  # Unchanged from the pagure tarball -- byte for byte the same 259772-byte file. That
  # identity is the evidence this is the same artifact rather than a repackage, so do
  # not "correct" it against a freshly downloaded checksum.
  sha256 "a43fa2325c4c1c77a5c8c98065ac30ef0511a21ac98e590f22340869bad9abd0"
  # COPYING is the GPLv2 text and every source header reads "either version 2 of
  # the License, or (at your option) any later version". Upstream's meson.build
  # claims 'GPLv3+', which is simply wrong -- do not "correct" this to match it.
  license "GPL-2.0-or-later"

  livecheck do
    # The pagure listing this would naturally point at is gone, GitLab's own releases
    # page is rendered client-side and carries no version strings, and unauthenticated
    # `git ls-remote` against gitlab.com answers 403 -- so neither PageMatch nor :git
    # can work here. The releases API is what is left, and it is what the url above
    # is served from anyway.
    url "https://gitlab.com/api/v4/projects/virt-viewer%2Fvirt-viewer/releases"
    strategy :json do |json|
      json.map { |release| release["tag_name"]&.delete_prefix("v") }
    end
  end

  depends_on "gettext" => :build
  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkgconf" => :build

  # Every themed icon the UI asks for (view-fullscreen-symbolic, open-menu-symbolic,
  # computer-symbolic, ...) lives in Adwaita, which is the default icon theme but is
  # not a dependency of gtk+3. Without it hicolor is all that is installed, it holds
  # nothing but virt-viewer's own app icon, and the toolbar renders blank.
  depends_on "adwaita-icon-theme"
  depends_on "desktop-file-utils"
  depends_on "glib"
  depends_on "gtk+3"
  depends_on "gtk-vnc"
  # meson.build asks for both libvirt and libvirt-glib; the built virt-viewer binary
  # links libvirt.0.dylib directly, so declare it rather than relying on the
  # transitive dependency.
  depends_on "libvirt"
  depends_on "libvirt-glib"
  depends_on "shared-mime-info"
  depends_on "spice-gtk"
  depends_on "vanhecke/virt-manager/gtk+3-virt-viewer"

  patch :DATA

  def install
    # spice, vnc, libvirt, ovirt and vte are all `type: 'feature', value: 'auto'`:
    # left alone, a missing or renamed .pc drops the feature and the build still
    # succeeds. For a tap that exists to fix SPICE that is the worst failure mode,
    # so make the three we depend on hard requirements. ovirt and vte are pinned
    # off so a later `brew install vte3` cannot quietly change what we build.
    system "meson", "setup", "builddir", *std_meson_args,
           "-Dspice=enabled",
           "-Dvnc=enabled",
           "-Dlibvirt=enabled",
           "-Dovirt=disabled",
           "-Dvte=disabled"
    system "ninja", "-C", "builddir", "install", "-v"

    # Run against the patched GTK without inflicting it on the rest of the
    # machine. DYLD_LIBRARY_PATH overrides by leaf name for every dependent in
    # the process, so spice-gtk and gtk-vnc -- which link libgtk-3 themselves
    # and would otherwise pull in the stock copy -- resolve to the patched one
    # too. That matters: two libgtk-3 in one process means duplicate GTypes and
    # duplicate static state, which breaks far worse than the bug being fixed.
    gtkvv = Formula["vanhecke/virt-manager/gtk+3-virt-viewer"]
    (libexec/"bin").install Dir[bin/"*"]
    Dir[libexec/"bin/*"].each do |real|
      wrapper = bin/File.basename(real)
      # Wrapper, not a symlink: it points this process (and only this process)
      # at the patched GTK. A command prefix assignment on exec is used rather
      # than /usr/bin/env because macOS strips every DYLD_* variable when
      # exec'ing a SIP-protected binary, and env is one -- an env based wrapper
      # would silently do nothing. Keep this wrapper free of diagnostics: it is
      # on the path of every launch, and keeping the tap in step with core's
      # gtk+3 is the maintainer's job, not the user's. See
      # .github/workflows/gtk-version-drift.yml.
      wrapper.write <<~SH
        #!/bin/bash
        DYLD_LIBRARY_PATH="#{gtkvv.opt_lib}" exec "#{real}" "$@"
      SH
      wrapper.chmod 0555
    end
  end

  def post_install
    system formula_opt_bin("shared-mime-info")/"update-mime-database", HOMEBREW_PREFIX/"share/mime"
    system formula_opt_bin("gtk+3")/"gtk3-update-icon-cache", HOMEBREW_PREFIX/"share/icons/hicolor"
    system formula_opt_bin("desktop-file-utils")/"update-desktop-database", HOMEBREW_PREFIX/"share/applications"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/virt-viewer --version")
    assert_match version.to_s, shell_output("#{bin}/remote-viewer --version")

    # The wrapper is the whole tap. If it ever stops pointing at the private GTK,
    # virt-viewer silently loads the stock copy instead, everything still starts,
    # and the clipboard crash comes back months later with nothing to connect it
    # to. Assert on the wrapper rather than on behaviour because the failure is
    # invisible until a guest is actually connected.
    gtkvv = Formula["vanhecke/virt-manager/gtk+3-virt-viewer"]
    assert_match gtkvv.opt_lib.to_s, (bin/"virt-viewer").read
  end
end
__END__
diff --git a/meson.build b/meson.build
index e5ed47b..26f386f 100644
--- a/meson.build
+++ b/meson.build
@@ -539,30 +539,6 @@ i18n = import('i18n')
 i18n_itsdir = join_paths(meson.source_root(), 'data', 'gettext')
 top_include_dir = [include_directories('.')]

-update_mime_database = find_program('update-mime-database', required: false)
-update_icon_cache = find_program('gtk-update-icon-cache', required: false)
-update_desktop_database = find_program('update-desktop-database', required: false)
-
-update_mime_database_path = ''
-if update_mime_database.found()
-  update_mime_database_path = update_mime_database.path()
-endif
-
-update_icon_cache_path = ''
-if update_icon_cache.found()
-  update_icon_cache_path = update_icon_cache.path()
-endif
-
-update_desktop_database_path = ''
-if update_desktop_database.found()
-  update_desktop_database_path = update_desktop_database.path()
-endif
-
-meson.add_install_script('build-aux/post_install.py',
-                         update_mime_database_path,
-                         update_icon_cache_path,
-                         update_desktop_database_path)
-
 subdir('icons')
 subdir('src')
 subdir('po')
diff --git a/data/meson.build b/data/meson.build
index d718491..4325108 100644
--- a/data/meson.build
+++ b/data/meson.build
@@ -2,7 +2,6 @@ if host_machine.system() != 'windows'
   desktop = 'remote-viewer.desktop'

   i18n.merge_file (
-    desktop,
     type: 'desktop',
     input: desktop + '.in',
     output: desktop,
@@ -14,7 +13,6 @@ if host_machine.system() != 'windows'
   mimetypes = 'virt-viewer-mime.xml'

   i18n.merge_file (
-    mimetypes,
     type: 'xml',
     input: mimetypes + '.in',
     output: mimetypes,
@@ -27,7 +25,6 @@ if host_machine.system() != 'windows'
   metainfo = 'remote-viewer.appdata.xml'

   i18n.merge_file (
-    metainfo,
     type: 'xml',
     input: metainfo + '.in',
     output: metainfo,
--- a/src/virt-viewer-window.c
+++ b/src/virt-viewer-window.c
@@ -825,12 +825,18 @@
         {GDK_SHIFT_MASK, GDK_KEY_Shift_L},
         {GDK_CONTROL_MASK, GDK_KEY_Control_L},
         {GDK_MOD1_MASK, GDK_KEY_Alt_L},
+        /* The GDK quartz backend reports the Command key as MOD2 and sets META
+         * alongside it, and it is what <Primary> resolves to on macOS. Both
+         * bits describe the one key, so keep them in a single entry to avoid
+         * sending Meta_L twice. */
+        {GDK_MOD2_MASK | GDK_META_MASK, GDK_KEY_Meta_L},
     };
 
     g_warn_if_fail((accel_mods &
-                    ~(GDK_SHIFT_MASK | GDK_CONTROL_MASK | GDK_MOD1_MASK)) == 0);
+                    ~(GDK_SHIFT_MASK | GDK_CONTROL_MASK | GDK_MOD1_MASK |
+                      GDK_MOD2_MASK | GDK_META_MASK)) == 0);
 
-    keys = val = g_new(guint, G_N_ELEMENTS(modifiers) + 2); /* up to 3 modifiers, key and the stop symbol */
+    keys = val = g_new(guint, G_N_ELEMENTS(modifiers) + 2); /* one key per modifier, the key and the stop symbol */
     /* first, send the modifiers */
     for (i = 0; i < G_N_ELEMENTS(modifiers); i++) {
         if (accel_mods & modifiers[i].mask)
--- a/src/virt-viewer-app.c
+++ b/src/virt-viewer-app.c
@@ -2468,13 +2468,19 @@
     VirtViewerAppPrivate *priv = virt_viewer_app_get_instance_private(self);
     GError *error = NULL;
     gint i;
-#ifndef G_OS_WIN32
+#if !defined(G_OS_WIN32) && !defined(GDK_WINDOWING_QUARTZ)
     GtkSettings *gtk_settings;
 #endif
 
     G_APPLICATION_CLASS(virt_viewer_app_parent_class)->startup(app);
 
-#ifndef G_OS_WIN32
+/* Forcing dark here would pin gtk-application-prefer-dark-theme at
+ * GTK_SETTINGS_SOURCE_APPLICATION, which outranks both settings.ini and the
+ * windowing backend, so nothing could ever override it. On macOS the backend
+ * reports the system appearance (see the gtk3 quartz system-appearance patch),
+ * and we want to follow it rather than override it.
+ */
+#if !defined(G_OS_WIN32) && !defined(GDK_WINDOWING_QUARTZ)
     gtk_settings = gtk_settings_get_default();
     g_object_set(G_OBJECT(gtk_settings),
                  "gtk-application-prefer-dark-theme",
--- a/src/resources/ui/virt-viewer.ui
+++ b/src/resources/ui/virt-viewer.ui
@@ -135,118 +135,5 @@
         </child>
       </object>
     </child>
-    <child type="titlebar">
-      <object class="GtkHeaderBar" id="header">
-        <property name="visible">True</property>
-        <property name="can-focus">False</property>
-        <property name="show-close-button">True</property>
-        <child>
-          <object class="GtkMenuButton" id="header-action">
-            <property name="visible">True</property>
-            <property name="can-focus">True</property>
-            <property name="receives-default">True</property>
-            <child>
-              <object class="GtkImage">
-                <property name="visible">True</property>
-                <property name="can-focus">False</property>
-                <property name="icon-name">open-menu-symbolic</property>
-              </object>
-            </child>
-          </object>
-          <packing>
-            <property name="pack-type">end</property>
-          </packing>
-        </child>
-        <child>
-          <object class="GtkMenuButton" id="header-send-key">
-            <property name="visible">True</property>
-            <property name="can-focus">True</property>
-            <property name="receives-default">True</property>
-            <child>
-              <object class="GtkImage">
-                <property name="visible">True</property>
-                <property name="can-focus">False</property>
-                <property name="icon-name">preferences-desktop-keyboard-shortcuts-symbolic</property>
-              </object>
-            </child>
-          </object>
-          <packing>
-            <property name="position">1</property>
-          </packing>
-        </child>
-        <child>
-          <object class="GtkButton" id="header-usb">
-            <property name="visible">True</property>
-            <property name="can-focus">True</property>
-            <property name="receives-default">True</property>
-            <property name="action-name">win.usb-device-select</property>
-            <child>
-              <object class="GtkImage">
-                <property name="visible">True</property>
-                <property name="can-focus">False</property>
-                <property name="icon-name">audio-card-symbolic</property>
-              </object>
-            </child>
-          </object>
-          <packing>
-            <property name="position">2</property>
-          </packing>
-        </child>
-        <child>
-          <object class="GtkButton" id="header-cd">
-            <property name="can-focus">True</property>
-            <property name="receives-default">True</property>
-            <property name="tooltip-text" translatable="yes">Change CD</property>
-            <property name="action-name">win.change-cd</property>
-            <child>
-              <object class="GtkImage">
-                <property name="visible">True</property>
-                <property name="can-focus">False</property>
-                <property name="icon-name">drive-optical-symbolic</property>
-              </object>
-            </child>
-          </object>
-          <packing>
-            <property name="position">3</property>
-          </packing>
-        </child>
-        <child>
-          <object class="GtkMenuButton" id="header-machine">
-            <property name="visible">True</property>
-            <property name="can-focus">True</property>
-            <property name="receives-default">True</property>
-            <child>
-              <object class="GtkImage">
-                <property name="visible">True</property>
-                <property name="can-focus">False</property>
-                <property name="icon-name">computer-symbolic</property>
-              </object>
-            </child>
-          </object>
-          <packing>
-            <property name="position">4</property>
-          </packing>
-        </child>
-        <child>
-          <object class="GtkButton" id="header-fullscreen">
-            <property name="visible">True</property>
-            <property name="can-focus">True</property>
-            <property name="receives-default">True</property>
-            <property name="action-name">win.fullscreen</property>
-            <child>
-              <object class="GtkImage">
-                <property name="visible">True</property>
-                <property name="can-focus">False</property>
-                <property name="icon-name">view-fullscreen-symbolic</property>
-              </object>
-            </child>
-          </object>
-          <packing>
-            <property name="pack-type">end</property>
-            <property name="position">5</property>
-          </packing>
-        </child>
-      </object>
-    </child>
   </object>
 </interface>
--- a/src/virt-viewer-window.c
+++ b/src/virt-viewer-window.c
@@ -71,6 +71,9 @@
     PROP_KEYMAP,
 };
 
+/* Machine, View, Send key -- rebuild_combo_menu() replaces the third. */
+#define MENUBAR_SEND_KEY_INDEX 2
+
 struct _VirtViewerWindow {
     GObject parent;
     VirtViewerApp *app;
@@ -81,6 +84,7 @@
     VirtViewerNotebook *notebook;
     VirtViewerDisplay *display;
     VirtViewerTimedRevealer *revealer;
+    GMenu *menubar;
 
     gboolean accel_enabled;
     GValue accel_setting;
@@ -191,6 +195,8 @@
 
     g_value_unset(&self->accel_setting);
 
+    g_clear_object(&self->menubar);
+
     G_OBJECT_CLASS (virt_viewer_window_parent_class)->dispose (object);
 }
 
@@ -205,15 +211,19 @@
 
     menu = virt_viewer_window_get_keycombo_menu(self);
 
-    button = gtk_builder_get_object(self->builder, "header-send-key");
-    gtk_menu_button_set_menu_model(
-        GTK_MENU_BUTTON(button),
-        G_MENU_MODEL(menu));
-
     button = gtk_builder_get_object(self->builder, "toolbar-send-key");
     gtk_menu_button_set_menu_model(
         GTK_MENU_BUTTON(button),
         G_MENU_MODEL(menu));
+
+    /* The menu bar carries the same combos, and only the window that owns the
+     * menu bar has one at all.
+     */
+    if (self->menubar != NULL) {
+        g_menu_remove(self->menubar, MENUBAR_SEND_KEY_INDEX);
+        g_menu_insert_submenu(self->menubar, MENUBAR_SEND_KEY_INDEX,
+                              _("Send _key"), G_MENU_MODEL(menu));
+    }
 }
 
 static void
@@ -224,6 +234,56 @@
     if (G_OBJECT_CLASS(virt_viewer_window_parent_class)->constructed)
         G_OBJECT_CLASS(virt_viewer_window_parent_class)->constructed(object);
 
+    /* macOS draws the titlebar itself, so there is no header bar to hang these
+     * controls off and they live in the system menu bar instead. The models
+     * already built for the fullscreen overlay toolbar are reused rather than
+     * duplicated, so sections filled in at runtime -- the display list injected
+     * into machine-menu's first section, the key combos -- keep working here.
+     *
+     * This has to happen in constructed() rather than init(): self->app is a
+     * construct property, so during instance init it is still NULL.
+     *
+     * Only the first window installs a menu bar. On macOS it belongs to the
+     * application rather than the window, and win.* actions in it resolve
+     * against whichever window is active, because the Quartz backend swaps the
+     * active window's action group into the menu muxer under "win".
+     */
+    if (gtk_application_get_menubar(GTK_APPLICATION(self->app)) == NULL) {
+        GMenu *machine = g_menu_new();
+        GMenu *devices = g_menu_new();
+        GMenu *view = g_menu_new();
+        GMenu *screen = g_menu_new();
+
+        g_menu_append_section(machine, NULL,
+            gtk_menu_button_get_menu_model(
+                GTK_MENU_BUTTON(gtk_builder_get_object(self->builder, "toolbar-machine"))));
+        g_menu_append(devices, _("_USB device selection"), "win.usb-device-select");
+        g_menu_append(devices, _("Change _CD"), "win.change-cd");
+        g_menu_append_section(machine, NULL, G_MENU_MODEL(devices));
+
+        g_menu_append_section(view, NULL,
+            gtk_menu_button_get_menu_model(
+                GTK_MENU_BUTTON(gtk_builder_get_object(self->builder, "toolbar-action"))));
+        g_menu_append(screen, _("_Full screen"), "win.fullscreen");
+        g_menu_append_section(view, NULL, G_MENU_MODEL(screen));
+
+        self->menubar = g_menu_new();
+        g_menu_append_submenu(self->menubar, _("_Machine"), G_MENU_MODEL(machine));
+        g_menu_append_submenu(self->menubar, _("_View"), G_MENU_MODEL(view));
+        /* Placeholder at MENUBAR_SEND_KEY_INDEX; rebuild_combo_menu() fills it
+         * in below and again whenever the hotkey configuration changes.
+         */
+        g_menu_append_submenu(self->menubar, _("Send _key"), G_MENU_MODEL(g_menu_new()));
+
+        g_object_unref(machine);
+        g_object_unref(devices);
+        g_object_unref(view);
+        g_object_unref(screen);
+
+        gtk_application_set_menubar(GTK_APPLICATION(self->app),
+                                    G_MENU_MODEL(self->menubar));
+    }
+
     g_signal_connect(self->app, "notify::release-cursor-display-hotkey",
                      G_CALLBACK(rebuild_combo_menu), object);
     rebuild_combo_menu(NULL, NULL, object);
@@ -556,16 +616,6 @@
 
     menuBuilder =
         gtk_builder_new_from_resource(VIRT_VIEWER_RESOURCE_PREFIX "/ui/virt-viewer-menus.ui");
-
-    menu = gtk_builder_get_object(self->builder, "header-action");
-    gtk_menu_button_set_menu_model(
-        GTK_MENU_BUTTON(menu),
-        G_MENU_MODEL(gtk_builder_get_object(menuBuilder, "action-menu")));
-
-    menu = gtk_builder_get_object(self->builder, "header-machine");
-    gtk_menu_button_set_menu_model(
-        GTK_MENU_BUTTON(menu),
-        G_MENU_MODEL(gtk_builder_get_object(menuBuilder, "machine-menu")));
 
     menu = gtk_builder_get_object(self->builder, "toolbar-action");
     gtk_menu_button_set_menu_model(
@@ -1302,10 +1352,8 @@
 {
     char *title;
     char *grabhint = NULL;
-    GtkWidget *header;
     GtkWidget *toolbar;
 
-    header = GTK_WIDGET(gtk_builder_get_object(self->builder, "header"));
     toolbar = GTK_WIDGET(gtk_builder_get_object(self->builder, "toolbar"));
 
     if (self->grabbed) {
@@ -1361,18 +1409,17 @@
     }
 
     gtk_window_set_title(GTK_WINDOW(self->window), title);
+    /* The grab hint is already part of the window title built above, so the
+     * native titlebar still shows it; these only feed the fullscreen overlay.
+     */
     if (self->subtitle) {
-        gtk_header_bar_set_title(GTK_HEADER_BAR(header), self->subtitle);
         gtk_header_bar_set_title(GTK_HEADER_BAR(toolbar), self->subtitle);
     } else {
-        gtk_header_bar_set_title(GTK_HEADER_BAR(header), g_get_application_name());
         gtk_header_bar_set_title(GTK_HEADER_BAR(toolbar), g_get_application_name());
     }
     if (grabhint) {
-        gtk_header_bar_set_subtitle(GTK_HEADER_BAR(header), grabhint);
         gtk_header_bar_set_subtitle(GTK_HEADER_BAR(toolbar), grabhint);
     } else {
-        gtk_header_bar_set_subtitle(GTK_HEADER_BAR(header), "");
         gtk_header_bar_set_subtitle(GTK_HEADER_BAR(toolbar), "");
     }
 
@@ -1651,7 +1698,7 @@
     GMenuModel *model;
     g_return_val_if_fail(VIRT_VIEWER_IS_WINDOW(self), NULL);
 
-    menu = gtk_builder_get_object(self->builder, "header-machine");
+    menu = gtk_builder_get_object(self->builder, "toolbar-machine");
     model = gtk_menu_button_get_menu_model(GTK_MENU_BUTTON(menu));
 
     return g_menu_model_get_item_link(model, 0, G_MENU_LINK_SECTION);
--- a/src/virt-viewer-window.c
+++ b/src/virt-viewer-window.c
@@ -198,6 +198,36 @@
     g_clear_object(&self->menubar);
 
     G_OBJECT_CLASS (virt_viewer_window_parent_class)->dispose (object);
+}
+
+/* Fullscreen can be toggled without going through our own action: the green
+ * titlebar button and Window > Enter Full Screen drive the NSWindow directly.
+ * Left alone that desynchronises self->fullscreen and the View menu toggle, so
+ * the next explicit toggle does nothing. Re-entering GDK from here is harmless:
+ * gdk_quartz_window_fullscreen() and _unfullscreen() both no-op when the window
+ * is already in the requested state.
+ */
+static gboolean
+virt_viewer_window_window_state_event(GtkWidget *widget G_GNUC_UNUSED,
+                                      GdkEventWindowState *event,
+                                      gpointer user_data)
+{
+    VirtViewerWindow *self = user_data;
+    gboolean fullscreen;
+
+    if (!(event->changed_mask & GDK_WINDOW_STATE_FULLSCREEN))
+        return FALSE;
+
+    fullscreen = (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0;
+
+    /* We initiated it; enter/leave already set this before calling GDK. */
+    if (fullscreen == self->fullscreen)
+        return FALSE;
+
+    g_action_group_change_action_state(G_ACTION_GROUP(self->window), "fullscreen",
+                                       g_variant_new_boolean(fullscreen));
+
+    return FALSE;
 }
 
 static void
@@ -606,6 +636,16 @@
     gtk_container_add(GTK_CONTAINER(overlay), GTK_WIDGET(self->notebook));
     self->revealer = virt_viewer_timed_revealer_new(toolbar);
     gtk_overlay_add_overlay(GTK_OVERLAY(overlay), GTK_WIDGET(self->revealer));
+    /* The overlay toolbar exists to give a fullscreen window a way back out and
+     * somewhere to put the controls. macOS needs neither: the system menu bar
+     * stays reachable in fullscreen and carries the same actions. Keep the
+     * widget, because the menu bar reuses the menu models hung off its buttons,
+     * but never let it appear. It reveals itself on enter-notify, so hiding it
+     * is what actually suppresses it, and no_show_all stops the later
+     * gtk_widget_show_all() from undoing that.
+     */
+    gtk_widget_set_no_show_all(GTK_WIDGET(self->revealer), TRUE);
+    gtk_widget_hide(GTK_WIDGET(self->revealer));
 
     self->window = GTK_WIDGET(gtk_builder_get_object(self->builder, "viewer"));
 
@@ -614,6 +654,9 @@
 
     gtk_window_add_accel_group(GTK_WINDOW(self->window), self->accel_group);
 
+    g_signal_connect(self->window, "window-state-event",
+                     G_CALLBACK(virt_viewer_window_window_state_event), self);
+
     menuBuilder =
         gtk_builder_new_from_resource(VIRT_VIEWER_RESOURCE_PREFIX "/ui/virt-viewer-menus.ui");
 
@@ -757,11 +800,6 @@
 
     self->fullscreen = FALSE;
     self->fullscreen_monitor = -1;
-    if (self->display) {
-        virt_viewer_display_set_monitor(self->display, -1);
-        virt_viewer_display_set_fullscreen(self->display, FALSE);
-    }
-    virt_viewer_timed_revealer_force_reveal(self->revealer, FALSE);
     gtk_widget_set_size_request(self->window, -1, -1);
     gtk_window_unfullscreen(GTK_WINDOW(self->window));
 
@@ -790,16 +828,16 @@
         return;
     }
 
-    if (!self->kiosk) {
-        virt_viewer_timed_revealer_force_reveal(self->revealer, TRUE);
-    }
-
-    if (self->display) {
-        virt_viewer_display_set_monitor(self->display, monitor);
-        virt_viewer_display_set_fullscreen(self->display, TRUE);
-    }
-    virt_viewer_window_move_to_monitor(self);
-
+    /* Everything the X11 path does here is either unnecessary or actively
+     * harmful on macOS, where fullscreen is a window that fills the screen and
+     * nothing more: there is no overlay toolbar to reveal, no window to move or
+     * size by hand, and no reason to switch the display to monitor-derived
+     * geometry. Leaving the display in its normal mode means the guest is
+     * resized from the widget allocation instead -- the same path that runs
+     * when the window is resized by hand, which already works. Driving the
+     * monitor-geometry path here left the guest un-resized and the display
+     * frozen.
+     */
     if (monitor == -1) {
         // just go fullscreen on the current monitor
         gtk_window_fullscreen(GTK_WINDOW(self->window));
