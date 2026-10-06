#include "rd_keymap.h"

#include <stdlib.h>
#include <string.h>

#define RD_MAX_LEVELS 8
#define RD_MAX_MASKS 16

gboolean
rd_keysym_is_text (xkb_keysym_t keysym)
{
    guint32 c = xkb_keysym_to_utf32 (keysym);
    return c >= 0x20 && c != 0x7f;
}

static xkb_mod_mask_t
lock_mods (struct xkb_keymap *keymap)
{
    xkb_mod_mask_t mask = 0;
    const gchar *names[] = { XKB_MOD_NAME_CAPS, XKB_MOD_NAME_NUM };
    for (guint i = 0; i < G_N_ELEMENTS (names); i++) {
        xkb_mod_index_t index = xkb_keymap_mod_get_index (keymap, names[i]);
        if (index != XKB_MOD_INVALID)
            mask |= 1u << index;
    }
    return mask;
}

static gboolean
best_mask (struct xkb_keymap *keymap, xkb_keycode_t keycode, xkb_layout_index_t layout, xkb_level_index_t level,
           xkb_mod_mask_t locks, xkb_mod_mask_t *mask)
{
    xkb_mod_mask_t masks[RD_MAX_MASKS];
    gsize n = xkb_keymap_key_get_mods_for_level (keymap, keycode, layout, level, masks, RD_MAX_MASKS);
    gint best = -1;
    guint best_score = G_MAXUINT;

    for (gsize i = 0; i < n; i++) {
        guint score = (guint) __builtin_popcount (masks[i] & ~locks) + ((masks[i] & locks) != 0 ? 16 : 0);
        if (score < best_score) {
            best_score = score;
            best = (gint) i;
        }
    }
    if (best < 0)
        return FALSE;
    *mask = masks[best];
    return TRUE;
}

static xkb_mod_mask_t
level_mods (struct xkb_keymap *keymap, xkb_keycode_t keycode, xkb_layout_index_t layout)
{
    xkb_mod_mask_t all = 0;
    xkb_level_index_t levels = xkb_keymap_num_levels_for_key (keymap, keycode, layout);
    for (xkb_level_index_t l = 0; l < levels; l++) {
        xkb_mod_mask_t masks[RD_MAX_MASKS];
        gsize n = xkb_keymap_key_get_mods_for_level (keymap, keycode, layout, l, masks, RD_MAX_MASKS);
        for (gsize i = 0; i < n; i++)
            all |= masks[i];
    }
    return all;
}

static gboolean
find_in_layout (struct xkb_keymap *keymap, xkb_keysym_t keysym, xkb_layout_index_t layout, xkb_mod_mask_t locks,
                RdKeyTarget *target)
{
    xkb_keycode_t min = xkb_keymap_min_keycode (keymap);
    xkb_keycode_t max = xkb_keymap_max_keycode (keymap);

    for (xkb_level_index_t level = 0; level < RD_MAX_LEVELS; level++) {
        for (xkb_keycode_t kc = min; kc <= max; kc++) {
            if (layout >= xkb_keymap_num_layouts_for_key (keymap, kc))
                continue;
            if (level >= xkb_keymap_num_levels_for_key (keymap, kc, layout))
                continue;
            const xkb_keysym_t *syms = NULL;
            gint n = xkb_keymap_key_get_syms_by_level (keymap, kc, layout, level, &syms);
            if (n != 1 || syms[0] != keysym)
                continue;
            xkb_mod_mask_t mask;
            if (!best_mask (keymap, kc, layout, level, locks, &mask))
                continue;
            target->keycode = kc;
            target->layout = layout;
            target->level = level;
            target->mods = mask;
            target->level_mods = level_mods (keymap, kc, layout);
            return TRUE;
        }
    }
    return FALSE;
}

gboolean
rd_keymap_find (struct xkb_keymap *keymap, xkb_keysym_t keysym, xkb_layout_index_t prefer, RdKeyTarget *target)
{
    if (keymap == NULL || keysym == XKB_KEY_NoSymbol)
        return FALSE;
    xkb_layout_index_t layouts = xkb_keymap_num_layouts (keymap);
    xkb_mod_mask_t locks = lock_mods (keymap);

    if (prefer < layouts && find_in_layout (keymap, keysym, prefer, locks, target))
        return TRUE;
    for (xkb_layout_index_t layout = 0; layout < layouts; layout++) {
        if (layout != prefer && find_in_layout (keymap, keysym, layout, locks, target))
            return TRUE;
    }
    return FALSE;
}

