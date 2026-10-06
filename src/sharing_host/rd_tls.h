#pragma once

#include <glib.h>

G_BEGIN_DECLS

gboolean rd_tls_generate (const gchar *cert_path, const gchar *key_path, const gchar *common_name, GError **error);

G_END_DECLS
