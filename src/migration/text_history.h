#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

gboolean singularity_migration_text_history_available(void);
GVariant *singularity_migration_save_buffer_history(GtkTextBuffer *buffer);
gboolean singularity_migration_restore_buffer_history(GtkTextBuffer *buffer, GVariant *history);
GVariant *singularity_migration_save_text_history(GtkText *text);
gboolean singularity_migration_restore_text_history(GtkText *text, GVariant *history);

G_END_DECLS
