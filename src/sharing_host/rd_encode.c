#include "rd_encode.h"

#include <string.h>
#include <zlib.h>

#define RD_TILE 64
#define RD_SCROLL_MIN_ROWS 32
#define RD_SCROLL_MIN_VOTES 8
#define RD_PALETTE_SLOTS 256

typedef struct {
    gint c0;
    gint c1;
    gint r0;
    gint r1;
} RdSpan;

struct _RdEncoder {
    gint bits_per_pixel;
    gint depth;
    gboolean big_endian;
    guint16 red_max;
    guint16 green_max;
    guint16 blue_max;
    guint8 red_shift;
    guint8 green_shift;
    guint8 blue_shift;
    gint cpixel;
    gint cpixel_shift;
    gint preferred;
    gboolean copy_rect;
    z_stream zs;
    gboolean zs_ready;
    guint8 *shadow;
    gint shadow_width;
    gint shadow_height;
    gboolean shadow_valid;
    GByteArray *stream;
    guint32 pixels[RD_TILE * RD_TILE];
    guint8 index[RD_TILE * RD_TILE];
    guint copies;
};

static inline guint32
scale_channel (guint32 value, guint16 max)
{
    return max == 255 ? value : (value * max + 127) / 255;
}

void
rd_convert_pixels (const guint8 *src, gint src_stride, gint x, gint y, gint width, gint height, guint8 *dst,
                   gint bits_per_pixel, gboolean big_endian, guint16 red_max, guint16 green_max, guint16 blue_max,
                   guint8 red_shift, guint8 green_shift, guint8 blue_shift)
{
    gint bytes = bits_per_pixel / 8;
    gboolean native = bits_per_pixel == 32 && !big_endian && red_max == 255 && green_max == 255 && blue_max == 255 &&
                      red_shift == 16 && green_shift == 8 && blue_shift == 0;

    for (gint row = 0; row < height; row++) {
        const guint8 *line = src + (gsize) (y + row) * src_stride + (gsize) x * 4;
        guint8 *out = dst + (gsize) row * width * bytes;
        if (native) {
            memcpy (out, line, (gsize) width * 4);
            continue;
        }
        for (gint col = 0; col < width; col++) {
            const guint8 *p = line + col * 4;
            guint32 value = (scale_channel (p[2], red_max) << red_shift) |
                            (scale_channel (p[1], green_max) << green_shift) |
                            (scale_channel (p[0], blue_max) << blue_shift);
            for (gint b = 0; b < bytes; b++) {
                gint shift = big_endian ? (bytes - 1 - b) * 8 : b * 8;
                out[col * bytes + b] = (guint8) (value >> shift);
            }
        }
    }
}

static void
update_cpixel (RdEncoder *e)
{
    guint32 mask = ((guint32) e->red_max << e->red_shift) | ((guint32) e->green_max << e->green_shift) |
                   ((guint32) e->blue_max << e->blue_shift);
    e->cpixel = e->bits_per_pixel / 8;
    e->cpixel_shift = 0;
    if (e->bits_per_pixel == 32 && e->depth <= 24) {
        if ((mask & 0xff000000u) == 0) {
            e->cpixel = 3;
        } else if ((mask & 0xffu) == 0) {
            e->cpixel = 3;
            e->cpixel_shift = 8;
        }
    }
}

RdEncoder *
rd_encoder_new (void)
{
    RdEncoder *e = g_new0 (RdEncoder, 1);
    e->stream = g_byte_array_new ();
    e->preferred = RD_ENCODING_RAW;
    rd_encoder_set_format (e, 32, 24, FALSE, 255, 255, 255, 16, 8, 0);
    return e;
}

void
rd_encoder_free (RdEncoder *e)
{
    if (e == NULL)
        return;
    if (e->zs_ready)
        deflateEnd (&e->zs);
    g_byte_array_unref (e->stream);
    g_free (e->shadow);
    g_free (e);
}

void
rd_encoder_set_format (RdEncoder *e, gint bits_per_pixel, gint depth, gboolean big_endian, guint16 red_max,
                       guint16 green_max, guint16 blue_max, guint8 red_shift, guint8 green_shift, guint8 blue_shift)
{
    e->bits_per_pixel = bits_per_pixel;
    e->depth = depth;
    e->big_endian = big_endian;
    e->red_max = red_max;
    e->green_max = green_max;
    e->blue_max = blue_max;
    e->red_shift = red_shift;
    e->green_shift = green_shift;
    e->blue_shift = blue_shift;
    update_cpixel (e);
    e->shadow_valid = FALSE;
}

