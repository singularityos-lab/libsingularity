#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include <glib.h>
#include <xkbcommon/xkbcommon.h>

#include "rd_encode.h"
#include "rd_keymap.h"

#define W 300
#define H 260

typedef struct {
    guint8 *fb;
    z_stream zs;
    gsize copies;
    gsize zrle;
    gsize raw;
} Client;

static gchar *
keymap_text (const gchar *layout)
{
    struct xkb_context *ctx = xkb_context_new (XKB_CONTEXT_NO_ENVIRONMENT_NAMES);
    struct xkb_rule_names names = { .rules = "evdev", .model = "pc105", .layout = layout };
    struct xkb_keymap *km = xkb_keymap_new_from_names (ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    g_assert_nonnull (km);
    gchar *raw = xkb_keymap_get_as_string (km, XKB_KEYMAP_FORMAT_TEXT_V1);
    gchar *text = g_strdup (raw);
    free (raw);
    xkb_keymap_unref (km);
    xkb_context_unref (ctx);
    return text;
}

static void
test_italian_typing (void)
{
    gchar *it = keymap_text ("it");
    const gchar *sample = "Perché è così? Città, però: più già. @#€ [x] {y} <z> ~ | Ciao!";
    gchar *typed = rd_keymap_type_text (it, sample);
    g_assert_cmpstr (typed, ==, sample);
    g_free (typed);

    struct xkb_context *ctx = xkb_context_new (XKB_CONTEXT_NO_ENVIRONMENT_NAMES);
    struct xkb_keymap *km = xkb_keymap_new_from_string (ctx, it, XKB_KEYMAP_FORMAT_TEXT_V1, 0);
    RdKeyTarget t;
    g_assert_true (rd_keymap_find (km, XKB_KEY_egrave, 0, &t));
    g_assert_cmpuint (t.mods, ==, 0);
    g_assert_true (rd_keymap_find (km, XKB_KEY_eacute, 0, &t));
    g_assert_cmpuint (t.mods, ==, 1u << xkb_keymap_mod_get_index (km, XKB_MOD_NAME_SHIFT));
    g_assert_true (rd_keymap_find (km, XKB_KEY_at, 0, &t));
    g_assert_cmpuint (t.mods & (1u << xkb_keymap_mod_get_index (km, XKB_MOD_NAME_SHIFT)), ==, 0);
    g_assert_cmpuint (t.mods, !=, 0);
    xkb_keymap_unref (km);
    xkb_context_unref (ctx);
    g_free (it);
}

static void
test_missing_keysyms (void)
{
    gchar *us = keymap_text ("us");
    gchar *typed = rd_keymap_type_text (us, "aè");
    g_assert_cmpstr (typed, ==, "a?");
    g_free (typed);

    struct xkb_context *ctx = xkb_context_new (XKB_CONTEXT_NO_ENVIRONMENT_NAMES);
    struct xkb_keymap *km = xkb_keymap_new_from_string (ctx, us, XKB_KEYMAP_FORMAT_TEXT_V1, 0);
    xkb_keysym_t extra[] = { XKB_KEY_egrave, XKB_KEY_ntilde, xkb_utf32_to_keysym (0x20ac) };
    gchar *bigger = rd_keymap_add_keysyms (us, km, extra, 3);
    g_assert_nonnull (bigger);
    typed = rd_keymap_type_text (bigger, "èñ€ ok");
    g_assert_cmpstr (typed, ==, "èñ€ ok");
    g_free (typed);
    g_free (bigger);
    xkb_keymap_unref (km);
    xkb_context_unref (ctx);
    g_free (us);
}

static void
test_text_keysyms (void)
{
    g_assert_true (rd_keysym_is_text (XKB_KEY_a));
    g_assert_true (rd_keysym_is_text (XKB_KEY_egrave));
    g_assert_false (rd_keysym_is_text (XKB_KEY_Tab));
    g_assert_false (rd_keysym_is_text (XKB_KEY_Shift_L));
    g_assert_false (rd_keysym_is_text (XKB_KEY_Return));
}

static guint32
get32 (const guint8 *p)
{
    return (guint32) p[0] << 24 | (guint32) p[1] << 16 | (guint32) p[2] << 8 | p[3];
}

static guint16
get16 (const guint8 *p)
{
    return (guint16) (p[0] << 8 | p[1]);
}

static void
put_px (Client *c, gint x, gint y, const guint8 *cp)
{
    guint8 *o = c->fb + ((gsize) y * W + x) * 4;
    o[0] = cp[0];
    o[1] = cp[1];
    o[2] = cp[2];
    o[3] = 0;
}

static gsize
decode_zrle_tiles (Client *c, const guint8 *z, gsize n, gint x, gint y, gint w, gint h)
{
    gsize p = 0;
    for (gint ty = y; ty < y + h; ty += 64) {
        gint th = MIN (64, y + h - ty);
        for (gint tx = x; tx < x + w; tx += 64) {
            gint tw = MIN (64, x + w - tx);
            guint8 sub = z[p++];
            gint palsize = sub & 127;
            const guint8 *pal = z + p;
            p += (gsize) palsize * 3;
            if (sub == 0) {
                for (gint i = 0; i < tw * th; i++, p += 3)
                    put_px (c, tx + i % tw, ty + i / tw, z + p);
            } else if (sub == 1) {
                for (gint i = 0; i < tw * th; i++)
                    put_px (c, tx + i % tw, ty + i / tw, pal);
            } else if (sub < 128) {
                gint bits = palsize == 2 ? 1 : (palsize <= 4 ? 2 : 4);
                gint row_bytes = (tw * bits + 7) / 8;
                for (gint row = 0; row < th; row++) {
                    for (gint col = 0; col < tw; col++) {
                        gint bit = col * bits;
                        gint idx = (z[p + row * row_bytes + bit / 8] >> (8 - bits - bit % 8)) & ((1 << bits) - 1);
                        put_px (c, tx + col, ty + row, pal + idx * 3);
                    }
                }
                p += (gsize) row_bytes * th;
            } else {
                gint done = 0;
                while (done < tw * th) {
                    const guint8 *color;
                    gint run = 1;
                    if (palsize == 0) {
                        color = z + p;
                        p += 3;
                        run = 1;
                        guint8 b;
                        do {
                            b = z[p++];
                            run += b;
                        } while (b == 255);
                    } else {
                        guint8 idx = z[p++];
                        color = pal + (idx & 127) * 3;
                        if (idx & 128) {
                            guint8 b;
                            do {
                                b = z[p++];
                                run += b;
                            } while (b == 255);
                        }
                    }
                    for (gint k = 0; k < run; k++, done++)
                        put_px (c, tx + done % tw, ty + done / tw, color);
                }
            }
        }
    }
    g_assert_cmpuint (p, ==, n);
    return p;
}

static void
apply (Client *c, GBytes *bytes)
{
    gsize len;
    const guint8 *m = g_bytes_get_data (bytes, &len);
    g_assert_cmpuint (m[0], ==, 0);
    gint count = get16 (m + 2);
    gsize p = 4;
    for (gint i = 0; i < count; i++) {
        gint x = get16 (m + p), y = get16 (m + p + 2), w = get16 (m + p + 4), h = get16 (m + p + 6);
        gint32 enc = (gint32) get32 (m + p + 8);
        p += 12;
        if (enc == RD_ENCODING_RAW) {
            for (gint row = 0; row < h; row++)
                memcpy (c->fb + ((gsize) (y + row) * W + x) * 4, m + p + (gsize) row * w * 4, (gsize) w * 4);
            p += (gsize) w * h * 4;
            c->raw++;
        } else if (enc == RD_ENCODING_COPYRECT) {
            gint sx = get16 (m + p), sy = get16 (m + p + 2);
            p += 4;
            guint8 *tmp = g_malloc ((gsize) w * h * 4);
            for (gint row = 0; row < h; row++)
                memcpy (tmp + (gsize) row * w * 4, c->fb + ((gsize) (sy + row) * W + sx) * 4, (gsize) w * 4);
            for (gint row = 0; row < h; row++)
                memcpy (c->fb + ((gsize) (y + row) * W + x) * 4, tmp + (gsize) row * w * 4, (gsize) w * 4);
            g_free (tmp);
            c->copies++;
        } else if (enc == RD_ENCODING_ZRLE) {
            guint32 n = get32 (m + p);
            p += 4;
            guint8 *out = g_malloc (1 << 22);
            c->zs.next_in = (Bytef *) (m + p);
            c->zs.avail_in = n;
            c->zs.next_out = out;
            c->zs.avail_out = 1 << 22;
            g_assert_cmpint (inflate (&c->zs, Z_SYNC_FLUSH), >=, 0);
            g_assert_cmpuint (c->zs.avail_in, ==, 0);
            decode_zrle_tiles (c, out, (1 << 22) - c->zs.avail_out, x, y, w, h);
            g_free (out);
            p += n;
            c->zrle++;
        } else {
            g_assert_not_reached ();
        }
    }
    g_assert_cmpuint (p, ==, len);
}

static void
paint (guint8 *fb, gint seed)
{
    for (gint y = 0; y < H; y++) {
        for (gint x = 0; x < W; x++) {
            guint8 *p = fb + ((gsize) y * W + x) * 4;
            if (y < 40) {
                p[0] = 200; p[1] = 180; p[2] = 160;
            } else if (x < 120) {
                gboolean ink = ((x / 3 + (y + seed) / 5) % 7) == 0;
                p[0] = ink ? 20 : 250; p[1] = ink ? 20 : 250; p[2] = ink ? 30 : 250;
            } else if (x < 200) {
                p[0] = (guint8) (x * 3 + y); p[1] = (guint8) (y * 5 + seed); p[2] = (guint8) (x ^ y);
            } else {
                guint8 v = (guint8) (((x / 10) + ((y + seed) / 10)) % 5 * 50);
                p[0] = v; p[1] = 255 - v; p[2] = v / 2;
            }
            p[3] = 0xff;
        }
    }
}

static gboolean
same (Client *c, const guint8 *fb)
{
    for (gsize i = 0; i < (gsize) W * H; i++) {
        if (memcmp (c->fb + i * 4, fb + i * 4, 3) != 0)
            return FALSE;
    }
    return TRUE;
}

static void
test_zrle_roundtrip (void)
{
    RdEncoder *e = rd_encoder_new ();
    rd_encoder_set_encodings (e, RD_ENCODING_ZRLE, TRUE);
    Client c = { 0 };
    c.fb = g_malloc0 ((gsize) W * H * 4);
    g_assert_cmpint (inflateInit (&c.zs), ==, Z_OK);
    guint8 *fb = g_malloc ((gsize) W * H * 4);
    paint (fb, 0);

    gint all[4] = { 0, 0, W, H };
    GBytes *msg = rd_encoder_encode (e, fb, W, H, W * 4, all, 4);
    g_assert_nonnull (msg);
    g_assert_cmpuint (g_bytes_get_size (msg), <, (gsize) W * H * 4 / 2);
    apply (&c, msg);
    g_bytes_unref (msg);
    g_assert_true (same (&c, fb));

    g_assert_null (rd_encoder_encode (e, fb, W, H, W * 4, all, 4));

    memmove (fb + (gsize) 60 * W * 4, fb + (gsize) 100 * W * 4, (gsize) (H - 100) * W * 4);
    for (gint y = H - 40; y < H; y++)
        for (gint x = 0; x < W; x++)
            memset (fb + ((gsize) y * W + x) * 4, (x + y) & 0xff, 3);
    gint area[4] = { 0, 0, W, H };
    msg = rd_encoder_encode (e, fb, W, H, W * 4, area, 4);
    g_assert_nonnull (msg);
    apply (&c, msg);
    gsize scroll_size = g_bytes_get_size (msg);
    g_bytes_unref (msg);
    g_assert_true (same (&c, fb));
    g_assert_cmpuint (c.copies, >, 0);
    g_assert_cmpuint (rd_encoder_get_copy_count (e), ==, c.copies);
    g_assert_cmpuint (scroll_size, <, (gsize) W * H * 4 / 4);

    gint part[4] = { 128, 64, 64, 64 };
    memset (fb + ((gsize) 70 * W + 130) * 4, 0x42, 40);
    msg = rd_encoder_encode (e, fb, W, H, W * 4, part, 4);
    g_assert_nonnull (msg);
    apply (&c, msg);
    g_bytes_unref (msg);
    g_assert_true (same (&c, fb));

    inflateEnd (&c.zs);
    g_free (c.fb);
    g_free (fb);
    rd_encoder_free (e);
}

static void
test_raw_formats (void)
{
    RdEncoder *e = rd_encoder_new ();
    rd_encoder_set_format (e, 16, 16, FALSE, 31, 63, 31, 11, 5, 0);
    guint8 *fb = g_malloc0 ((gsize) W * H * 4);
    paint (fb, 3);
    gint all[4] = { 0, 0, W, H };
    GBytes *msg = rd_encoder_encode (e, fb, W, H, W * 4, all, 4);
    g_assert_cmpuint (g_bytes_get_size (msg), ==, 4 + 12 + (gsize) W * H * 2);
    g_bytes_unref (msg);

    fb[0] ^= 0xff;
    gint small[4] = { 0, 0, 10, 10 };
    msg = rd_encoder_encode (e, fb, W, H, W * 4, small, 4);
    g_assert_cmpuint (g_bytes_get_size (msg), ==, 4 + 12 + 10 * 10 * 2);
    g_bytes_unref (msg);

    guint8 src[8] = { 0x10, 0x20, 0xff, 0x00 };
    guint8 dst[4];
    rd_convert_pixels (src, 8, 0, 0, 1, 1, dst, 32, TRUE, 255, 255, 255, 0, 8, 16);
    g_assert_cmpuint (dst[3], ==, 0xff);
    g_assert_cmpuint (dst[1], ==, 0x10);
    g_free (fb);
    rd_encoder_free (e);
}

int
main (int argc, char **argv)
{
    g_test_init (&argc, &argv, NULL);
    g_test_add_func ("/sharing-host/keymap/italian", test_italian_typing);
    g_test_add_func ("/sharing-host/keymap/missing", test_missing_keysyms);
    g_test_add_func ("/sharing-host/keymap/text", test_text_keysyms);
    g_test_add_func ("/sharing-host/encode/zrle", test_zrle_roundtrip);
    g_test_add_func ("/sharing-host/encode/raw", test_raw_formats);
    return g_test_run ();
}
