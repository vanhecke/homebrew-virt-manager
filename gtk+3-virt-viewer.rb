class Gtkx3VirtViewer < Formula
  desc "GTK+3 patched for virt-viewer's SPICE clipboard (private, keg-only)"
  homepage "https://gtk.org/"
  url "https://download.gnome.org/sources/gtk/3.24/gtk-3.24.52.tar.xz"
  sha256 "80931fa472a77b9a164f6740e3c0b444fac6770054632d35a7ff9d679e5e7b9f"
  license "LGPL-2.0-or-later"
  compatibility_version 1

  # Deliberately keg-only. These patches change GTK behaviour process-wide --
  # gtk3-0002 makes every GtkClipboard emit ::owner-change on app activation --
  # and there is no reason to impose that on every GTK app on the machine. Only
  # virt-viewer's own wrapper puts this copy on DYLD_LIBRARY_PATH.
  keg_only "it is a patched GTK for virt-viewer only and must not shadow the stock gtk+3"

  # The stock gtk+3 of the same version supplies the compiled GSettings schemas
  # and icon cache in the shared prefix, which this copy reads at runtime.
  depends_on "gtk+3"

  livecheck do
    url :stable
    regex(/gtk\+?[._-](3\.([0-8]\d*?)?[02468](?:\.\d+)*?)\.t/i)
  end

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
  end
end