void
rd_encoder_set_encodings (RdEncoder *e, gint preferred, gboolean copy_rect)
{
    e->preferred = preferred == RD_ENCODING_ZRLE ? RD_ENCODING_ZRLE : RD_ENCODING_RAW;
    e->copy_rect = copy_rect;
}

void
rd_encoder_invalidate (RdEncoder *e)
{
    e->shadow_valid = FALSE;
}

guint
rd_encoder_get_copy_count (RdEncoder *e)
{
    return e->copies;
}

static void
put16 (GByteArray *b, guint16 v)
{
    guint8 d[2] = { (guint8) (v >> 8), (guint8) v };
    g_byte_array_append (b, d, 2);
}

static void
put32 (GByteArray *b, guint32 v)
{
    guint8 d[4] = { (guint8) (v >> 24), (guint8) (v >> 16), (guint8) (v >> 8), (guint8) v };
    g_byte_array_append (b, d, 4);
}

static void
rect_header (GByteArray *b, gint x, gint y, gint w, gint h, gint32 encoding)
{
    put16 (b, (guint16) x);
    put16 (b, (guint16) y);
    put16 (b, (guint16) w);
    put16 (b, (guint16) h);
    put32 (b, (guint32) encoding);
}

static inline guint32
pixel_value (RdEncoder *e, const guint8 *p)
{
    return (scale_channel (p[2], e->red_max) << e->red_shift) | (scale_channel (p[1], e->green_max) << e->green_shift) |
           (scale_channel (p[0], e->blue_max) << e->blue_shift);
}

static inline void
put_cpixel (RdEncoder *e, GByteArray *b, guint32 v)
{
    guint8 d[4];
    gint n = e->cpixel;
    if (n == 3) {
        v >>= e->cpixel_shift;
        if (e->big_endian) {
            d[0] = (guint8) (v >> 16);
            d[1] = (guint8) (v >> 8);
            d[2] = (guint8) v;
        } else {
            d[0] = (guint8) v;
            d[1] = (guint8) (v >> 8);
            d[2] = (guint8) (v >> 16);
        }
    } else {
        for (gint i = 0; i < n; i++)
            d[i] = (guint8) (v >> (e->big_endian ? (n - 1 - i) * 8 : i * 8));
    }
    g_byte_array_append (b, d, (guint) n);
}

static inline gsize
run_bytes (gint run)
{
    return (gsize) ((run - 1) / 255 + 1);
}

static inline void
put_run (GByteArray *b, gint run)
{
    gint r = run - 1;
    guint8 full = 255;
    while (r >= 255) {
        g_byte_array_append (b, &full, 1);
        r -= 255;
    }
    guint8 last = (guint8) r;
    g_byte_array_append (b, &last, 1);
}

