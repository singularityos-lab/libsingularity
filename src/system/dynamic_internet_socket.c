#include "dynamic_internet_socket.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>

gboolean
singularity_socket_bind_to_device(GSocket *socket,
                                  const gchar *interface_name,
                                  GError **error)
{
#ifdef SO_BINDTODEVICE
    if (setsockopt(g_socket_get_fd(socket), SOL_SOCKET, SO_BINDTODEVICE,
                   interface_name, strlen(interface_name) + 1) == 0)
        return TRUE;

    g_set_error(error, G_IO_ERROR, g_io_error_from_errno(errno),
                "Could not bind probe to %s: %s", interface_name,
                g_strerror(errno));
#else
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                        "Interface-bound probes are not supported");
#endif
    return FALSE;
}
