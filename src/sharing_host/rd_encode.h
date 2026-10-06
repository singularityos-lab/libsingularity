#pragma once

#include <glib.h>

G_BEGIN_DECLS

#define RD_ENCODING_RAW 0
#define RD_ENCODING_COPYRECT 1
#define RD_ENCODING_ZRLE 16

typedef struct _RdEncoder RdEncoder;

RdEncoder *rd_encoder_new (void);
void rd_encoder_free (RdEncoder *encoder);
void rd_encoder_set_format (RdEncoder *encoder, gint bits_per_pixel, gint depth, gboolean big_endian,
                            guint16 red_max, guint16 green_max, guint16 blue_max, guint8 red_shift,
                            guint8 green_shift, guint8 blue_shift);
void rd_encoder_set_encodings (RdEncoder *encoder, gint preferred, gboolean copy_rect);
void rd_encoder_invalidate (RdEncoder *encoder);
GBytes *rd_encoder_encode (RdEncoder *encoder, const guint8 *framebuffer, gint width, gint height, gint stride,
                           const gint *rects, gint n_rects);
guint rd_encoder_get_copy_count (RdEncoder *encoder);

void rd_convert_pixels (const guint8 *src, gint src_stride, gint x, gint y, gint width, gint height, guint8 *dst,
                        gint bits_per_pixel, gboolean big_endian, guint16 red_max, guint16 green_max,
                        guint16 blue_max, guint8 red_shift, guint8 green_shift, guint8 blue_shift);

G_END_DECLS
