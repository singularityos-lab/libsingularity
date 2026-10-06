#define _GNU_SOURCE
#include "rd_wayland.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <gio/gio.h>
#include <glib-unix.h>
#include <linux/input-event-codes.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "ext-data-control-v1-client-protocol.h"
#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"
#include "rd_keymap.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "xdg-output-unstable-v1-client-protocol.h"

#define RD_POINTER_RESOLUTION 8
#define RD_MAX_EXTRA_KEYSYMS 24

typedef struct {
    RdDisplay *display;
    GPtrArray *mime_types;
} RdOffer;

typedef struct {
    RdDisplay *display;
    guint32 global;
    struct wl_output *output;
    struct zxdg_output_v1 *xdg;
    gchar *name;
    gchar *description;
    gchar *make;
    gchar *model;
    gint x;
    gint y;
    gint mode_width;
    gint mode_height;
    gint scale;
    gint transform;
    gint logical_x;
    gint logical_y;
    gint logical_width;
    gint logical_height;
    gboolean has_logical;
    gboolean ready;
} RdOutput;

typedef struct {
    RdScreen *screen;
    RdOutput *output;
    struct ext_image_capture_source_v1 *source;
    struct ext_image_copy_capture_session_v1 *session;
    struct ext_image_copy_capture_frame_v1 *frame;
    struct wl_buffer *buffer;
    guint8 *pixels;
    gsize size;
    gint stride;
    gint width;
    gint height;
    gint pending_width;
    gint pending_height;
    guint32 shm_format;
    gboolean shm_format_ok;
    gboolean need_full_damage;
    gboolean has_frame;
    GArray *damage;
    gint ox;
    gint oy;
} RdCapture;

struct _RdScreen {
    RdDisplay *display;
    gchar *output_name;
    gboolean paint_cursor;
    GPtrArray *captures;
    guint8 *canvas;
    gint width;
    gint height;
    gdouble scale;
    gint min_x;
    gint min_y;
    GArray *damage;
    RdFrameFunc frame_func;
    gpointer frame_data;
    RdStoppedFunc stopped_func;
    gpointer stopped_data;
    guint stopped_idle;
    gboolean stopped;
    gint busy;
    gboolean dead;
};

typedef struct {
    xkb_keycode_t keycode;
    gboolean override;
} RdPressed;

struct _RdDisplay {
    struct wl_display *wl;
    struct wl_registry *registry;
    struct wl_shm *shm;
    struct wl_seat *seat;
    struct wl_keyboard *wl_keyboard;
    GPtrArray *outputs;
    GList *screens;
    struct zxdg_output_manager_v1 *xdg_manager;
    struct ext_output_image_capture_source_manager_v1 *source_manager;
    struct ext_image_copy_capture_manager_v1 *copy_manager;
    struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
    struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
    struct ext_data_control_manager_v1 *data_manager;
    guint watch_id;
    gboolean broken;
    RdOutputsFunc outputs_func;
    gpointer outputs_data;

    struct zwlr_virtual_pointer_v1 *pointer;
    struct zwp_virtual_keyboard_v1 *keyboard;
    struct xkb_context *xkb;
    gchar *base_text;
    struct xkb_keymap *base_keymap;
    gchar *sent_text;
    struct xkb_keymap *keymap;
    struct xkb_state *state;
    xkb_keysym_t extra[RD_MAX_EXTRA_KEYSYMS];
    gint n_extra;
    GHashTable *pressed_syms;
    GHashTable *pressed_codes;
    GHashTable *pressed_buttons;

    struct ext_data_control_device_v1 *data_device;
    struct ext_data_control_offer_v1 *selection;
    struct ext_data_control_source_v1 *own_source;
    RdClipboardFunc clipboard_func;
    gpointer clipboard_data;
    RdSendFunc send_func;
    gpointer send_data;
    gchar *own_text;
};

static guint32
now_ms (void)
{
    return (guint32) (g_get_monotonic_time () / 1000);
}

static void
flush (RdDisplay *d)
{
    if (d->wl != NULL && !d->broken)
        wl_display_flush (d->wl);
}

static void screen_output_changed (RdScreen *s, RdOutput *output);
static void screen_output_removed (RdScreen *s, RdOutput *output);

static void
notify_outputs (RdDisplay *d)
{
    if (d->outputs_func != NULL)
        d->outputs_func (d->outputs_data);
}

static void
output_logical (RdOutput *o, gint *x, gint *y, gint *w, gint *h)
{
    if (o->has_logical && o->logical_width > 0 && o->logical_height > 0) {
        *x = o->logical_x;
        *y = o->logical_y;
        *w = o->logical_width;
        *h = o->logical_height;
        return;
    }
    gint pw = o->mode_width;
    gint ph = o->mode_height;
    if (o->transform % 2 == 1) {
        pw = o->mode_height;
        ph = o->mode_width;
    }
    gint scale = MAX (o->scale, 1);
    *x = o->x;
    *y = o->y;
    *w = pw / scale;
    *h = ph / scale;
}

static void
output_pixels (RdOutput *o, gint *w, gint *h)
{
    *w = o->transform % 2 == 1 ? o->mode_height : o->mode_width;
    *h = o->transform % 2 == 1 ? o->mode_width : o->mode_height;
}

static void
output_geometry (void *data, struct wl_output *output, int32_t x, int32_t y, int32_t pw, int32_t ph,
                 int32_t subpixel, const char *make, const char *model, int32_t transform)
{
    RdOutput *o = data;
    o->x = x;
    o->y = y;
    o->transform = transform;
    g_free (o->make);
    g_free (o->model);
    o->make = g_strdup (make);
    o->model = g_strdup (model);
}

static void
output_mode (void *data, struct wl_output *output, uint32_t flags, int32_t width, int32_t height, int32_t refresh)
{
    RdOutput *o = data;
    if (flags & WL_OUTPUT_MODE_CURRENT) {
        o->mode_width = width;
        o->mode_height = height;
    }
}

static void
output_done (void *data, struct wl_output *output)
{
    RdOutput *o = data;
    RdDisplay *d = o->display;
    o->ready = TRUE;
    for (GList *l = d->screens; l != NULL; l = l->next)
        screen_output_changed (l->data, o);
    notify_outputs (d);
}

static void
output_scale (void *data, struct wl_output *output, int32_t factor)
{
    RdOutput *o = data;
    o->scale = factor;
}

static void
output_name (void *data, struct wl_output *output, const char *name)
{
    RdOutput *o = data;
    g_free (o->name);
    o->name = g_strdup (name);
}