static gssize
symbols_end (const gchar *text)
{
    const gchar *start = strstr (text, "xkb_symbols");
    if (start == NULL)
        return -1;
    const gchar *open = strchr (start, '{');
    if (open == NULL)
        return -1;
    gint depth = 0;
    gboolean quoted = FALSE;
    for (const gchar *p = open; *p != '\0'; p++) {
        if (*p == '"' && (p == open || p[-1] != '\\'))
            quoted = !quoted;
        if (quoted)
            continue;
        if (*p == '{') {
            depth++;
        } else if (*p == '}') {
            depth--;
            if (depth == 0)
                return p - text;
        }
    }
    return -1;
}

gchar *
rd_keymap_add_keysyms (const gchar *text, struct xkb_keymap *keymap, const xkb_keysym_t *keysyms, gint n_keysyms)
{
    gssize end = symbols_end (text);
    if (end < 0 || n_keysyms <= 0)
        return NULL;

    GString *extra = g_string_new (NULL);
    gint added = 0;
    xkb_keycode_t min = xkb_keymap_min_keycode (keymap);
    xkb_keycode_t kc = xkb_keymap_max_keycode (keymap);
    for (; kc >= min && added < n_keysyms; kc--) {
        const gchar *name = xkb_keymap_key_get_name (keymap, kc);
        if (name == NULL || xkb_keymap_num_layouts_for_key (keymap, kc) != 0)
            continue;
        gchar sym[64];
        if (xkb_keysym_get_name (keysyms[added], sym, sizeof (sym)) <= 0)
            break;
        g_string_append_printf (extra, "    key <%s> { [ %s ] };\n", name, sym);
        added++;
    }
    if (added < n_keysyms) {
        g_string_free (extra, TRUE);
        return NULL;
    }

    GString *out = g_string_new_len (text, end);
    g_string_append (out, extra->str);
    g_string_append (out, text + end);
    g_string_free (extra, TRUE);
    return g_string_free (out, FALSE);
}

gchar *
rd_keymap_normalize (struct xkb_context *context, const gchar *text)
{
    struct xkb_keymap *keymap = xkb_keymap_new_from_string (context, text, XKB_KEYMAP_FORMAT_TEXT_V1,
                                                            XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (keymap == NULL)
        return NULL;
    gchar *raw = xkb_keymap_get_as_string (keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    gchar *copy = g_strdup (raw);
    free (raw);
    xkb_keymap_unref (keymap);
    return copy;
}

gchar *
rd_keymap_type_text (const gchar *keymap_text, const gchar *text)
{
    struct xkb_context *context = xkb_context_new (XKB_CONTEXT_NO_ENVIRONMENT_NAMES);
    struct xkb_keymap *keymap = xkb_keymap_new_from_string (context, keymap_text, XKB_KEYMAP_FORMAT_TEXT_V1,
                                                            XKB_KEYMAP_COMPILE_NO_FLAGS);
    GString *out = g_string_new (NULL);
    if (keymap == NULL) {
        xkb_context_unref (context);
        return g_string_free (out, FALSE);
    }
    struct xkb_state *state = xkb_state_new (keymap);
    for (const gchar *p = text; *p != '\0'; p = g_utf8_next_char (p)) {
        xkb_keysym_t sym = xkb_utf32_to_keysym (g_utf8_get_char (p));
        RdKeyTarget target;
        if (!rd_keymap_find (keymap, sym, 0, &target)) {
            g_string_append_c (out, '?');
            continue;
        }
        xkb_state_update_mask (state, target.mods, 0, 0, 0, 0, target.layout);
        gchar buf[16];
        xkb_state_key_get_utf8 (state, target.keycode, buf, sizeof (buf));
        g_string_append (out, buf);
    }
    xkb_state_unref (state);
    xkb_keymap_unref (keymap);
    xkb_context_unref (context);
    return g_string_free (out, FALSE);
}