static void
zrle_tile (RdEncoder *e, const guint8 *fb, gint stride, gint x, gint y, gint w, gint h)
{
    GByteArray *b = e->stream;
    gint n = w * h;
    guint32 keys[RD_PALETTE_SLOTS];
    gint16 slots[RD_PALETTE_SLOTS];
    guint32 palette[128];
    gint colors = 0;
    gboolean many = FALSE;
    gint cp = e->cpixel;

    memset (slots, 0xff, sizeof (slots));
    for (gint row = 0; row < h; row++) {
        const guint8 *line = fb + (gsize) (y + row) * stride + (gsize) x * 4;
        for (gint col = 0; col < w; col++) {
            guint32 v = pixel_value (e, line + col * 4);
            gint i = row * w + col;
            e->pixels[i] = v;
            if (many)
                continue;
            guint slot = (v * 2654435761u) >> 24;
            while (slots[slot] >= 0 && keys[slot] != v)
                slot = (slot + 1) & (RD_PALETTE_SLOTS - 1);
            if (slots[slot] < 0) {
                if (colors == 127) {
                    many = TRUE;
                    continue;
                }
                keys[slot] = v;
                slots[slot] = (gint16) colors;
                palette[colors++] = v;
            }
            e->index[i] = (guint8) slots[slot];
        }
    }

    if (!many && colors == 1) {
        guint8 sub = 1;
        g_byte_array_append (b, &sub, 1);
        put_cpixel (e, b, palette[0]);
        return;
    }

    gsize plain = 0;
    gsize pal_rle = 0;
    for (gint i = 0; i < n;) {
        gint j = i + 1;
        while (j < n && e->pixels[j] == e->pixels[i])
            j++;
        gint run = j - i;
        plain += (gsize) cp + run_bytes (run);
        pal_rle += run == 1 ? 1 : 1 + run_bytes (run);
        i = j;
    }

    gsize raw = (gsize) n * cp;
    gsize best = raw;
    gint mode = 0;
    if (plain < best) {
        best = plain;
        mode = 128;
    }
    if (!many) {
        gsize palette_rle = (gsize) colors * cp + pal_rle;
        if (palette_rle < best) {
            best = palette_rle;
            mode = 128 + colors;
        }
        if (colors <= 16) {
            gint bits = colors == 2 ? 1 : (colors <= 4 ? 2 : 4);
            gsize packed = (gsize) colors * cp + (gsize) h * ((w * bits + 7) / 8);
            if (packed < best) {
                best = packed;
                mode = colors;
            }
        }
    }

    guint8 sub = (guint8) mode;
    g_byte_array_append (b, &sub, 1);
    if (mode == 0) {
        for (gint i = 0; i < n; i++)
            put_cpixel (e, b, e->pixels[i]);
    } else if (mode == 128) {
        for (gint i = 0; i < n;) {
            gint j = i + 1;
            while (j < n && e->pixels[j] == e->pixels[i])
                j++;
            put_cpixel (e, b, e->pixels[i]);
            put_run (b, j - i);
            i = j;
        }
    } else if (mode > 128) {
        for (gint c = 0; c < colors; c++)
            put_cpixel (e, b, palette[c]);
        for (gint i = 0; i < n;) {
            gint j = i + 1;
            while (j < n && e->pixels[j] == e->pixels[i])
                j++;
            guint8 idx = e->index[i];
            if (j - i == 1) {
                g_byte_array_append (b, &idx, 1);
            } else {
                idx |= 128;
                g_byte_array_append (b, &idx, 1);
                put_run (b, j - i);
            }
            i = j;
        }
    } else {
        for (gint c = 0; c < colors; c++)
            put_cpixel (e, b, palette[c]);
        gint bits = colors == 2 ? 1 : (colors <= 4 ? 2 : 4);
        for (gint row = 0; row < h; row++) {
            guint8 acc = 0;
            gint used = 0;
            for (gint col = 0; col < w; col++) {
                acc |= (guint8) (e->index[row * w + col] << (8 - bits - used));
                used += bits;
                if (used == 8) {
                    g_byte_array_append (b, &acc, 1);
                    acc = 0;
                    used = 0;
                }
            }
            if (used > 0)
                g_byte_array_append (b, &acc, 1);
        }
    }
}

static gboolean
ensure_zlib (RdEncoder *e)
{
    if (e->zs_ready)
        return TRUE;
    memset (&e->zs, 0, sizeof (e->zs));
    if (deflateInit (&e->zs, 6) != Z_OK)
        return FALSE;
    e->zs_ready = TRUE;
    return TRUE;
}

static gboolean
encode_zrle (RdEncoder *e, GByteArray *msg, const guint8 *fb, gint stride, gint x, gint y, gint w, gint h)
{
    if (!ensure_zlib (e))
        return FALSE;
    g_byte_array_set_size (e->stream, 0);
    for (gint ty = y; ty < y + h; ty += RD_TILE) {
        gint th = MIN (RD_TILE, y + h - ty);
        for (gint tx = x; tx < x + w; tx += RD_TILE)
            zrle_tile (e, fb, stride, tx, ty, MIN (RD_TILE, x + w - tx), th);
    }

    guint mark = msg->len;
    rect_header (msg, x, y, w, h, RD_ENCODING_ZRLE);
    guint length_at = msg->len;
    put32 (msg, 0);
    guint start = msg->len;
    e->zs.next_in = e->stream->data;
    e->zs.avail_in = e->stream->len;
    do {
        gsize room = MAX ((gsize) e->zs.avail_in / 2 + 1024, 16384);
        guint used = msg->len;
        g_byte_array_set_size (msg, used + (guint) room);
        e->zs.next_out = msg->data + used;
        e->zs.avail_out = (uInt) room;
        if (deflate (&e->zs, Z_SYNC_FLUSH) == Z_STREAM_ERROR) {
            g_byte_array_set_size (msg, mark);
            return FALSE;
        }
        g_byte_array_set_size (msg, used + (guint) (room - e->zs.avail_out));
    } while (e->zs.avail_out == 0 || e->zs.avail_in > 0);
    guint32 length = msg->len - start;
    msg->data[length_at] = (guint8) (length >> 24);
    msg->data[length_at + 1] = (guint8) (length >> 16);
    msg->data[length_at + 2] = (guint8) (length >> 8);
    msg->data[length_at + 3] = (guint8) length;
    return TRUE;
}

