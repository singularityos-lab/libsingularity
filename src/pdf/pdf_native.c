#include <glib.h>
#include <string.h>
#include <fontconfig/fontconfig.h>
#include <hb.h>
#include <hb-ot.h>
#include <hb-subset.h>
#include <lcms2.h>

#include "pdf_native.h"

struct _SingularityPdfFontFile {
    hb_blob_t *blob;
    hb_face_t *face;
    hb_font_t *font;
    int index;
};

static SingularityPdfFontFile *
wrap_blob (hb_blob_t *blob, int index)
{
    if (hb_blob_get_length (blob) == 0) {
        hb_blob_destroy (blob);
        return NULL;
    }
    SingularityPdfFontFile *f = g_new0 (SingularityPdfFontFile, 1);
    f->blob = blob;
    f->index = index;
    f->face = hb_face_create (blob, index);
    f->font = hb_font_create (f->face);
    hb_ot_font_set_funcs (f->font);
    if (hb_face_get_glyph_count (f->face) == 0) {
        singularity_pdf_font_file_free (f);
        return NULL;
    }
    return f;
}

SingularityPdfFontFile *
singularity_pdf_font_file_open (const char *path, int index)
{
    hb_blob_t *blob = hb_blob_create_from_file (path);
    return wrap_blob (blob, index);
}

SingularityPdfFontFile *
singularity_pdf_font_file_open_data (const guint8 *data, gsize length, int index)
{
    guint8 *copy = g_memdup2 (data, length);
    hb_blob_t *blob = hb_blob_create ((const char *) copy, (unsigned int) length, HB_MEMORY_MODE_WRITABLE, copy, g_free);
    return wrap_blob (blob, index);
}

void
singularity_pdf_font_file_free (SingularityPdfFontFile *f)
{
    if (f == NULL)
        return;
    hb_font_destroy (f->font);
    hb_face_destroy (f->face);
    hb_blob_destroy (f->blob);
    g_free (f);
}

guint
singularity_pdf_font_file_glyph (SingularityPdfFontFile *f, gunichar c)
{
    hb_codepoint_t glyph = 0;
    if (!hb_font_get_nominal_glyph (f->font, c, &glyph))
        return 0;
    return glyph;
}

int
singularity_pdf_font_file_advance (SingularityPdfFontFile *f, guint glyph)
{
    return hb_font_get_glyph_h_advance (f->font, glyph);
}

int
singularity_pdf_font_file_upem (SingularityPdfFontFile *f)
{
    return (int) hb_face_get_upem (f->face);
}

int
singularity_pdf_font_file_glyph_count (SingularityPdfFontFile *f)
{
    return (int) hb_face_get_glyph_count (f->face);
}

void
singularity_pdf_font_file_metrics (SingularityPdfFontFile *f, int *ascent, int *descent, int *cap_height,
                                   int *x_min, int *y_min, int *x_max, int *y_max)
{
    hb_position_t v = 0;
    *ascent = hb_ot_metrics_get_position (f->font, HB_OT_METRICS_TAG_HORIZONTAL_ASCENDER, &v) ? v : (int) (hb_face_get_upem (f->face) * 0.8);
    *descent = hb_ot_metrics_get_position (f->font, HB_OT_METRICS_TAG_HORIZONTAL_DESCENDER, &v) ? v : -(int) (hb_face_get_upem (f->face) * 0.2);
    *cap_height = hb_ot_metrics_get_position (f->font, HB_OT_METRICS_TAG_CAP_HEIGHT, &v) ? v : *ascent;
    *x_min = 0;
    *y_min = *descent;
    *x_max = (int) hb_face_get_upem (f->face);
    *y_max = *ascent;
    hb_blob_t *head = hb_face_reference_table (f->face, HB_TAG ('h', 'e', 'a', 'd'));
    unsigned int len = 0;
    const guint8 *d = (const guint8 *) hb_blob_get_data (head, &len);
    if (d != NULL && len >= 44) {
        *x_min = (gint16) ((d[36] << 8) | d[37]);
        *y_min = (gint16) ((d[38] << 8) | d[39]);
        *x_max = (gint16) ((d[40] << 8) | d[41]);
        *y_max = (gint16) ((d[42] << 8) | d[43]);
    }
    hb_blob_destroy (head);
}

