#ifndef SINGULARITY_ASYNC_ENGINE_H
#define SINGULARITY_ASYNC_ENGINE_H

#include <gtk/gtk.h>

typedef gpointer (*SingularityAsyncWork)(GCancellable *cancellable, gpointer user_data, GError **error);

gboolean singularity_async_native(void);

void singularity_async_submit(int qos, SingularityAsyncWork work, gpointer work_target,
	GDestroyNotify work_target_destroy, GCancellable *cancellable,
	GAsyncReadyCallback callback, gpointer user_data);
gpointer singularity_async_submit_finish(GAsyncResult *result, GError **error);

GCancellable *singularity_async_widget_cancellable(GtkWidget *widget);

gpointer singularity_async_stream_new(void);
void singularity_async_stream_free(gpointer stream);
void singularity_async_stream_push(gpointer stream, GObject *item);
void singularity_async_stream_close(gpointer stream, const GError *error);
void singularity_async_stream_next(gpointer stream, GCancellable *cancellable,
	GAsyncReadyCallback callback, gpointer user_data);
GPtrArray *singularity_async_stream_next_finish(GAsyncResult *result, GError **error);

#endif