static void
encode_raw (RdEncoder *e, GByteArray *msg, const guint8 *fb, gint stride, gint x, gint y, gint w, gint h)
{
    rect_header (msg, x, y, w, h, RD_ENCODING_RAW);
    gint bytes = e->bits_per_pixel / 8;
    guint used = msg->len;
    g_byte_array_set_size (msg, used + (guint) ((gsize) w * h * bytes));
    rd_convert_pixels (fb, stride, x, y, w, h, msg->data + used, e->bits_per_pixel, e->big_endian, e->red_max,
                       e->green_max, e->blue_max, e->red_shift, e->green_shift, e->blue_shift);
}

static void
store_shadow (RdEncoder *e, const guint8 *fb, gint stride, gint x, gint y, gint w, gint h)
{
    for (gint row = y; row < y + h; row++)
        memcpy (e->shadow + ((gsize) row * e->shadow_width + x) * 4, fb + (gsize) row * stride + (gsize) x * 4,
                (gsize) w * 4);
}

static gboolean
tile_changed (RdEncoder *e, const guint8 *fb, gint stride, gint x, gint y, gint w, gint h)
{
    for (gint row = y; row < y + h; row++) {
        if (memcmp (e->shadow + ((gsize) row * e->shadow_width + x) * 4, fb + (gsize) row * stride + (gsize) x * 4,
                    (gsize) w * 4) != 0)
            return TRUE;
    }
    return FALSE;
}

static guint64
row_hash (const guint8 *p, gsize len)
{
    guint64 h = 1469598103934665603ull;
    const guint32 *w = (const guint32 *) p;
    for (gsize i = 0; i < len / 4; i++) {
        h ^= w[i];
        h *= 1099511628211ull;
    }
    return h;
}

static gint
scroll_strip (RdEncoder *e, const guint8 *fb, gint stride, gint x, gint y, gint w, gint h, gint *band_start,
              gint *band_length)
{
    if (h < RD_SCROLL_MIN_ROWS * 2)
        return 0;
    gsize bytes = (gsize) w * 4;
    guint64 *fresh = g_new (guint64, h);
    guint64 *old = g_new (guint64, h);
    for (gint i = 0; i < h; i++) {
        fresh[i] = row_hash (fb + (gsize) (y + i) * stride + (gsize) x * 4, bytes);
        old[i] = row_hash (e->shadow + ((gsize) (y + i) * e->shadow_width + x) * 4, bytes);
    }

    gint size = 1;
    while (size < h * 2)
        size <<= 1;
    guint64 *keys = g_new (guint64, size);
    gint *rows = g_new (gint, size);
    for (gint i = 0; i < size; i++)
        rows[i] = -2;
    for (gint i = 0; i < h; i++) {
        guint slot = (guint) (old[i] * 11400714819323198485ull >> 40) & (guint) (size - 1);
        while (rows[slot] != -2 && keys[slot] != old[i])
            slot = (slot + 1) & (guint) (size - 1);
        if (rows[slot] == -2) {
            keys[slot] = old[i];
            rows[slot] = i;
        } else {
            rows[slot] = -1;
        }
    }

    gint *votes = g_new0 (gint, h * 2);
    for (gint i = 0; i < h; i++) {
        if (i > 0 && fresh[i] == fresh[i - 1])
            continue;
        guint slot = (guint) (fresh[i] * 11400714819323198485ull >> 40) & (guint) (size - 1);
        while (rows[slot] != -2 && keys[slot] != fresh[i])
            slot = (slot + 1) & (guint) (size - 1);
        if (rows[slot] < 0 || rows[slot] == i)
            continue;
        votes[rows[slot] - i + h]++;
    }
    gint best = 0;
    gint best_votes = 0;
    for (gint d = 0; d < h * 2; d++) {
        if (votes[d] > best_votes) {
            best_votes = votes[d];
            best = d - h;
        }
    }
    g_free (votes);
    g_free (keys);
    g_free (rows);

    gint result = 0;
    if (best != 0 && best_votes >= RD_SCROLL_MIN_VOTES) {
        gint run_start = -1;
        gint top_start = 0;
        gint top_length = 0;
        for (gint i = 0; i <= h; i++) {
            gboolean match = i < h && i + best >= 0 && i + best < h && fresh[i] == old[i + best] &&
                             memcmp (fb + (gsize) (y + i) * stride + (gsize) x * 4,
                                     e->shadow + ((gsize) (y + i + best) * e->shadow_width + x) * 4, bytes) == 0;
            if (match && run_start < 0)
                run_start = i;
            if (!match && run_start >= 0) {
                if (i - run_start > top_length) {
                    top_length = i - run_start;
                    top_start = run_start;
                }
                run_start = -1;
            }
        }
        gint unchanged = 0;
        for (gint i = top_start; i < top_start + top_length; i++) {
            if (fresh[i] == old[i])
                unchanged++;
        }
        if (top_length >= RD_SCROLL_MIN_ROWS && unchanged < top_length) {
            *band_start = top_start;
            *band_length = top_length;
            result = best;
        }
    }
    g_free (fresh);
    g_free (old);
    return result;
}

