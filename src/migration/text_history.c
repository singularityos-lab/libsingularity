#include "text_history.h"

#include <gmodule.h>

typedef GVariant *(*SaveBuffer)(GtkTextBuffer *buffer);
typedef gboolean (*RestoreBuffer)(GtkTextBuffer *buffer, GVariant *history);
typedef GVariant *(*SaveText)(GtkText *text);
typedef gboolean (*RestoreText)(GtkText *text, GVariant *history);

static SaveBuffer save_buffer;
static RestoreBuffer restore_buffer;
static SaveText save_text;
static RestoreText restore_text;

static void
load_history(void)
{
	static gsize initialized;

	if (g_once_init_enter(&initialized)) {
		GModule *module = g_module_open(NULL, 0);

		if (module != NULL) {
			g_module_symbol(module, "sit_text_buffer_save_history", (gpointer *)&save_buffer);
			g_module_symbol(module, "sit_text_buffer_restore_history", (gpointer *)&restore_buffer);
			g_module_symbol(module, "sit_text_save_history", (gpointer *)&save_text);
			g_module_symbol(module, "sit_text_restore_history", (gpointer *)&restore_text);
		}
		g_once_init_leave(&initialized, 1);
	}
}

gboolean
singularity_migration_text_history_available(void)
{
	load_history();
	return save_buffer != NULL && restore_buffer != NULL && save_text != NULL && restore_text != NULL;
}

GVariant *
singularity_migration_save_buffer_history(GtkTextBuffer *buffer)
{
	load_history();
	return save_buffer != NULL ? save_buffer(buffer) : NULL;
}

gboolean
singularity_migration_restore_buffer_history(GtkTextBuffer *buffer, GVariant *history)
{
	load_history();
	return restore_buffer != NULL && restore_buffer(buffer, history);
}

GVariant *
singularity_migration_save_text_history(GtkText *text)
{
	load_history();
	return save_text != NULL ? save_text(text) : NULL;
}

gboolean
singularity_migration_restore_text_history(GtkText *text, GVariant *history)
{
	load_history();
	return restore_text != NULL && restore_text(text, history);
}