static void
output_description (void *data, struct wl_output *output, const char *description)
{
    RdOutput *o = data;
    g_free (o->description);
    o->description = g_strdup (description);
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static void
xdg_logical_position (void *data, struct zxdg_output_v1 *xdg, int32_t x, int32_t y)
{
    RdOutput *o = data;
    o->logical_x = x;
    o->logical_y = y;
    o->has_logical = TRUE;
}

static void
xdg_logical_size (void *data, struct zxdg_output_v1 *xdg, int32_t width, int32_t height)
{
    RdOutput *o = data;
    o->logical_width = width;
    o->logical_height = height;
    o->has_logical = TRUE;
}

static void
xdg_done (void *data, struct zxdg_output_v1 *xdg)
{
}

static void
xdg_name (void *data, struct zxdg_output_v1 *xdg, const char *name)
{
    RdOutput *o = data;
    if (o->name == NULL)
        o->name = g_strdup (name);
}

static void
xdg_description (void *data, struct zxdg_output_v1 *xdg, const char *description)
{
    RdOutput *o = data;
    if (o->description == NULL)
        o->description = g_strdup (description);
}

static const struct zxdg_output_v1_listener xdg_listener = {
    .logical_position = xdg_logical_position,
    .logical_size = xdg_logical_size,
    .done = xdg_done,
    .name = xdg_name,
    .description = xdg_description,
};

static void
output_bind_xdg (RdDisplay *d, RdOutput *o)
{
    if (d->xdg_manager == NULL || o->xdg != NULL)
        return;
    o->xdg = zxdg_output_manager_v1_get_xdg_output (d->xdg_manager, o->output);
    zxdg_output_v1_add_listener (o->xdg, &xdg_listener, o);
}

static void
output_free (RdOutput *o)
{
    if (o->xdg != NULL)
        zxdg_output_v1_destroy (o->xdg);
    if (o->output != NULL)
        wl_output_destroy (o->output);
    g_free (o->name);
    g_free (o->description);
    g_free (o->make);
    g_free (o->model);
    g_free (o);
}

static RdOutput *
find_output (RdDisplay *d, const gchar *name)
{
    for (guint i = 0; i < d->outputs->len; i++) {
        RdOutput *o = g_ptr_array_index (d->outputs, i);
        if (o->ready && o->name != NULL && g_strcmp0 (o->name, name) == 0)
            return o;
    }
    return NULL;
}

static void keyboard_keymap (void *data, struct wl_keyboard *keyboard, uint32_t format, int32_t fd, uint32_t size);
static void adopt_keymap (RdDisplay *d, gchar *text);

static void
keyboard_enter (void *data, struct wl_keyboard *keyboard, uint32_t serial, struct wl_surface *surface,
                struct wl_array *keys)
{
}

static void
keyboard_leave (void *data, struct wl_keyboard *keyboard, uint32_t serial, struct wl_surface *surface)
{
}

static void
keyboard_key (void *data, struct wl_keyboard *keyboard, uint32_t serial, uint32_t time, uint32_t key, uint32_t state)
{
}

static void
keyboard_modifiers (void *data, struct wl_keyboard *keyboard, uint32_t serial, uint32_t depressed, uint32_t latched,
                    uint32_t locked, uint32_t group)
{
}

static void
keyboard_repeat (void *data, struct wl_keyboard *keyboard, int32_t rate, int32_t delay)
{
}

static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = keyboard_repeat,
};

static void
seat_capabilities (void *data, struct wl_seat *seat, uint32_t caps)
{
    RdDisplay *d = data;
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && d->wl_keyboard == NULL) {
        d->wl_keyboard = wl_seat_get_keyboard (seat);
        wl_keyboard_add_listener (d->wl_keyboard, &keyboard_listener, d);
    } else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && d->wl_keyboard != NULL) {
        wl_keyboard_release (d->wl_keyboard);
        d->wl_keyboard = NULL;
    }
}

static void
seat_name (void *data, struct wl_seat *seat, const char *name)
{
}

static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities,
    .name = seat_name,
};

