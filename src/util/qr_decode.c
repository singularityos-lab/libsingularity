#include <glib.h>
#include <dlfcn.h>
#include <string.h>

typedef void *(*scanner_create_fn) (void);
typedef int (*scanner_config_fn) (void *, int, int, int);
typedef void (*scanner_destroy_fn) (void *);
typedef void *(*image_create_fn) (void);
typedef void (*image_set_format_fn) (void *, unsigned long);
typedef void (*image_set_size_fn) (void *, unsigned, unsigned);
typedef void (*image_set_data_fn) (void *, const void *, unsigned long, void (*) (void *));
typedef int (*scan_image_fn) (void *, void *);
typedef const void *(*first_symbol_fn) (const void *);
typedef const void *(*symbol_next_fn) (const void *);
typedef const char *(*symbol_data_fn) (const void *);
typedef unsigned (*symbol_length_fn) (const void *);
typedef int (*symbol_type_fn) (const void *);
typedef void (*image_destroy_fn) (void *);

static struct {
    gboolean tried;
    void *lib;
    scanner_create_fn scanner_create;
    scanner_config_fn scanner_config;
    scanner_destroy_fn scanner_destroy;
    image_create_fn image_create;
    image_set_format_fn image_set_format;
    image_set_size_fn image_set_size;
    image_set_data_fn image_set_data;
    scan_image_fn scan_image;
    first_symbol_fn first_symbol;
    symbol_next_fn symbol_next;
    symbol_data_fn symbol_data;
    symbol_length_fn symbol_length;
    symbol_type_fn symbol_type;
    image_destroy_fn image_destroy;
} zb;

static gboolean
load_zbar (void)
{
    if (zb.tried)
        return zb.lib != NULL;
    zb.tried = TRUE;
    zb.lib = dlopen ("libzbar.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (zb.lib == NULL)
        return FALSE;
#define SYM(field, name) zb.field = dlsym (zb.lib, name); if (zb.field == NULL) { dlclose (zb.lib); zb.lib = NULL; return FALSE; }
    SYM (scanner_create, "zbar_image_scanner_create")
    SYM (scanner_config, "zbar_image_scanner_set_config")
    SYM (scanner_destroy, "zbar_image_scanner_destroy")
    SYM (image_create, "zbar_image_create")
    SYM (image_set_format, "zbar_image_set_format")
    SYM (image_set_size, "zbar_image_set_size")
    SYM (image_set_data, "zbar_image_set_data")
    SYM (scan_image, "zbar_scan_image")
    SYM (first_symbol, "zbar_image_first_symbol")
    SYM (symbol_next, "zbar_symbol_next")
    SYM (symbol_data, "zbar_symbol_get_data")
    SYM (symbol_length, "zbar_symbol_get_data_length")
    SYM (symbol_type, "zbar_symbol_get_type")
    SYM (image_destroy, "zbar_image_destroy")
#undef SYM
    return TRUE;
}

gboolean
singularity_qr_decode_available (void)
{
    return load_zbar ();
}

gchar **
singularity_qr_decode_gray (const guint8 *gray, gint gray_length, gint width, gint height)
{
    GPtrArray *found = g_ptr_array_new ();
    if (gray != NULL && width > 0 && height > 0 && gray_length >= width * height && load_zbar ()) {
        void *scanner = zb.scanner_create ();
        zb.scanner_config (scanner, 0, 0, 0);
        zb.scanner_config (scanner, 64, 0, 1);
        void *image = zb.image_create ();
        zb.image_set_format (image, (unsigned long) ('Y' | ('8' << 8) | ('0' << 16) | ((unsigned long) '0' << 24)));
        zb.image_set_size (image, (unsigned) width, (unsigned) height);
        guint8 *copy = g_memdup2 (gray, (gsize) width * height);
        zb.image_set_data (image, copy, (unsigned long) width * height, NULL);
        if (zb.scan_image (scanner, image) > 0) {
            for (const void *s = zb.first_symbol (image); s != NULL; s = zb.symbol_next (s)) {
                const char *data = zb.symbol_data (s);
                unsigned length = zb.symbol_length (s);
                if (data != NULL && length > 0 && zb.symbol_type (s) == 64)
                    g_ptr_array_add (found, g_strndup (data, length));
            }
        }
        zb.image_destroy (image);
        zb.scanner_destroy (scanner);
        g_free (copy);
    }
    g_ptr_array_add (found, NULL);
    return (gchar **) g_ptr_array_free (found, FALSE);
}
