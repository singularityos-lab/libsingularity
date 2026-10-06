#include "ipp_transport.h"

#include <cups/cups.h>
#include <string.h>

static GQuark transport_error_quark(void)
{
	return g_quark_from_static_string("singularity-ipp-transport-error-quark");
}

static const char *no_password(const char *prompt, http_t *http,
	const char *method, const char *resource, void *data)
{
	(void) prompt;
	(void) http;
	(void) method;
	(void) resource;
	(void) data;
	return NULL;
}

static ipp_tag_t group_tag(const char *name)
{
	if (g_strcmp0(name, "job") == 0)
		return IPP_TAG_JOB;
	if (g_strcmp0(name, "printer") == 0)
		return IPP_TAG_PRINTER;
	if (g_strcmp0(name, "subscription") == 0)
		return IPP_TAG_SUBSCRIPTION;
	return IPP_TAG_OPERATION;
}

static const char *group_name(ipp_tag_t tag)
{
	switch (tag) {
	case IPP_TAG_OPERATION:
		return "operation";
	case IPP_TAG_JOB:
		return "job";
	case IPP_TAG_PRINTER:
		return "printer";
	case IPP_TAG_UNSUPPORTED_GROUP:
		return "unsupported";
	case IPP_TAG_SUBSCRIPTION:
		return "subscription";
	case IPP_TAG_EVENT_NOTIFICATION:
		return "event";
	default:
		return "other";
	}
}

static ipp_tag_t value_tag(const char *name)
{
	static const struct {
		const char *name;
		ipp_tag_t tag;
	} tags[] = {
		{ "keyword", IPP_TAG_KEYWORD },
		{ "name", IPP_TAG_NAME },
		{ "text", IPP_TAG_TEXT },
		{ "uri", IPP_TAG_URI },
		{ "mimeMediaType", IPP_TAG_MIMETYPE },
		{ "naturalLanguage", IPP_TAG_LANGUAGE },
		{ "charset", IPP_TAG_CHARSET },
		{ "integer", IPP_TAG_INTEGER },
		{ "enum", IPP_TAG_ENUM },
		{ "boolean", IPP_TAG_BOOLEAN },
		{ "rangeOfInteger", IPP_TAG_RANGE },
		{ "collection", IPP_TAG_BEGIN_COLLECTION },
	};
	for (gsize i = 0; i < G_N_ELEMENTS(tags); i++) {
		if (g_strcmp0(tags[i].name, name) == 0)
			return tags[i].tag;
	}
	return IPP_TAG_KEYWORD;
}

static ipp_t *collection_from_variant(GVariant *dict);

static void add_collection_member(ipp_t *col, const char *key, GVariant *value)
{
	if (g_variant_is_of_type(value, G_VARIANT_TYPE_VARIANT)) {
		GVariant *inner = g_variant_get_variant(value);
		add_collection_member(col, key, inner);
		g_variant_unref(inner);
		return;
	}
	if (g_variant_is_of_type(value, G_VARIANT_TYPE_INT32)) {
		ippAddInteger(col, IPP_TAG_ZERO, IPP_TAG_INTEGER, key, g_variant_get_int32(value));
	} else if (g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN)) {
		ippAddBoolean(col, IPP_TAG_ZERO, key, g_variant_get_boolean(value));
	} else if (g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
		ippAddString(col, IPP_TAG_ZERO, IPP_TAG_KEYWORD, key, NULL, g_variant_get_string(value, NULL));
	} else if (g_variant_is_of_type(value, G_VARIANT_TYPE_VARDICT)) {
		ipp_t *child = collection_from_variant(value);
		ippAddCollection(col, IPP_TAG_ZERO, key, child);
		ippDelete(child);
	}
}

static ipp_t *collection_from_variant(GVariant *dict)
{
	ipp_t *col = ippNew();
	GVariantIter iter;
	const char *key;
	GVariant *value;
	g_variant_iter_init(&iter, dict);
	while (g_variant_iter_next(&iter, "{&sv}", &key, &value)) {
		add_collection_member(col, key, value);
		g_variant_unref(value);
	}
	return col;
}

