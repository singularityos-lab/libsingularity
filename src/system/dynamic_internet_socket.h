#pragma once

#include <gio/gio.h>

G_BEGIN_DECLS

gboolean singularity_socket_bind_to_device(GSocket *socket,
                                            const gchar *interface_name,
                                            GError **error);

G_END_DECLS
