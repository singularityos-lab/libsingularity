#ifndef SINGULARITY_IPP_TRANSPORT_H
#define SINGULARITY_IPP_TRANSPORT_H

#include <glib.h>

GVariant *singularity_ipp_transport_request(const char *uri, int operation,
	const char *resource, GVariant *attributes, const char *document_path,
	GError **error);

char *singularity_ipp_transport_server(void);

#endif
