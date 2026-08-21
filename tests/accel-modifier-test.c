#include <gtk/gtk.h>

static const char *accels[] = {
  "F11", "<Ctrl>plus", "<Ctrl>KP_Add", "<Ctrl>minus", "<Ctrl>KP_Subtract",
  "<Ctrl>0", "<Ctrl>KP_0", "<Shift>F12", "<Shift>F8", "<Shift>F9",
  "<Ctrl><Alt>End", "<Ctrl><Shift>r",
  "<Control><Alt>Delete", "<Control><Alt>F1", "Print",
  "<Primary>c", "<Primary><Shift>v", "<Meta>x", "<Super>x", "<Hyper>x",
};

#define OLD_MASK (GDK_SHIFT_MASK | GDK_CONTROL_MASK | GDK_MOD1_MASK)
#define NEW_MASK (OLD_MASK | GDK_MOD2_MASK | GDK_META_MASK)

int main(int argc, char **argv)
{
  gtk_init(&argc, &argv);
  g_print("%-22s %-10s %-8s %s\n", "accel", "mods", "old", "new");
  for (guint i = 0; i < G_N_ELEMENTS(accels); i++) {
    guint key; GdkModifierType mods;
    gtk_accelerator_parse(accels[i], &key, &mods);
    g_print("%-22s 0x%-8x %-8s %s\n", accels[i], mods,
            (mods & ~OLD_MASK) ? "WARN" : "ok",
            (mods & ~NEW_MASK) ? "WARN" : "ok");
  }
  GdkKeymap *km = gdk_keymap_get_for_display(gdk_display_get_default());
  g_print("\nPRIMARY_ACCELERATOR mask = 0x%x (MOD2=0x%x META=0x%x)\n",
          gdk_keymap_get_modifier_mask(km, GDK_MODIFIER_INTENT_PRIMARY_ACCELERATOR),
          GDK_MOD2_MASK, GDK_META_MASK);
  return 0;
}
