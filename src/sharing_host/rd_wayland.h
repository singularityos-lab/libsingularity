#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef struct _RdDisplay RdDisplay;
typedef struct _RdScreen RdScreen;

typedef void (*RdFrameFunc) (gpointer user_data, const guint8 *data, gint width, gint height, gint stride,
                             const gint *damage, gint n_damage);
typedef void (*RdStoppedFunc) (gpointer user_data);
typedef void (*RdOutputsFunc) (gpointer user_data);
typedef void (*RdClipboardFunc) (gpointer user_data, gchar **mime_types, gboolean own);
typedef void (*RdSendFunc) (gpointer user_data, const gchar *mime_type, gint fd);

RdDisplay *rd_display_new (GError **error);
void rd_display_free (RdDisplay *display);

gboolean rd_display_can_capture (RdDisplay *display);
gboolean rd_display_can_inject (RdDisplay *display);
gboolean rd_display_can_clipboard (RdDisplay *display);

gchar **rd_display_get_outputs (RdDisplay *display);
gboolean rd_display_get_output_info (RdDisplay *display, const gchar *name, gchar **description, gint *x, gint *y,
                                     gint *width, gint *height, gdouble *scale);
void rd_display_watch_outputs (RdDisplay *display, RdOutputsFunc func, gpointer user_data);

RdScreen *rd_screen_new (RdDisplay *display, const gchar *output, gboolean paint_cursor, RdFrameFunc frame_func,
                         gpointer frame_data, RdStoppedFunc stopped_func, gpointer stopped_data);
void rd_screen_free (RdScreen *screen);
gint rd_screen_get_width (RdScreen *screen);
gint rd_screen_get_height (RdScreen *screen);
void rd_screen_pointer_motion (RdScreen *screen, gdouble x, gdouble y);

void rd_display_pointer_motion_output (RdDisplay *display, const gchar *output, gdouble x, gdouble y);
void rd_display_pointer_motion (RdDisplay *display, gdouble dx, gdouble dy);
void rd_display_pointer_button (RdDisplay *display, guint32 button, gboolean pressed);
void rd_display_pointer_axis (RdDisplay *display, guint32 axis, gdouble value);
void rd_display_pointer_axis_discrete (RdDisplay *display, guint32 axis, gint steps);
gboolean rd_display_keysym (RdDisplay *display, guint32 keysym, gboolean pressed);
void rd_display_keycode (RdDisplay *display, guint32 keycode, gboolean pressed);
void rd_display_release_all (RdDisplay *display);
gchar *rd_display_get_keymap_layouts (RdDisplay *display);

void rd_display_watch_clipboard (RdDisplay *display, RdClipboardFunc func, gpointer user_data);
void rd_display_offer_clipboard (RdDisplay *display, gchar **mime_types, RdSendFunc func, gpointer user_data);
void rd_display_set_clipboard_text (RdDisplay *display, const gchar *text);
gboolean rd_display_receive_clipboard (RdDisplay *display, const gchar *mime_type, gint fd);
gchar *rd_display_text_mime_type (RdDisplay *display);

G_END_DECLS
