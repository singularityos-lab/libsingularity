#pragma once

#include <glib.h>
#include <xkbcommon/xkbcommon.h>

G_BEGIN_DECLS

typedef struct {
    xkb_keycode_t keycode;
    xkb_layout_index_t layout;
    xkb_level_index_t level;
    xkb_mod_mask_t mods;
    xkb_mod_mask_t level_mods;
} RdKeyTarget;

gboolean rd_keysym_is_text (xkb_keysym_t keysym);
gboolean rd_keymap_find (struct xkb_keymap *keymap, xkb_keysym_t keysym, xkb_layout_index_t prefer,
                         RdKeyTarget *target);
gchar *rd_keymap_add_keysyms (const gchar *text, struct xkb_keymap *keymap, const xkb_keysym_t *keysyms,
                              gint n_keysyms);
gchar *rd_keymap_normalize (struct xkb_context *context, const gchar *text);
gchar *rd_keymap_type_text (const gchar *keymap_text, const gchar *text);

G_END_DECLS
