#import <Cocoa/Cocoa.h>
#include <gtk/gtk.h>

static int fires = 0;
static char *last_text = NULL;
static int last_reason = -1;

static void on_owner_change(GtkClipboard *cb, GdkEvent *ev, gpointer d)
{
  fires++;
  last_reason = ev->owner_change.reason;
  g_free(last_text);
  last_text = gtk_clipboard_wait_for_text(cb);
  g_print("  -> owner-change #%d reason=%d text=%s\n",
          fires, last_reason, last_text ? last_text : "(none)");
}

static void seed(const char *s)
{
  NSPasteboard *pb = [NSPasteboard generalPasteboard];
  [pb clearContents];
  [pb setString:[NSString stringWithUTF8String:s] forType:NSPasteboardTypeString];
}

static void post(NSString *name)
{
  [[NSNotificationCenter defaultCenter] postNotificationName:name object:NSApp];
}

int main(int argc, char **argv)
{
  int failures = 0;
  gtk_init(&argc, &argv);
  GtkClipboard *cb = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  g_signal_connect(cb, "owner-change", G_CALLBACK(on_owner_change), NULL);

  /* Case 1: another app put text on the pasteboard; app activation must
   * turn that into owner-change carrying the new text. */
  seed("hello-from-another-app");
  fires = 0;
  g_print("case 1: NSApplicationDidBecomeActive after a foreign copy\n");
  post(NSApplicationDidBecomeActiveNotification);
  if (fires != 1) { g_print("  FAIL expected 1 fire, got %d\n", fires); failures++; }
  else if (last_reason != GDK_OWNER_CHANGE_NEW_OWNER) { g_print("  FAIL reason\n"); failures++; }
  else if (g_strcmp0(last_text, "hello-from-another-app") != 0) { g_print("  FAIL text\n"); failures++; }
  else g_print("  PASS\n");

  /* Case 2: nothing changed since -> must stay silent (idempotent). */
  fires = 0;
  g_print("case 2: activation again, pasteboard unchanged\n");
  post(NSApplicationDidBecomeActiveNotification);
  if (fires != 0) { g_print("  FAIL expected 0 fires, got %d\n", fires); failures++; }
  else g_print("  PASS\n");

  /* Case 3: window regaining key focus must work too. */
  seed("second-copy");
  fires = 0;
  g_print("case 3: NSWindowDidBecomeKey after a foreign copy\n");
  post(NSWindowDidBecomeKeyNotification);
  if (fires != 1) { g_print("  FAIL expected 1 fire, got %d\n", fires); failures++; }
  else if (g_strcmp0(last_text, "second-copy") != 0) { g_print("  FAIL text\n"); failures++; }
  else g_print("  PASS\n");

  /* Case 4: when we own the clipboard ourselves, activation must not
   * revoke it -- that would break guest-to-host copy. */
  gtk_clipboard_set_text(cb, "owned-by-gtk", -1);
  fires = 0;
  g_print("case 4: we own the clipboard, then activation\n");
  post(NSApplicationDidBecomeActiveNotification);
  gchar *own = gtk_clipboard_wait_for_text(cb);
  if (fires != 0) { g_print("  FAIL expected 0 fires, got %d\n", fires); failures++; }
  else if (g_strcmp0(own, "owned-by-gtk") != 0) { g_print("  FAIL lost our own text: %s\n", own); failures++; }
  else g_print("  PASS\n");
  g_free(own);

  g_print(failures ? "\nRESULT: FAIL\n" : "\nRESULT: PASS\n");
  return failures ? 1 : 0;
}