static void add_attribute(ipp_t *request, const char *group, const char *tag_name,
	const char *name, GVariant *value)
{
	ipp_tag_t group_id = group_tag(group);
	ipp_tag_t tag = value_tag(tag_name);

	if (tag == IPP_TAG_BEGIN_COLLECTION) {
		if (g_variant_is_of_type(value, G_VARIANT_TYPE_VARDICT)) {
			ipp_t *col = collection_from_variant(value);
			ippAddCollection(request, group_id, name, col);
			ippDelete(col);
		}
		return;
	}
	if (g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
		ippAddString(request, group_id, tag, name, NULL, g_variant_get_string(value, NULL));
	} else if (g_variant_is_of_type(value, G_VARIANT_TYPE_STRING_ARRAY)) {
		gsize n = 0;
		const gchar **values = g_variant_get_strv(value, &n);
		if (n > 0)
			ippAddStrings(request, group_id, tag, name, (int) n, NULL, values);
		g_free(values);
	} else if (g_variant_is_of_type(value, G_VARIANT_TYPE_INT32)) {
		ippAddInteger(request, group_id, tag == IPP_TAG_ENUM ? IPP_TAG_ENUM : IPP_TAG_INTEGER,
			name, g_variant_get_int32(value));
	} else if (g_variant_is_of_type(value, G_VARIANT_TYPE("ai"))) {
		gsize n = 0;
		const gint32 *values = g_variant_get_fixed_array(value, &n, sizeof(gint32));
		if (n > 0)
			ippAddIntegers(request, group_id, tag == IPP_TAG_ENUM ? IPP_TAG_ENUM : IPP_TAG_INTEGER,
				name, (int) n, (const int *) values);
	} else if (g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN)) {
		ippAddBoolean(request, group_id, name, g_variant_get_boolean(value));
	} else if (g_variant_is_of_type(value, G_VARIANT_TYPE("(ii)"))) {
		int lower, upper;
		g_variant_get(value, "(ii)", &lower, &upper);
		ippAddRange(request, group_id, name, lower, upper);
	} else if (g_variant_is_of_type(value, G_VARIANT_TYPE("a(ii)"))) {
		gsize n = g_variant_n_children(value);
		if (n == 0)
			return;
		int *lowers = g_new(int, n);
		int *uppers = g_new(int, n);
		for (gsize i = 0; i < n; i++)
			g_variant_get_child(value, i, "(ii)", &lowers[i], &uppers[i]);
		ippAddRanges(request, group_id, name, (int) n, lowers, uppers);
		g_free(lowers);
		g_free(uppers);
	}
}

static GVariant *collection_to_variant(ipp_t *col);

static GVariant *value_to_variant(ipp_attribute_t *attr, int index)
{
	switch (ippGetValueTag(attr)) {
	case IPP_TAG_INTEGER:
	case IPP_TAG_ENUM:
		return g_variant_new_int32(ippGetInteger(attr, index));
	case IPP_TAG_BOOLEAN:
		return g_variant_new_boolean(ippGetBoolean(attr, index));
	case IPP_TAG_RANGE: {
		int upper = 0;
		int lower = ippGetRange(attr, index, &upper);
		return g_variant_new("(ii)", lower, upper);
	}
	case IPP_TAG_RESOLUTION: {
		int yres = 0;
		ipp_res_t units = IPP_RES_PER_INCH;
		int xres = ippGetResolution(attr, index, &yres, &units);
		return g_variant_new("(iii)", xres, yres, (int) units);
	}
	case IPP_TAG_DATE:
		return g_variant_new_int64((gint64) ippDateToTime(ippGetDate(attr, index)));
	case IPP_TAG_BEGIN_COLLECTION:
		return collection_to_variant(ippGetCollection(attr, index));
	case IPP_TAG_TEXT:
	case IPP_TAG_NAME:
	case IPP_TAG_KEYWORD:
	case IPP_TAG_URI:
	case IPP_TAG_URISCHEME:
	case IPP_TAG_CHARSET:
	case IPP_TAG_LANGUAGE:
	case IPP_TAG_MIMETYPE:
	case IPP_TAG_TEXTLANG:
	case IPP_TAG_NAMELANG:
	case IPP_TAG_STRING: {
		const char *text = ippGetString(attr, index, NULL);
		char *valid = g_utf8_make_valid(text ? text : "", -1);
		GVariant *result = g_variant_new_string(valid);
		g_free(valid);
		return result;
	}
	default:
		return NULL;
	}
}

static GVariant *attribute_to_variant(ipp_attribute_t *attr)
{
	int count = ippGetCount(attr);
	if (count <= 0)
		return NULL;
	if (count == 1)
		return value_to_variant(attr, 0);

	GPtrArray *items = g_ptr_array_new();
	gboolean same = TRUE;
	for (int i = 0; i < count; i++) {
		GVariant *item = value_to_variant(attr, i);
		if (item == NULL)
			continue;
		if (items->len > 0 && !g_variant_type_equal(g_variant_get_type(item),
			g_variant_get_type(g_ptr_array_index(items, 0))))
			same = FALSE;
		g_ptr_array_add(items, g_variant_ref_sink(item));
	}
	if (items->len == 0) {
		g_ptr_array_free(items, TRUE);
		return NULL;
	}
	GVariant *result;
	if (same) {
		result = g_variant_new_array(g_variant_get_type(g_ptr_array_index(items, 0)),
			(GVariant **) items->pdata, items->len);
	} else {
		GVariant **boxed = g_new(GVariant *, items->len);
		for (guint i = 0; i < items->len; i++)
			boxed[i] = g_variant_new_variant(g_ptr_array_index(items, i));
		result = g_variant_new_array(G_VARIANT_TYPE_VARIANT, boxed, items->len);
		g_free(boxed);
	}
	for (guint i = 0; i < items->len; i++)
		g_variant_unref(g_ptr_array_index(items, i));
	g_ptr_array_free(items, TRUE);
	return result;
}