static void
apply_copy (RdEncoder *e, gint x, gint y, gint w, gint h, gint src_y)
{
    gsize bytes = (gsize) w * 4;
    if (src_y > y) {
        for (gint row = 0; row < h; row++)
            memmove (e->shadow + ((gsize) (y + row) * e->shadow_width + x) * 4,
                     e->shadow + ((gsize) (src_y + row) * e->shadow_width + x) * 4, bytes);
    } else {
        for (gint row = h - 1; row >= 0; row--)
            memmove (e->shadow + ((gsize) (y + row) * e->shadow_width + x) * 4,
                     e->shadow + ((gsize) (src_y + row) * e->shadow_width + x) * 4, bytes);
    }
}

static void
flush_copy (RdEncoder *e, GByteArray *msg, gint x0, gint x1, gint y, gint length, gint src_y)
{
    rect_header (msg, x0, y, x1 - x0, length, RD_ENCODING_COPYRECT);
    put16 (msg, (guint16) x0);
    put16 (msg, (guint16) src_y);
    apply_copy (e, x0, y, x1 - x0, length, src_y);
}

static gint
copy_rects (RdEncoder *e, GByteArray *msg, const guint8 *fb, gint stride, gint x, gint y, gint w, gint h)
{
    gint count = 0;
    gint cur_dy = 0;
    gint cur_start = 0;
    gint cur_length = 0;
    gint cur_x0 = 0;
    gint cur_x1 = 0;

    for (gint sx = x; sx < x + w; sx += RD_TILE) {
        gint sw = MIN (RD_TILE, x + w - sx);
        gint start = 0;
        gint length = 0;
        gint dy = scroll_strip (e, fb, stride, sx, y, sw, h, &start, &length);
        if (dy != 0 && cur_dy == dy && start == cur_start && length == cur_length) {
            cur_x1 = sx + sw;
            continue;
        }
        if (cur_dy != 0) {
            flush_copy (e, msg, cur_x0, cur_x1, y + cur_start, cur_length, y + cur_start + cur_dy);
            count++;
        }
        cur_dy = dy;
        cur_start = start;
        cur_length = length;
        cur_x0 = sx;
        cur_x1 = sx + sw;
    }
    if (cur_dy != 0) {
        flush_copy (e, msg, cur_x0, cur_x1, y + cur_start, cur_length, y + cur_start + cur_dy);
        count++;
    }
    return count;
}