static void
registry_global (void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version)
{
    RdDisplay *d = data;

    if (strcmp (interface, wl_shm_interface.name) == 0 && d->shm == NULL) {
        d->shm = wl_registry_bind (registry, name, &wl_shm_interface, 1);
    } else if (strcmp (interface, wl_seat_interface.name) == 0 && d->seat == NULL) {
        d->seat = wl_registry_bind (registry, name, &wl_seat_interface, MIN (version, 5));
        wl_seat_add_listener (d->seat, &seat_listener, d);
    } else if (strcmp (interface, wl_output_interface.name) == 0) {
        RdOutput *o = g_new0 (RdOutput, 1);
        o->display = d;
        o->global = name;
        o->scale = 1;
        o->output = wl_registry_bind (registry, name, &wl_output_interface, MIN (version, 4));
        wl_output_add_listener (o->output, &output_listener, o);
        g_ptr_array_add (d->outputs, o);
        output_bind_xdg (d, o);
    } else if (strcmp (interface, zxdg_output_manager_v1_interface.name) == 0) {
        d->xdg_manager = wl_registry_bind (registry, name, &zxdg_output_manager_v1_interface, MIN (version, 3));
        for (guint i = 0; i < d->outputs->len; i++)
            output_bind_xdg (d, g_ptr_array_index (d->outputs, i));
    } else if (strcmp (interface, ext_output_image_capture_source_manager_v1_interface.name) == 0) {
        d->source_manager = wl_registry_bind (registry, name, &ext_output_image_capture_source_manager_v1_interface, 1);
    } else if (strcmp (interface, ext_image_copy_capture_manager_v1_interface.name) == 0) {
        d->copy_manager = wl_registry_bind (registry, name, &ext_image_copy_capture_manager_v1_interface, 1);
    } else if (strcmp (interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        d->pointer_manager = wl_registry_bind (registry, name, &zwlr_virtual_pointer_manager_v1_interface,
                                               MIN (version, 2));
    } else if (strcmp (interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        d->keyboard_manager = wl_registry_bind (registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    } else if (strcmp (interface, ext_data_control_manager_v1_interface.name) == 0) {
        d->data_manager = wl_registry_bind (registry, name, &ext_data_control_manager_v1_interface, 1);
    }
}

static void
registry_global_remove (void *data, struct wl_registry *registry, uint32_t name)
{
    RdDisplay *d = data;
    for (guint i = 0; i < d->outputs->len; i++) {
        RdOutput *o = g_ptr_array_index (d->outputs, i);
        if (o->global != name)
            continue;
        GList *screens = g_list_copy (d->screens);
        for (GList *l = screens; l != NULL; l = l->next)
            screen_output_removed (l->data, o);
        g_list_free (screens);
        g_ptr_array_remove_index (d->outputs, i);
        output_free (o);
        notify_outputs (d);
        return;
    }
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void screen_emit_stopped (RdScreen *s);

static gboolean
display_ready (gint fd, GIOCondition condition, gpointer user_data)
{
    RdDisplay *d = user_data;

    if ((condition & (G_IO_ERR | G_IO_HUP)) != 0 || wl_display_dispatch (d->wl) < 0) {
        g_warning ("rd_wayland: lost the compositor connection");
        d->broken = TRUE;
        d->watch_id = 0;
        for (GList *l = d->screens; l != NULL; l = l->next)
            screen_emit_stopped (l->data);
        return G_SOURCE_REMOVE;
    }
    flush (d);
    return G_SOURCE_CONTINUE;
}

static void setup_input (RdDisplay *d);
static void setup_clipboard (RdDisplay *d);

RdDisplay *
rd_display_new (GError **error)
{
    RdDisplay *d = g_new0 (RdDisplay, 1);

    d->wl = wl_display_connect (NULL);
    if (d->wl == NULL) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_NOT_CONNECTED, "Cannot connect to the Wayland compositor");
        g_free (d);
        return NULL;
    }
    d->outputs = g_ptr_array_new ();
    d->pressed_syms = g_hash_table_new_full (g_direct_hash, g_direct_equal, NULL, g_free);
    d->pressed_codes = g_hash_table_new (g_direct_hash, g_direct_equal);
    d->pressed_buttons = g_hash_table_new (g_direct_hash, g_direct_equal);
    d->xkb = xkb_context_new (XKB_CONTEXT_NO_FLAGS);
    d->registry = wl_display_get_registry (d->wl);
    wl_registry_add_listener (d->registry, &registry_listener, d);
    wl_display_roundtrip (d->wl);
    wl_display_roundtrip (d->wl);

    setup_input (d);
    setup_clipboard (d);
    wl_display_roundtrip (d->wl);
    wl_display_roundtrip (d->wl);
    if (d->keyboard != NULL && d->keymap == NULL) {
        g_message ("rd_wayland: the compositor sent no keymap, using the default one");
        struct xkb_rule_names names = { 0 };
        struct xkb_keymap *fallback = xkb_keymap_new_from_names (d->xkb, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (fallback != NULL) {
            gchar *raw = xkb_keymap_get_as_string (fallback, XKB_KEYMAP_FORMAT_TEXT_V1);
            adopt_keymap (d, g_strdup (raw));
            free (raw);
            xkb_keymap_unref (fallback);
        }
    }

    d->watch_id = g_unix_fd_add (wl_display_get_fd (d->wl), G_IO_IN | G_IO_ERR | G_IO_HUP, display_ready, d);
    return d;
}

gboolean
rd_display_can_capture (RdDisplay *d)
{
    return d != NULL && !d->broken && d->shm != NULL && d->outputs->len > 0 && d->source_manager != NULL &&
           d->copy_manager != NULL;
}

gboolean
rd_display_can_inject (RdDisplay *d)
{
    return d != NULL && !d->broken && d->pointer != NULL && d->keyboard != NULL && d->keymap != NULL;
}

gboolean
rd_display_can_clipboard (RdDisplay *d)
{
    return d != NULL && !d->broken && d->data_device != NULL;
}

gchar **
rd_display_get_outputs (RdDisplay *d)
{
    GPtrArray *list = g_ptr_array_new ();
    for (guint i = 0; d != NULL && i < d->outputs->len; i++) {
        RdOutput *o = g_ptr_array_index (d->outputs, i);
        if (o->ready && o->name != NULL)
            g_ptr_array_add (list, g_strdup (o->name));
    }
    g_ptr_array_add (list, NULL);
    return (gchar **) g_ptr_array_free (list, FALSE);
}

gboolean
rd_display_get_output_info (RdDisplay *d, const gchar *name, gchar **description, gint *x, gint *y, gint *width,
                            gint *height, gdouble *scale)
{
    RdOutput *o = find_output (d, name);
    *description = NULL;
    *x = *y = *width = *height = 0;
    *scale = 1;
    if (o == NULL)
        return FALSE;
    output_logical (o, x, y, width, height);
    gint pw, ph;
    output_pixels (o, &pw, &ph);
    *scale = *width > 0 ? (gdouble) pw / *width : 1;
    if (o->description != NULL && o->description[0] != '\0')
        *description = g_strdup (o->description);
    else if (o->make != NULL && o->model != NULL)
        *description = g_strdup_printf ("%s %s", o->make, o->model);
    else
        *description = g_strdup (o->name);
    return TRUE;
}

void
rd_display_watch_outputs (RdDisplay *d, RdOutputsFunc func, gpointer user_data)
{
    d->outputs_func = func;
    d->outputs_data = user_data;
}

static void
destroy_buffer (RdCapture *c)
{
    if (c->buffer != NULL) {
        wl_buffer_destroy (c->buffer);
        c->buffer = NULL;
    }
    if (c->pixels != NULL) {
        munmap (c->pixels, c->size);
        c->pixels = NULL;
    }
    c->size = 0;
}

static gboolean
create_buffer (RdCapture *c)
{
    RdDisplay *d = c->screen->display;
    destroy_buffer (c);
    c->width = c->pending_width;
    c->height = c->pending_height;
    c->stride = c->width * 4;
    c->size = (gsize) c->stride * c->height;
    c->has_frame = FALSE;
    if (c->size == 0)
        return FALSE;

    gint fd = memfd_create ("singularity-remote-desktop", MFD_CLOEXEC);
    if (fd < 0 || ftruncate (fd, (off_t) c->size) < 0) {
        if (fd >= 0)
            close (fd);
        return FALSE;
    }
    c->pixels = mmap (NULL, c->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (c->pixels == MAP_FAILED) {
        c->pixels = NULL;
        close (fd);
        return FALSE;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool (d->shm, fd, (int32_t) c->size);
    c->buffer = wl_shm_pool_create_buffer (pool, 0, c->width, c->height, c->stride, c->shm_format);
    wl_shm_pool_destroy (pool);
    close (fd);
    c->need_full_damage = TRUE;
    return c->buffer != NULL;
}

static void
capture_stop (RdCapture *c)
{
    if (c->frame != NULL) {
        ext_image_copy_capture_frame_v1_destroy (c->frame);
        c->frame = NULL;
    }
    if (c->session != NULL) {
        ext_image_copy_capture_session_v1_destroy (c->session);
        c->session = NULL;
    }
    if (c->source != NULL) {
        ext_image_capture_source_v1_destroy (c->source);
        c->source = NULL;
    }
    destroy_buffer (c);
}

static void
capture_free (RdCapture *c)
{
    capture_stop (c);
    g_array_unref (c->damage);
    g_free (c);
}

static void
screen_emit_stopped_now (RdScreen *s)
{
    if (s->stopped_func != NULL)
        s->stopped_func (s->stopped_data);
}

static gboolean
screen_stopped_idle (gpointer data)
{
    RdScreen *s = data;
    s->stopped_idle = 0;
    s->busy++;
    screen_emit_stopped_now (s);
    s->busy--;
    if (s->dead && s->busy == 0)
        rd_screen_free (s);
    return G_SOURCE_REMOVE;
}

static void
screen_emit_stopped (RdScreen *s)
{
    if (s->stopped)
        return;
    s->stopped = TRUE;
    for (guint i = 0; i < s->captures->len; i++)
        capture_stop (g_ptr_array_index (s->captures, i));
    if (s->stopped_idle == 0)
        s->stopped_idle = g_idle_add (screen_stopped_idle, s);
}

static void
screen_emit (RdScreen *s)
{
    if (s->frame_func == NULL || s->canvas == NULL || s->damage->len == 0) {
        g_array_set_size (s->damage, 0);
        return;
    }
    s->busy++;
    s->frame_func (s->frame_data, s->canvas, s->width, s->height, s->width * 4, (const gint *) s->damage->data,
                   (gint) s->damage->len);
    s->busy--;
    g_array_set_size (s->damage, 0);
}

static void
screen_add_damage (RdScreen *s, gint x, gint y, gint w, gint h)
{
    gint x2 = MIN (x + w, s->width);
    gint y2 = MIN (y + h, s->height);
    x = MAX (x, 0);
    y = MAX (y, 0);
    if (x2 <= x || y2 <= y)
        return;
    gint rect[4] = { x, y, x2 - x, y2 - y };
    g_array_append_vals (s->damage, rect, 4);
}

static void
blit (RdScreen *s, RdCapture *c, gint x, gint y, gint w, gint h)
{
    gint x2 = MIN (x + w, c->width);
    gint y2 = MIN (y + h, c->height);
    x = MAX (x, 0);
    y = MAX (y, 0);
    x2 = MIN (x2, s->width - c->ox);
    y2 = MIN (y2, s->height - c->oy);
    if (x2 <= x || y2 <= y || c->pixels == NULL)
        return;
    for (gint row = y; row < y2; row++)
        memcpy (s->canvas + ((gsize) (c->oy + row) * s->width + c->ox + x) * 4,
                c->pixels + (gsize) row * c->stride + (gsize) x * 4, (gsize) (x2 - x) * 4);
    screen_add_damage (s, c->ox + x, c->oy + y, x2 - x, y2 - y);
}

static void
screen_layout (RdScreen *s)
{
    gint min_x = G_MAXINT, min_y = G_MAXINT;
    gdouble scale = 1;

    for (guint i = 0; i < s->captures->len; i++) {
        RdCapture *c = g_ptr_array_index (s->captures, i);
        gint lx, ly, lw, lh, pw, ph;
        output_logical (c->output, &lx, &ly, &lw, &lh);
        output_pixels (c->output, &pw, &ph);
        if (c->width > 0)
            pw = c->width;
        min_x = MIN (min_x, lx);
        min_y = MIN (min_y, ly);
        if (lw > 0)
            scale = MAX (scale, (gdouble) pw / lw);
    }
    if (s->captures->len == 0)
        return;

    gint width = 0, height = 0;
    gboolean moved = FALSE;
    guint n = s->captures->len;
    gint *lx = g_new (gint, n), *ly = g_new (gint, n), *lw = g_new (gint, n), *lh = g_new (gint, n);
    gint *pw = g_new (gint, n), *ph = g_new (gint, n), *ox = g_new0 (gint, n), *oy = g_new0 (gint, n);
    for (guint i = 0; i < n; i++) {
        RdCapture *c = g_ptr_array_index (s->captures, i);
        output_logical (c->output, &lx[i], &ly[i], &lw[i], &lh[i]);
        output_pixels (c->output, &pw[i], &ph[i]);
        if (c->width > 0) {
            pw[i] = c->width;
            ph[i] = c->height;
        }
    }
    for (guint pass = 0; pass < n; pass++) {
        for (guint i = 0; i < n; i++) {
            for (guint j = 0; j < n; j++) {
                if (j == i)
                    continue;
                if (lx[j] + lw[j] <= lx[i])
                    ox[i] = MAX (ox[i], ox[j] + pw[j]);
                if (ly[j] + lh[j] <= ly[i])
                    oy[i] = MAX (oy[i], oy[j] + ph[j]);
            }
        }
    }
    for (guint i = 0; i < n; i++) {
        RdCapture *c = g_ptr_array_index (s->captures, i);
        if (ox[i] != c->ox || oy[i] != c->oy)
            moved = TRUE;
        c->ox = ox[i];
        c->oy = oy[i];
        width = MAX (width, ox[i] + pw[i]);
        height = MAX (height, oy[i] + ph[i]);
    }
    g_free (lx); g_free (ly); g_free (lw); g_free (lh); g_free (pw); g_free (ph); g_free (ox); g_free (oy);
    s->scale = scale;
    s->min_x = min_x;
    s->min_y = min_y;
    if (!moved && width == s->width && height == s->height && s->canvas != NULL)
        return;

    g_free (s->canvas);
    s->width = width;
    s->height = height;
    s->canvas = g_malloc0 ((gsize) width * height * 4);
    g_array_set_size (s->damage, 0);
    gboolean any = FALSE;
    for (guint i = 0; i < s->captures->len; i++) {
        RdCapture *c = g_ptr_array_index (s->captures, i);
        if (c->has_frame) {
            blit (s, c, 0, 0, c->width, c->height);
            any = TRUE;
        }
    }
    g_array_set_size (s->damage, 0);
    if (any) {
        screen_add_damage (s, 0, 0, width, height);
        screen_emit (s);
    }
}

static void capture_next (RdCapture *c);

static void
frame_transform (void *data, struct ext_image_copy_capture_frame_v1 *frame, uint32_t transform)
{
}

static void
frame_damage (void *data, struct ext_image_copy_capture_frame_v1 *frame, int32_t x, int32_t y, int32_t w, int32_t h)
{
    RdCapture *c = data;
    gint rect[4] = { x, y, w, h };
    g_array_append_vals (c->damage, rect, 4);
}

static void
frame_presentation_time (void *data, struct ext_image_copy_capture_frame_v1 *frame, uint32_t hi, uint32_t lo,
                         uint32_t nsec)
{
}

static void
frame_ready (void *data, struct ext_image_copy_capture_frame_v1 *frame)
{
    RdCapture *c = data;
    RdScreen *s = c->screen;

    ext_image_copy_capture_frame_v1_destroy (frame);
    c->frame = NULL;
    gboolean full = !c->has_frame || c->need_full_damage;
    c->need_full_damage = FALSE;
    c->has_frame = TRUE;
    if (full) {
        blit (s, c, 0, 0, c->width, c->height);
    } else {
        gint *r = (gint *) c->damage->data;
        for (guint i = 0; i + 3 < c->damage->len; i += 4)
            blit (s, c, r[i], r[i + 1], r[i + 2], r[i + 3]);
    }
    g_array_set_size (c->damage, 0);
    s->busy++;
    screen_emit (s);
    s->busy--;
    if (s->dead) {
        if (s->busy == 0)
            rd_screen_free (s);
        return;
    }
    capture_next (c);
}

static void
frame_failed (void *data, struct ext_image_copy_capture_frame_v1 *frame, uint32_t reason)
{
    RdCapture *c = data;

    ext_image_copy_capture_frame_v1_destroy (frame);
    c->frame = NULL;
    g_array_set_size (c->damage, 0);
    if (reason == EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS)
        return;
    if (reason == EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED) {
        screen_emit_stopped (c->screen);
        return;
    }
    capture_next (c);
}

static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {
    .transform = frame_transform,
    .damage = frame_damage,
    .presentation_time = frame_presentation_time,
    .ready = frame_ready,
    .failed = frame_failed,
};

static void
capture_next (RdCapture *c)
{
    if (c->session == NULL || c->buffer == NULL || c->frame != NULL)
        return;
    c->frame = ext_image_copy_capture_session_v1_create_frame (c->session);
    ext_image_copy_capture_frame_v1_add_listener (c->frame, &frame_listener, c);
    ext_image_copy_capture_frame_v1_attach_buffer (c->frame, c->buffer);
    if (c->need_full_damage)
        ext_image_copy_capture_frame_v1_damage_buffer (c->frame, 0, 0, c->width, c->height);
    ext_image_copy_capture_frame_v1_capture (c->frame);
    flush (c->screen->display);
}

static void
session_buffer_size (void *data, struct ext_image_copy_capture_session_v1 *session, uint32_t width, uint32_t height)
{
    RdCapture *c = data;
    c->pending_width = (gint) width;
    c->pending_height = (gint) height;
}

static void
session_shm_format (void *data, struct ext_image_copy_capture_session_v1 *session, uint32_t format)
{
    RdCapture *c = data;
    if (format == WL_SHM_FORMAT_XRGB8888 || (format == WL_SHM_FORMAT_ARGB8888 && !c->shm_format_ok)) {
        c->shm_format = format;
        c->shm_format_ok = TRUE;
    }
}

static void
session_dmabuf_device (void *data, struct ext_image_copy_capture_session_v1 *session, struct wl_array *device)
{
}

static void
session_dmabuf_format (void *data, struct ext_image_copy_capture_session_v1 *session, uint32_t format,
                       struct wl_array *modifiers)
{
}

static void
session_done (void *data, struct ext_image_copy_capture_session_v1 *session)
{
    RdCapture *c = data;

    if (!c->shm_format_ok) {
        g_warning ("rd_wayland: the compositor offers no 32 bit shm format");
        return;
    }
    if (c->buffer == NULL || c->pending_width != c->width || c->pending_height != c->height) {
        if (c->frame != NULL) {
            ext_image_copy_capture_frame_v1_destroy (c->frame);
            c->frame = NULL;
        }
        if (!create_buffer (c)) {
            g_warning ("rd_wayland: cannot allocate the capture buffer");
            return;
        }
        screen_layout (c->screen);
        if (c->screen->dead)
            return;
    }
    capture_next (c);
}

static void
session_stopped (void *data, struct ext_image_copy_capture_session_v1 *session)
{
    RdCapture *c = data;
    RdScreen *s = c->screen;
    if (s->output_name == NULL && s->captures->len > 1) {
        g_ptr_array_remove (s->captures, c);
        capture_free (c);
        screen_layout (s);
        return;
    }
    screen_emit_stopped (s);
}

static const struct ext_image_copy_capture_session_v1_listener session_listener = {
    .buffer_size = session_buffer_size,
    .shm_format = session_shm_format,
    .dmabuf_device = session_dmabuf_device,
    .dmabuf_format = session_dmabuf_format,
    .done = session_done,
    .stopped = session_stopped,
};

static void
screen_add_capture (RdScreen *s, RdOutput *o)
{
    RdDisplay *d = s->display;
    RdCapture *c = g_new0 (RdCapture, 1);
    c->screen = s;
    c->output = o;
    c->damage = g_array_new (FALSE, FALSE, sizeof (gint));
    c->source = ext_output_image_capture_source_manager_v1_create_source (d->source_manager, o->output);
    c->session = ext_image_copy_capture_manager_v1_create_session (
        d->copy_manager, c->source, s->paint_cursor ? EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_OPTIONS_PAINT_CURSORS : 0);
    ext_image_copy_capture_session_v1_add_listener (c->session, &session_listener, c);
    g_ptr_array_add (s->captures, c);
}

static RdCapture *
screen_capture_for (RdScreen *s, RdOutput *o)
{
    for (guint i = 0; i < s->captures->len; i++) {
        RdCapture *c = g_ptr_array_index (s->captures, i);
        if (c->output == o)
            return c;
    }
    return NULL;
}

static void
screen_output_changed (RdScreen *s, RdOutput *o)
{
    if (s->stopped || s->dead)
        return;
    if (screen_capture_for (s, o) != NULL) {
        screen_layout (s);
        return;
    }
    if (s->output_name == NULL && o->name != NULL) {
        screen_add_capture (s, o);
        screen_layout (s);
        flush (s->display);
    }
}

static void
screen_output_removed (RdScreen *s, RdOutput *o)
{
    RdCapture *c = screen_capture_for (s, o);
    if (c == NULL)
        return;
    g_ptr_array_remove (s->captures, c);
    capture_free (c);
    if (s->captures->len == 0 || s->output_name != NULL) {
        screen_emit_stopped (s);
        return;
    }
    screen_layout (s);
}

RdScreen *
rd_screen_new (RdDisplay *d, const gchar *output, gboolean paint_cursor, RdFrameFunc frame_func, gpointer frame_data,
               RdStoppedFunc stopped_func, gpointer stopped_data)
{
    if (!rd_display_can_capture (d))
        return NULL;
    gboolean all = output == NULL || output[0] == '\0' || g_strcmp0 (output, "all") == 0;
    if (!all && find_output (d, output) == NULL)
        return NULL;

    RdScreen *s = g_new0 (RdScreen, 1);
    s->display = d;
    s->output_name = all ? NULL : g_strdup (output);
    s->paint_cursor = paint_cursor;
    s->captures = g_ptr_array_new ();
    s->damage = g_array_new (FALSE, FALSE, sizeof (gint));
    s->scale = 1;
    s->frame_func = frame_func;
    s->frame_data = frame_data;
    s->stopped_func = stopped_func;
    s->stopped_data = stopped_data;
    for (guint i = 0; i < d->outputs->len; i++) {
        RdOutput *o = g_ptr_array_index (d->outputs, i);
        if (!o->ready || o->name == NULL)
            continue;
        if (all || g_strcmp0 (o->name, output) == 0)
            screen_add_capture (s, o);
    }
    if (s->captures->len == 0) {
        g_ptr_array_unref (s->captures);
        g_array_unref (s->damage);
        g_free (s->output_name);
        g_free (s);
        return NULL;
    }
    d->screens = g_list_prepend (d->screens, s);
    screen_layout (s);
    flush (d);
    return s;
}

void
rd_screen_free (RdScreen *s)
{
    if (s == NULL)
        return;
    if (s->busy > 0) {
        s->dead = TRUE;
        s->frame_func = NULL;
        s->stopped_func = NULL;
        return;
    }
    if (s->stopped_idle != 0)
        g_source_remove (s->stopped_idle);
    if (s->display != NULL)
        s->display->screens = g_list_remove (s->display->screens, s);
    for (guint i = 0; i < s->captures->len; i++)
        capture_free (g_ptr_array_index (s->captures, i));
    g_ptr_array_unref (s->captures);
    g_array_unref (s->damage);
    if (s->display != NULL)
        flush (s->display);
    g_free (s->canvas);
    g_free (s->output_name);
    g_free (s);
}

gint
rd_screen_get_width (RdScreen *s)
{
    return s->width;
}

gint
rd_screen_get_height (RdScreen *s)
{
    return s->height;
}

static void
pointer_layout (RdDisplay *d, gdouble lx, gdouble ly)
{
    if (d->pointer == NULL)
        return;
    gint bx = G_MAXINT, by = G_MAXINT, bx2 = G_MININT, by2 = G_MININT;
    for (guint i = 0; i < d->outputs->len; i++) {
        RdOutput *o = g_ptr_array_index (d->outputs, i);
        if (!o->ready)
            continue;
        gint x, y, w, h;
        output_logical (o, &x, &y, &w, &h);
        bx = MIN (bx, x);
        by = MIN (by, y);
        bx2 = MAX (bx2, x + w);
        by2 = MAX (by2, y + h);
    }
    if (bx2 <= bx || by2 <= by)
        return;
    guint32 ext_x = (guint32) (bx2 - bx) * RD_POINTER_RESOLUTION;
    guint32 ext_y = (guint32) (by2 - by) * RD_POINTER_RESOLUTION;
    gdouble px = CLAMP ((lx - bx) * RD_POINTER_RESOLUTION, 0, ext_x - 1);
    gdouble py = CLAMP ((ly - by) * RD_POINTER_RESOLUTION, 0, ext_y - 1);
    zwlr_virtual_pointer_v1_motion_absolute (d->pointer, now_ms (), (guint32) px, (guint32) py, ext_x, ext_y);
    zwlr_virtual_pointer_v1_frame (d->pointer);
    flush (d);
}

void
rd_screen_pointer_motion (RdScreen *s, gdouble x, gdouble y)
{
    if (s->display == NULL || s->stopped)
        return;
    for (guint i = 0; i < s->captures->len; i++) {
        RdCapture *c = g_ptr_array_index (s->captures, i);
        gint w = c->width > 0 ? c->width : 0;
        gint h = c->height > 0 ? c->height : 0;
        if (x < c->ox || y < c->oy || x >= c->ox + w || y >= c->oy + h)
            continue;
        gint lx, ly, lw, lh;
        output_logical (c->output, &lx, &ly, &lw, &lh);
        pointer_layout (s->display, lx + (x - c->ox) * lw / w, ly + (y - c->oy) * lh / h);
        return;
    }
    pointer_layout (s->display, s->min_x + x / s->scale, s->min_y + y / s->scale);
}

void
rd_display_pointer_motion_output (RdDisplay *d, const gchar *name, gdouble x, gdouble y)
{
    RdOutput *o = name != NULL && name[0] != '\0' ? find_output (d, name) : NULL;
    if (o == NULL && d->outputs->len > 0)
        o = g_ptr_array_index (d->outputs, 0);
    if (o == NULL)
        return;
    gint lx, ly, lw, lh;
    output_logical (o, &lx, &ly, &lw, &lh);
    pointer_layout (d, lx + CLAMP (x, 0, lw), ly + CLAMP (y, 0, lh));
}

static gboolean
send_keymap_text (RdDisplay *d, const gchar *text)
{
    gsize size = strlen (text) + 1;
    gint fd = memfd_create ("singularity-remote-keymap", MFD_CLOEXEC);
    gboolean ok = fd >= 0 && write (fd, text, size) == (gssize) size;
    if (ok)
        zwp_virtual_keyboard_v1_keymap (d->keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t) size);
    if (fd >= 0)
        close (fd);
    return ok;
}

static gboolean
install_keymap (RdDisplay *d, const gchar *text)
{
    struct xkb_keymap *keymap = xkb_keymap_new_from_string (d->xkb, text, XKB_KEYMAP_FORMAT_TEXT_V1,
                                                            XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (keymap == NULL)
        return FALSE;
    gchar *raw = xkb_keymap_get_as_string (keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    if (d->keyboard != NULL && !send_keymap_text (d, raw)) {
        free (raw);
        xkb_keymap_unref (keymap);
        return FALSE;
    }
    g_free (d->sent_text);
    d->sent_text = g_strdup (raw);
    free (raw);
    if (d->state != NULL)
        xkb_state_unref (d->state);
    if (d->keymap != NULL)
        xkb_keymap_unref (d->keymap);
    d->keymap = keymap;
    d->state = xkb_state_new (keymap);
    flush (d);
    return TRUE;
}

static void
adopt_keymap (RdDisplay *d, gchar *text)
{
    if (text == NULL)
        return;
    if (g_strcmp0 (text, d->sent_text) == 0 || g_strcmp0 (text, d->base_text) == 0) {
        g_free (text);
        return;
    }
    struct xkb_keymap *base = xkb_keymap_new_from_string (d->xkb, text, XKB_KEYMAP_FORMAT_TEXT_V1,
                                                          XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (base == NULL) {
        g_free (text);
        return;
    }
    if (d->base_keymap != NULL)
        xkb_keymap_unref (d->base_keymap);
    d->base_keymap = base;
    g_free (d->base_text);
    d->base_text = text;
    d->n_extra = 0;
    g_hash_table_remove_all (d->pressed_syms);
    if (!install_keymap (d, text)) {
        g_warning ("rd_wayland: cannot use the keymap of the session");
        return;
    }
    gchar *layouts = rd_display_get_keymap_layouts (d);
    g_message ("rd_wayland: typing with the %s keyboard layout", layouts);
    g_free (layouts);
}

static void
keyboard_keymap (void *data, struct wl_keyboard *keyboard, uint32_t format, int32_t fd, uint32_t size)
{
    RdDisplay *d = data;
    gchar *text = NULL;

    if (format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 && size > 0) {
        gchar *map = mmap (NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (map != MAP_FAILED) {
            text = rd_keymap_normalize (d->xkb, map);
            munmap (map, size);
        }
    }
    close (fd);
    adopt_keymap (d, text);
}

static void
setup_input (RdDisplay *d)
{
    if (d->seat == NULL)
        return;
    if (d->pointer_manager != NULL)
        d->pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer (d->pointer_manager, d->seat);
    if (d->keyboard_manager != NULL)
        d->keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard (d->keyboard_manager, d->seat);
}

gchar *
rd_display_get_keymap_layouts (RdDisplay *d)
{
    if (d->keymap == NULL)
        return g_strdup ("");
    GString *s = g_string_new (NULL);
    for (xkb_layout_index_t i = 0; i < xkb_keymap_num_layouts (d->keymap); i++) {
        const gchar *name = xkb_keymap_layout_get_name (d->keymap, i);
        if (s->len > 0)
            g_string_append (s, ", ");
        g_string_append (s, name != NULL ? name : "?");
    }
    return g_string_free (s, FALSE);
}

void
rd_display_pointer_motion (RdDisplay *d, gdouble dx, gdouble dy)
{
    if (d->pointer == NULL)
        return;
    zwlr_virtual_pointer_v1_motion (d->pointer, now_ms (), wl_fixed_from_double (dx), wl_fixed_from_double (dy));
    zwlr_virtual_pointer_v1_frame (d->pointer);
    flush (d);
}

void
rd_display_pointer_button (RdDisplay *d, guint32 button, gboolean pressed)
{
    if (d->pointer == NULL)
        return;
    if (pressed == g_hash_table_contains (d->pressed_buttons, GUINT_TO_POINTER (button)))
        return;
    if (pressed)
        g_hash_table_add (d->pressed_buttons, GUINT_TO_POINTER (button));
    else
        g_hash_table_remove (d->pressed_buttons, GUINT_TO_POINTER (button));
    zwlr_virtual_pointer_v1_button (d->pointer, now_ms (), button,
                                    pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame (d->pointer);
    flush (d);
}

void
rd_display_pointer_axis (RdDisplay *d, guint32 axis, gdouble value)
{
    if (d->pointer == NULL || axis > 1)
        return;
    zwlr_virtual_pointer_v1_axis_source (d->pointer, WL_POINTER_AXIS_SOURCE_FINGER);
    zwlr_virtual_pointer_v1_axis (d->pointer, now_ms (), axis, wl_fixed_from_double (value));
    zwlr_virtual_pointer_v1_frame (d->pointer);
    flush (d);
}

void
rd_display_pointer_axis_discrete (RdDisplay *d, guint32 axis, gint steps)
{
    if (d->pointer == NULL || axis > 1 || steps == 0)
        return;
    zwlr_virtual_pointer_v1_axis_source (d->pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
    zwlr_virtual_pointer_v1_axis_discrete (d->pointer, now_ms (), axis, wl_fixed_from_double (steps * 15.0), steps);
    zwlr_virtual_pointer_v1_frame (d->pointer);
    flush (d);
}

static void
send_modifiers (RdDisplay *d)
{
    zwp_virtual_keyboard_v1_modifiers (d->keyboard, xkb_state_serialize_mods (d->state, XKB_STATE_MODS_DEPRESSED),
                                       xkb_state_serialize_mods (d->state, XKB_STATE_MODS_LATCHED),
                                       xkb_state_serialize_mods (d->state, XKB_STATE_MODS_LOCKED),
                                       xkb_state_serialize_layout (d->state, XKB_STATE_LAYOUT_EFFECTIVE));
}

static void
send_key (RdDisplay *d, xkb_keycode_t keycode, gboolean pressed)
{
    zwp_virtual_keyboard_v1_key (d->keyboard, now_ms (), keycode - 8,
                                 pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
    xkb_state_update_key (d->state, keycode, pressed ? XKB_KEY_DOWN : XKB_KEY_UP);
    send_modifiers (d);
}

static gboolean
extend_keymap (RdDisplay *d, xkb_keysym_t keysym)
{
    if (d->base_text == NULL || d->base_keymap == NULL)
        return FALSE;
    if (d->n_extra >= RD_MAX_EXTRA_KEYSYMS)
        d->n_extra = 0;
    d->extra[d->n_extra++] = keysym;
    gchar *text = rd_keymap_add_keysyms (d->base_text, d->base_keymap, d->extra, d->n_extra);
    if (text == NULL) {
        d->n_extra--;
        return FALSE;
    }
    GList *held = g_hash_table_get_keys (d->pressed_syms);
    gboolean busy = held != NULL || g_hash_table_size (d->pressed_codes) > 0;
    g_list_free (held);
    if (busy) {
        d->n_extra--;
        g_free (text);
        return FALSE;
    }
    gboolean ok = install_keymap (d, text);
    g_free (text);
    if (!ok)
        d->n_extra--;
    return ok;
}

gboolean
rd_display_keysym (RdDisplay *d, guint32 keysym, gboolean pressed)
{
    if (d->keyboard == NULL || d->keymap == NULL)
        return FALSE;

    gpointer key = GUINT_TO_POINTER (keysym);
    if (!pressed) {
        RdPressed *p = g_hash_table_lookup (d->pressed_syms, key);
        if (p == NULL)
            return TRUE;
        xkb_keycode_t code = p->keycode;
        gboolean was_override = p->override;
        g_hash_table_remove (d->pressed_syms, key);
        if (was_override) {
            zwp_virtual_keyboard_v1_key (d->keyboard, now_ms (), code - 8, WL_KEYBOARD_KEY_STATE_RELEASED);
        } else {
            send_key (d, code, FALSE);
        }
        flush (d);
        return TRUE;
    }

    if (g_hash_table_contains (d->pressed_syms, key))
        rd_display_keysym (d, keysym, FALSE);

    xkb_layout_index_t layout = xkb_state_serialize_layout (d->state, XKB_STATE_LAYOUT_EFFECTIVE);
    RdKeyTarget target;
    if (!rd_keymap_find (d->keymap, keysym, layout, &target)) {
        if (!rd_keysym_is_text (keysym) || !extend_keymap (d, keysym) ||
            !rd_keymap_find (d->keymap, keysym, layout, &target))
            return FALSE;
    }

    gboolean override = FALSE;
    if (rd_keysym_is_text (keysym)) {
        override = xkb_state_key_get_one_sym (d->state, target.keycode) != keysym ||
                   xkb_state_key_get_layout (d->state, target.keycode) != target.layout;
    }

    RdPressed *p = g_new0 (RdPressed, 1);
    p->keycode = target.keycode;
    p->override = override;
    g_hash_table_insert (d->pressed_syms, key, p);

    if (override) {
        xkb_mod_mask_t depressed = xkb_state_serialize_mods (d->state, XKB_STATE_MODS_DEPRESSED);
        xkb_mod_mask_t latched = xkb_state_serialize_mods (d->state, XKB_STATE_MODS_LATCHED);
        xkb_mod_mask_t locked = xkb_state_serialize_mods (d->state, XKB_STATE_MODS_LOCKED);
        zwp_virtual_keyboard_v1_modifiers (d->keyboard, (depressed & ~target.level_mods) | target.mods,
                                           latched & ~target.level_mods, locked & ~target.level_mods,
                                           target.layout);
        zwp_virtual_keyboard_v1_key (d->keyboard, now_ms (), target.keycode - 8, WL_KEYBOARD_KEY_STATE_PRESSED);
        send_modifiers (d);
    } else {
        send_key (d, target.keycode, TRUE);
    }
    flush (d);
    return TRUE;
}

void
rd_display_keycode (RdDisplay *d, guint32 keycode, gboolean pressed)
{
    if (d->keyboard == NULL || d->keymap == NULL)
        return;
    xkb_keycode_t code = keycode + 8;
    gpointer key = GUINT_TO_POINTER (code);
    if (pressed == g_hash_table_contains (d->pressed_codes, key))
        return;
    if (pressed)
        g_hash_table_add (d->pressed_codes, key);
    else
        g_hash_table_remove (d->pressed_codes, key);
    send_key (d, code, pressed);
    flush (d);
}

void
rd_display_release_all (RdDisplay *d)
{
    if (d->keyboard != NULL && d->keymap != NULL) {
        GHashTableIter iter;
        gpointer k, v;
        g_hash_table_iter_init (&iter, d->pressed_syms);
        while (g_hash_table_iter_next (&iter, &k, &v)) {
            RdPressed *p = v;
            zwp_virtual_keyboard_v1_key (d->keyboard, now_ms (), p->keycode - 8, WL_KEYBOARD_KEY_STATE_RELEASED);
            xkb_state_update_key (d->state, p->keycode, XKB_KEY_UP);
        }
        g_hash_table_remove_all (d->pressed_syms);
        g_hash_table_iter_init (&iter, d->pressed_codes);
        while (g_hash_table_iter_next (&iter, &k, &v)) {
            zwp_virtual_keyboard_v1_key (d->keyboard, now_ms (), GPOINTER_TO_UINT (k) - 8,
                                         WL_KEYBOARD_KEY_STATE_RELEASED);
            xkb_state_update_key (d->state, GPOINTER_TO_UINT (k), XKB_KEY_UP);
        }
        g_hash_table_remove_all (d->pressed_codes);
        send_modifiers (d);
    }
    if (d->pointer != NULL) {
        GList *buttons = g_hash_table_get_keys (d->pressed_buttons);
        for (GList *l = buttons; l != NULL; l = l->next)
            zwlr_virtual_pointer_v1_button (d->pointer, now_ms (), GPOINTER_TO_UINT (l->data),
                                            WL_POINTER_BUTTON_STATE_RELEASED);
        if (buttons != NULL)
            zwlr_virtual_pointer_v1_frame (d->pointer);
        g_list_free (buttons);
        g_hash_table_remove_all (d->pressed_buttons);
    }
    flush (d);
}

static void
offer_free (RdOffer *offer)
{
    g_ptr_array_unref (offer->mime_types);
    g_free (offer);
}

static void
offer_offer (void *data, struct ext_data_control_offer_v1 *offer, const char *mime_type)
{
    RdOffer *o = data;
    g_ptr_array_add (o->mime_types, g_strdup (mime_type));
}

static const struct ext_data_control_offer_v1_listener offer_listener = {
    .offer = offer_offer,
};

static void
destroy_offer (struct ext_data_control_offer_v1 *offer)
{
    if (offer == NULL)
        return;
    RdOffer *o = ext_data_control_offer_v1_get_user_data (offer);
    if (o != NULL)
        offer_free (o);
    ext_data_control_offer_v1_destroy (offer);
}

static void
device_data_offer (void *data, struct ext_data_control_device_v1 *device, struct ext_data_control_offer_v1 *offer)
{
    RdOffer *o = g_new0 (RdOffer, 1);
    o->display = data;
    o->mime_types = g_ptr_array_new_with_free_func (g_free);
    ext_data_control_offer_v1_add_listener (offer, &offer_listener, o);
}

static gchar **
offer_mime_types (struct ext_data_control_offer_v1 *offer)
{
    GPtrArray *list = g_ptr_array_new ();
    if (offer != NULL) {
        RdOffer *o = ext_data_control_offer_v1_get_user_data (offer);
        for (guint i = 0; o != NULL && i < o->mime_types->len; i++)
            g_ptr_array_add (list, g_strdup (g_ptr_array_index (o->mime_types, i)));
    }
    g_ptr_array_add (list, NULL);
    return (gchar **) g_ptr_array_free (list, FALSE);
}

static void
device_selection (void *data, struct ext_data_control_device_v1 *device, struct ext_data_control_offer_v1 *offer)
{
    RdDisplay *d = data;

    destroy_offer (d->selection);
    d->selection = offer;
    if (d->clipboard_func != NULL) {
        gchar **types = offer_mime_types (offer);
        d->clipboard_func (d->clipboard_data, types, d->own_source != NULL);
        g_strfreev (types);
    }
}

static void
device_finished (void *data, struct ext_data_control_device_v1 *device)
{
    RdDisplay *d = data;
    ext_data_control_device_v1_destroy (device);
    if (d->data_device == device)
        d->data_device = NULL;
}

static void
device_primary_selection (void *data, struct ext_data_control_device_v1 *device,
                          struct ext_data_control_offer_v1 *offer)
{
    destroy_offer (offer);
}

static const struct ext_data_control_device_v1_listener device_listener = {
    .data_offer = device_data_offer,
    .selection = device_selection,
    .finished = device_finished,
    .primary_selection = device_primary_selection,
};

static void
setup_clipboard (RdDisplay *d)
{
    if (d->data_manager == NULL || d->seat == NULL)
        return;
    d->data_device = ext_data_control_manager_v1_get_data_device (d->data_manager, d->seat);
    ext_data_control_device_v1_add_listener (d->data_device, &device_listener, d);
}

void
rd_display_watch_clipboard (RdDisplay *d, RdClipboardFunc func, gpointer user_data)
{
    d->clipboard_func = func;
    d->clipboard_data = user_data;
}

gchar *
rd_display_text_mime_type (RdDisplay *d)
{
    static const gchar *preferred[] = { "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT" };
    if (d->selection == NULL)
        return NULL;
    RdOffer *o = ext_data_control_offer_v1_get_user_data (d->selection);
    for (guint p = 0; o != NULL && p < G_N_ELEMENTS (preferred); p++) {
        for (guint i = 0; i < o->mime_types->len; i++) {
            if (g_strcmp0 (g_ptr_array_index (o->mime_types, i), preferred[p]) == 0)
                return g_strdup (preferred[p]);
        }
    }
    return NULL;
}

gboolean
rd_display_receive_clipboard (RdDisplay *d, const gchar *mime_type, gint fd)
{
    if (d->selection == NULL) {
        close (fd);
        return FALSE;
    }
    ext_data_control_offer_v1_receive (d->selection, mime_type, fd);
    flush (d);
    close (fd);
    return TRUE;
}

static void
source_send (void *data, struct ext_data_control_source_v1 *source, const char *mime_type, int32_t fd)
{
    RdDisplay *d = data;

    if (source != d->own_source) {
        close (fd);
        return;
    }
    if (d->own_text != NULL) {
        gsize len = strlen (d->own_text);
        gsize done = 0;
        gint flags = fcntl (fd, F_GETFL);
        if (flags >= 0)
            fcntl (fd, F_SETFL, flags & ~O_NONBLOCK);
        while (done < len) {
            gssize n = write (fd, d->own_text + done, len - done);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                break;
            done += (gsize) n;
        }
        close (fd);
        return;
    }
    if (d->send_func != NULL)
        d->send_func (d->send_data, mime_type, fd);
    else
        close (fd);
}

static void
source_cancelled (void *data, struct ext_data_control_source_v1 *source)
{
    RdDisplay *d = data;
    if (d->own_source == source) {
        d->own_source = NULL;
        g_clear_pointer (&d->own_text, g_free);
        d->send_func = NULL;
        d->send_data = NULL;
    }
    ext_data_control_source_v1_destroy (source);
}

static const struct ext_data_control_source_v1_listener source_listener = {
    .send = source_send,
    .cancelled = source_cancelled,
};

static void
set_source (RdDisplay *d, const gchar *const *mime_types)
{
    if (d->data_device == NULL || d->data_manager == NULL)
        return;
    struct ext_data_control_source_v1 *old = d->own_source;
    d->own_source = ext_data_control_manager_v1_create_data_source (d->data_manager);
    ext_data_control_source_v1_add_listener (d->own_source, &source_listener, d);
    for (guint i = 0; mime_types[i] != NULL; i++)
        ext_data_control_source_v1_offer (d->own_source, mime_types[i]);
    ext_data_control_device_v1_set_selection (d->data_device, d->own_source);
    if (old != NULL)
        ext_data_control_source_v1_destroy (old);
    flush (d);
}

void
rd_display_offer_clipboard (RdDisplay *d, gchar **mime_types, RdSendFunc func, gpointer user_data)
{
    g_clear_pointer (&d->own_text, g_free);
    d->send_func = func;
    d->send_data = user_data;
    if (mime_types == NULL || mime_types[0] == NULL) {
        if (d->data_device != NULL)
            ext_data_control_device_v1_set_selection (d->data_device, NULL);
        flush (d);
        return;
    }
    set_source (d, (const gchar *const *) mime_types);
}

void
rd_display_set_clipboard_text (RdDisplay *d, const gchar *text)
{
    static const gchar *types[] = { "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT", NULL };
    d->send_func = NULL;
    d->send_data = NULL;
    set_source (d, types);
    g_free (d->own_text);
    d->own_text = g_strdup (text);
}

void
rd_display_free (RdDisplay *d)
{
    if (d == NULL)
        return;
    if (d->watch_id != 0)
        g_source_remove (d->watch_id);
    for (GList *l = d->screens; l != NULL; l = l->next) {
        RdScreen *s = l->data;
        for (guint i = 0; i < s->captures->len; i++)
            capture_free (g_ptr_array_index (s->captures, i));
        g_ptr_array_set_size (s->captures, 0);
        s->display = NULL;
        s->stopped = TRUE;
    }
    g_list_free (d->screens);
    d->screens = NULL;
    if (!d->broken) {
        rd_display_release_all (d);
        destroy_offer (d->selection);
        if (d->own_source != NULL)
            ext_data_control_source_v1_destroy (d->own_source);
        if (d->data_device != NULL)
            ext_data_control_device_v1_destroy (d->data_device);
        if (d->pointer != NULL)
            zwlr_virtual_pointer_v1_destroy (d->pointer);
        if (d->keyboard != NULL)
            zwp_virtual_keyboard_v1_destroy (d->keyboard);
        if (d->wl_keyboard != NULL)
            wl_keyboard_release (d->wl_keyboard);
        wl_display_roundtrip (d->wl);
    }
    for (guint i = 0; i < d->outputs->len; i++)
        output_free (g_ptr_array_index (d->outputs, i));
    g_ptr_array_unref (d->outputs);
    if (d->state != NULL)
        xkb_state_unref (d->state);
    if (d->keymap != NULL)
        xkb_keymap_unref (d->keymap);
    if (d->base_keymap != NULL)
        xkb_keymap_unref (d->base_keymap);
    if (d->xkb != NULL)
        xkb_context_unref (d->xkb);
    g_free (d->base_text);
    g_free (d->sent_text);
    g_free (d->own_text);
    g_hash_table_unref (d->pressed_syms);
    g_hash_table_unref (d->pressed_codes);
    g_hash_table_unref (d->pressed_buttons);
    wl_display_disconnect (d->wl);
    g_free (d);
}
