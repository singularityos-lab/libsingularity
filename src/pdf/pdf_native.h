#pragma once

#include <glib.h>

typedef struct _SingularityPdfFontFile SingularityPdfFontFile;

SingularityPdfFontFile *singularity_pdf_font_file_open (const char *path, int index);
SingularityPdfFontFile *singularity_pdf_font_file_open_data (const guint8 *data, gsize length, int index);
void singularity_pdf_font_file_free (SingularityPdfFontFile *f);
guint singularity_pdf_font_file_glyph (SingularityPdfFontFile *f, gunichar c);
int singularity_pdf_font_file_advance (SingularityPdfFontFile *f, guint glyph);
int singularity_pdf_font_file_upem (SingularityPdfFontFile *f);
int singularity_pdf_font_file_glyph_count (SingularityPdfFontFile *f);
void singularity_pdf_font_file_metrics (SingularityPdfFontFile *f, int *ascent, int *descent, int *cap_height,
                                        int *x_min, int *y_min, int *x_max, int *y_max);
char *singularity_pdf_font_file_postscript_name (SingularityPdfFontFile *f);
gboolean singularity_pdf_font_file_is_cff (SingularityPdfFontFile *f);
GBytes *singularity_pdf_font_file_data (SingularityPdfFontFile *f);
GBytes *singularity_pdf_font_file_subset (SingularityPdfFontFile *f, const guint *glyphs, int n_glyphs);
char *singularity_pdf_font_match (const char *pattern, int *index);
char *singularity_pdf_font_family (const char *path);
GBytes *singularity_pdf_srgb_profile (void);
int singularity_pdf_profile_channels (const guint8 *data, gsize length);
char *singularity_pdf_profile_description (const guint8 *data, gsize length);
gboolean singularity_pdf_rgb_to_cmyk (const guint8 *profile_data, gsize profile_length, const guint8 *rgb, guint8 *cmyk, int pixels);
char *singularity_pdf_font_find_family (const char *compact);