static void
changed_spans (RdEncoder *e, const guint8 *fb, gint stride, gint x, gint y, gint w, gint h, GArray *out)
{
    gint cols = (w + RD_TILE - 1) / RD_TILE;
    gint rows = (h + RD_TILE - 1) / RD_TILE;
    GArray *spans = g_array_new (FALSE, FALSE, sizeof (RdSpan));

    for (gint r = 0; r < rows; r++) {
        gint ty = y + r * RD_TILE;
        gint th = MIN (RD_TILE, y + h - ty);
        gint c = 0;
        while (c < cols) {
            gint tx = x + c * RD_TILE;
            if (!tile_changed (e, fb, stride, tx, ty, MIN (RD_TILE, x + w - tx), th)) {
                c++;
                continue;
            }
            gint c0 = c;
            while (c < cols) {
                gint cx = x + c * RD_TILE;
                if (!tile_changed (e, fb, stride, cx, ty, MIN (RD_TILE, x + w - cx), th))
                    break;
                c++;
            }
            gboolean merged = FALSE;
            for (guint i = 0; i < spans->len; i++) {
                RdSpan *s = &g_array_index (spans, RdSpan, i);
                if (s->c0 == c0 && s->c1 == c && s->r1 == r) {
                    s->r1 = r + 1;
                    merged = TRUE;
                    break;
                }
            }
            if (!merged) {
                RdSpan s = { c0, c, r, r + 1 };
                g_array_append_val (spans, s);
            }
        }
    }
    for (guint i = 0; i < spans->len; i++) {
        RdSpan *s = &g_array_index (spans, RdSpan, i);
        gint rx = x + s->c0 * RD_TILE;
        gint ry = y + s->r0 * RD_TILE;
        gint rect[4] = { rx, ry, MIN (x + s->c1 * RD_TILE, x + w) - rx, MIN (y + s->r1 * RD_TILE, y + h) - ry };
        g_array_append_vals (out, rect, 4);
    }
    g_array_unref (spans);
}

GBytes *
rd_encoder_encode (RdEncoder *e, const guint8 *fb, gint width, gint height, gint stride, const gint *rects,
                   gint n_rects)
{
    if (e->shadow_width != width || e->shadow_height != height || e->shadow == NULL) {
        g_free (e->shadow);
        e->shadow = g_malloc0 ((gsize) width * height * 4);
        e->shadow_width = width;
        e->shadow_height = height;
        e->shadow_valid = FALSE;
    }

    GByteArray *msg = g_byte_array_new ();
    guint8 head[4] = { 0, 0, 0, 0 };
    g_byte_array_append (msg, head, 4);
    gint count = 0;
    guint64 area = 0;
    GArray *work = g_array_new (FALSE, FALSE, sizeof (gint));

    for (gint i = 0; i + 3 < n_rects; i += 4) {
        gint x = CLAMP (rects[i], 0, width);
        gint y = CLAMP (rects[i + 1], 0, height);
        gint w = MIN (rects[i + 2], width - x);
        gint h = MIN (rects[i + 3], height - y);
        if (w <= 0 || h <= 0)
            continue;
        area += (guint64) w * h;
        if (e->shadow_valid && e->copy_rect) {
            gint copies = copy_rects (e, msg, fb, stride, x, y, w, h);
            count += copies;
            e->copies += (guint) copies;
        }
        if (e->shadow_valid) {
            changed_spans (e, fb, stride, x, y, w, h, work);
        } else {
            gint rect[4] = { x, y, w, h };
            g_array_append_vals (work, rect, 4);
        }
    }

    gboolean was_valid = e->shadow_valid;
    for (guint i = 0; i + 3 < work->len; i += 4) {
        gint *r = &g_array_index (work, gint, i);
        if (e->preferred != RD_ENCODING_ZRLE || !encode_zrle (e, msg, fb, stride, r[0], r[1], r[2], r[3]))
            encode_raw (e, msg, fb, stride, r[0], r[1], r[2], r[3]);
        store_shadow (e, fb, stride, r[0], r[1], r[2], r[3]);
        count++;
    }
    g_array_unref (work);
    if (!was_valid && area >= (guint64) width * height)
        e->shadow_valid = TRUE;

    if (count == 0 || count > 0xffff) {
        g_byte_array_unref (msg);
        if (count > 0xffff)
            e->shadow_valid = FALSE;
        return NULL;
    }
    msg->data[2] = (guint8) (count >> 8);
    msg->data[3] = (guint8) count;
    return g_byte_array_free_to_bytes (msg);
}