char *
singularity_pdf_font_file_postscript_name (SingularityPdfFontFile *f)
{
    char buf[256];
    unsigned int size = sizeof (buf);
    unsigned int n = hb_ot_name_get_utf8 (f->face, HB_OT_NAME_ID_POSTSCRIPT_NAME, HB_LANGUAGE_INVALID, &size, buf);
    if (n == 0)
        return g_strdup ("Font");
    GString *s = g_string_new (NULL);
    for (unsigned int i = 0; i < size && buf[i]; i++) {
        char c = buf[i];
        if (c > 32 && c < 127 && c != '/' && c != '(' && c != ')' && c != '[' && c != ']' && c != '<' && c != '>' && c != '{' && c != '}' && c != '%' && c != '#')
            g_string_append_c (s, c);
    }
    if (s->len == 0)
        g_string_append (s, "Font");
    return g_string_free (s, FALSE);
}

gboolean
singularity_pdf_font_file_is_cff (SingularityPdfFontFile *f)
{
    hb_blob_t *cff = hb_face_reference_table (f->face, HB_TAG ('C', 'F', 'F', ' '));
    gboolean result = hb_blob_get_length (cff) > 0;
    hb_blob_destroy (cff);
    return result;
}

GBytes *
singularity_pdf_font_file_data (SingularityPdfFontFile *f)
{
    unsigned int len = 0;
    const char *d = hb_blob_get_data (f->blob, &len);
    return g_bytes_new (d, len);
}

GBytes *
singularity_pdf_font_file_subset (SingularityPdfFontFile *f, const guint *glyphs, int n_glyphs)
{
    hb_subset_input_t *input = hb_subset_input_create_or_fail ();
    if (input == NULL)
        return NULL;
    hb_set_t *set = hb_subset_input_glyph_set (input);
    hb_set_add (set, 0);
    for (int i = 0; i < n_glyphs; i++)
        hb_set_add (set, glyphs[i]);
    hb_subset_input_set_flags (input, HB_SUBSET_FLAGS_RETAIN_GIDS | HB_SUBSET_FLAGS_NO_HINTING);
    hb_set_t *drop = hb_subset_input_set (input, HB_SUBSET_SETS_DROP_TABLE_TAG);
    hb_set_add (drop, HB_TAG ('G', 'S', 'U', 'B'));
    hb_set_add (drop, HB_TAG ('G', 'P', 'O', 'S'));
    hb_set_add (drop, HB_TAG ('G', 'D', 'E', 'F'));
    hb_face_t *sub = hb_subset_or_fail (f->face, input);
    hb_subset_input_destroy (input);
    if (sub == NULL)
        return NULL;
    hb_blob_t *blob = hb_face_reference_blob (sub);
    unsigned int len = 0;
    const char *d = hb_blob_get_data (blob, &len);
    GBytes *result = len > 0 ? g_bytes_new (d, len) : NULL;
    hb_blob_destroy (blob);
    hb_face_destroy (sub);
    return result;
}

char *
singularity_pdf_font_match (const char *pattern, int *index)
{
    *index = 0;
    if (!FcInit ())
        return NULL;
    FcPattern *pat = FcNameParse ((const FcChar8 *) pattern);
    if (pat == NULL)
        return NULL;
    FcConfigSubstitute (NULL, pat, FcMatchPattern);
    FcDefaultSubstitute (pat);
    FcResult result;
    FcPattern *match = FcFontMatch (NULL, pat, &result);
    FcPatternDestroy (pat);
    if (match == NULL)
        return NULL;
    FcChar8 *file = NULL;
    char *path = NULL;
    if (FcPatternGetString (match, FC_FILE, 0, &file) == FcResultMatch)
        path = g_strdup ((const char *) file);
    int idx = 0;
    if (FcPatternGetInteger (match, FC_INDEX, 0, &idx) == FcResultMatch)
        *index = idx;
    FcPatternDestroy (match);
    return path;
}

char *
singularity_pdf_font_family (const char *path)
{
    int count = 0;
    FcPattern *pat = FcFreeTypeQuery ((const FcChar8 *) path, 0, NULL, &count);
    if (pat == NULL)
        return NULL;
    FcChar8 *family = NULL;
    char *result = NULL;
    if (FcPatternGetString (pat, FC_FAMILY, 0, &family) == FcResultMatch)
        result = g_strdup ((const char *) family);
    FcPatternDestroy (pat);
    return result;
}