static GVariant *collection_to_variant(ipp_t *col)
{
	GVariantBuilder builder;
	g_variant_builder_init(&builder, G_VARIANT_TYPE_VARDICT);
	for (ipp_attribute_t *attr = ippFirstAttribute(col); attr != NULL; attr = ippNextAttribute(col)) {
		const char *name = ippGetName(attr);
		if (name == NULL)
			continue;
		GVariant *value = attribute_to_variant(attr);
		if (value != NULL)
			g_variant_builder_add(&builder, "{sv}", name, value);
	}
	return g_variant_builder_end(&builder);
}

static GVariant *response_groups(ipp_t *response)
{
	GVariantBuilder groups;
	GVariantBuilder *current = NULL;
	ipp_tag_t current_tag = IPP_TAG_ZERO;

	g_variant_builder_init(&groups, G_VARIANT_TYPE("aa{sv}"));
	for (ipp_attribute_t *attr = ippFirstAttribute(response); attr != NULL; attr = ippNextAttribute(response)) {
		const char *name = ippGetName(attr);
		ipp_tag_t tag = ippGetGroupTag(attr);
		if (name == NULL || tag != current_tag) {
			if (current != NULL) {
				g_variant_builder_add_value(&groups, g_variant_builder_end(current));
				g_variant_builder_unref(current);
				current = NULL;
			}
			current_tag = name == NULL ? IPP_TAG_ZERO : tag;
			if (name == NULL)
				continue;
		}
		if (current == NULL) {
			current = g_variant_builder_new(G_VARIANT_TYPE_VARDICT);
			g_variant_builder_add(current, "{sv}", "@group", g_variant_new_string(group_name(tag)));
		}
		GVariant *value = attribute_to_variant(attr);
		if (value != NULL)
			g_variant_builder_add(current, "{sv}", name, value);
	}
	if (current != NULL) {
		g_variant_builder_add_value(&groups, g_variant_builder_end(current));
		g_variant_builder_unref(current);
	}
	return g_variant_builder_end(&groups);
}

char *singularity_ipp_transport_server(void)
{
	return g_strdup(cupsServer());
}

GVariant *singularity_ipp_transport_request(const char *uri, int operation,
	const char *resource, GVariant *attributes, const char *document_path,
	GError **error)
{
	http_t *http = CUPS_HTTP_DEFAULT;
	char path[1024] = "/";

	cupsSetPasswordCB2(no_password, NULL);

	if (uri != NULL && *uri != '\0') {
		char scheme[32], userpass[256], host[256];
		int port = 0;
		if (httpSeparateURI(HTTP_URI_CODING_ALL, uri, scheme, sizeof(scheme), userpass,
			sizeof(userpass), host, sizeof(host), &port, path, sizeof(path)) < HTTP_URI_STATUS_OK) {
			g_set_error(error, transport_error_quark(), 1, "Invalid printer address %s", uri);
			return NULL;
		}
		http_encryption_t encryption = HTTP_ENCRYPTION_IF_REQUESTED;
		if (g_strcmp0(scheme, "ipps") == 0 || g_strcmp0(scheme, "https") == 0)
			encryption = HTTP_ENCRYPTION_ALWAYS;
		http = httpConnect2(host, port, NULL, AF_UNSPEC, encryption, 1, 8000, NULL);
		if (http == NULL) {
			g_set_error(error, transport_error_quark(), 2, "%s", cupsLastErrorString());
			return NULL;
		}
	}

	ipp_t *request = ippNewRequest((ipp_op_t) operation);
	if (attributes != NULL) {
		GVariantIter iter;
		const char *group, *tag, *name;
		GVariant *value;
		g_variant_iter_init(&iter, attributes);
		while (g_variant_iter_next(&iter, "(&s&s&sv)", &group, &tag, &name, &value)) {
			add_attribute(request, group, tag, name, value);
			g_variant_unref(value);
		}
	}

	const char *target = resource != NULL && *resource != '\0' ? resource : path;
	ipp_t *response = cupsDoFileRequest(http, request, target, document_path);
	if (http != CUPS_HTTP_DEFAULT)
		httpClose(http);

	if (response == NULL) {
		g_set_error(error, transport_error_quark(), 3, "%s", cupsLastErrorString());
		return NULL;
	}

	const char *message = cupsLastErrorString();
	GVariant *result = g_variant_new("(is@aa{sv})", (int) ippGetStatusCode(response),
		message != NULL ? message : "", response_groups(response));
	ippDelete(response);
	return g_variant_ref_sink(result);
}