GBytes *
singularity_pdf_srgb_profile (void)
{
    cmsHPROFILE profile = cmsCreate_sRGBProfile ();
    if (profile == NULL)
        return NULL;
    cmsMLU *desc = cmsMLUalloc (NULL, 1);
    cmsMLUsetASCII (desc, "en", "US", "sRGB IEC61966-2.1");
    cmsWriteTag (profile, cmsSigProfileDescriptionTag, desc);
    cmsMLUfree (desc);
    cmsUInt32Number size = 0;
    GBytes *result = NULL;
    if (cmsSaveProfileToMem (profile, NULL, &size) && size > 0) {
        guint8 *buf = g_malloc (size);
        if (cmsSaveProfileToMem (profile, buf, &size))
            result = g_bytes_new_take (buf, size);
        else
            g_free (buf);
    }
    cmsCloseProfile (profile);
    return result;
}

int
singularity_pdf_profile_channels (const guint8 *data, gsize length)
{
    cmsHPROFILE profile = cmsOpenProfileFromMem (data, (cmsUInt32Number) length);
    if (profile == NULL)
        return 0;
    int channels = cmsChannelsOf (cmsGetColorSpace (profile));
    cmsCloseProfile (profile);
    return channels;
}

char *
singularity_pdf_profile_description (const guint8 *data, gsize length)
{
    cmsHPROFILE profile = cmsOpenProfileFromMem (data, (cmsUInt32Number) length);
    if (profile == NULL)
        return NULL;
    char buf[256] = { 0 };
    cmsGetProfileInfoASCII (profile, cmsInfoDescription, "en", "US", buf, sizeof (buf) - 1);
    cmsCloseProfile (profile);
    return g_strdup (buf);
}

gboolean
singularity_pdf_rgb_to_cmyk (const guint8 *profile_data, gsize profile_length, const guint8 *rgb, guint8 *cmyk, int pixels)
{
    cmsHPROFILE srgb = cmsCreate_sRGBProfile ();
    cmsHPROFILE target = profile_data != NULL ? cmsOpenProfileFromMem (profile_data, (cmsUInt32Number) profile_length) : NULL;
    if (target == NULL) {
        cmsCloseProfile (srgb);
        for (int i = 0; i < pixels; i++) {
            double r = rgb[i * 3] / 255.0, g = rgb[i * 3 + 1] / 255.0, b = rgb[i * 3 + 2] / 255.0;
            double k = 1.0 - MAX (r, MAX (g, b));
            double c = k < 1.0 ? (1.0 - r - k) / (1.0 - k) : 0, m = k < 1.0 ? (1.0 - g - k) / (1.0 - k) : 0, y = k < 1.0 ? (1.0 - b - k) / (1.0 - k) : 0;
            cmyk[i * 4] = (guint8) (c * 255 + 0.5);
            cmyk[i * 4 + 1] = (guint8) (m * 255 + 0.5);
            cmyk[i * 4 + 2] = (guint8) (y * 255 + 0.5);
            cmyk[i * 4 + 3] = (guint8) (k * 255 + 0.5);
        }
        return FALSE;
    }
    cmsHTRANSFORM t = cmsCreateTransform (srgb, TYPE_RGB_8, target, TYPE_CMYK_8, INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_BLACKPOINTCOMPENSATION);
    if (t != NULL) {
        cmsDoTransform (t, rgb, cmyk, (cmsUInt32Number) pixels);
        cmsDeleteTransform (t);
    }
    cmsCloseProfile (target);
    cmsCloseProfile (srgb);
    return t != NULL;
}

static char *
normalize_family (const char *s)
{
    GString *out = g_string_new (NULL);
    for (const char *p = s; *p; p++) {
        if (g_ascii_isalnum (*p))
            g_string_append_c (out, g_ascii_tolower (*p));
    }
    return g_string_free (out, FALSE);
}

char *
singularity_pdf_font_find_family (const char *compact)
{
    if (!FcInit ())
        return NULL;
    char *want = normalize_family (compact);
    FcPattern *pat = FcPatternCreate ();
    FcObjectSet *os = FcObjectSetBuild (FC_FAMILY, NULL);
    FcFontSet *set = FcFontList (NULL, pat, os);
    char *best = NULL;
    size_t best_len = 0;
    for (int i = 0; set != NULL && i < set->nfont; i++) {
        FcChar8 *family = NULL;
        for (int k = 0; FcPatternGetString (set->fonts[i], FC_FAMILY, k, &family) == FcResultMatch; k++) {
            char *norm = normalize_family ((const char *) family);
            size_t len = strlen (norm);
            if (len > 0 && g_str_has_prefix (want, norm) && len > best_len) {
                g_free (best);
                best = g_strdup ((const char *) family);
                best_len = len;
            }
            g_free (norm);
        }
    }
    if (set != NULL)
        FcFontSetDestroy (set);
    FcObjectSetDestroy (os);
    FcPatternDestroy (pat);
    g_free (want);
    return best;
}
