#include "async_engine.h"
#include "background_work.h"

#include <gmodule.h>

typedef void (*NativeRun)(gpointer scope, int qos, GDestroyNotify result_destroy,
	SingularityAsyncWork func, gpointer func_data, GDestroyNotify func_data_destroy,
	GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);
typedef gpointer (*NativeRunFinish)(GAsyncResult *result, GError **error);
typedef gpointer (*NativeWidgetScope)(GtkWidget *widget);
typedef GCancellable *(*NativeScopeCancellable)(gpointer scope);
typedef gpointer (*NativeStreamNew)(void);
typedef void (*NativeStreamPush)(gpointer stream, GObject *item);
typedef void (*NativeStreamClose)(gpointer stream, const GError *error);
typedef void (*NativeStreamNext)(gpointer stream, GCancellable *cancellable,
	GAsyncReadyCallback callback, gpointer user_data);
typedef GPtrArray *(*NativeStreamNextFinish)(gpointer stream, GAsyncResult *result, GError **error);
typedef void (*NativeFileLoad)(GFile *file, int qos, GCancellable *cancellable,
	GAsyncReadyCallback callback, gpointer user_data);
typedef GBytes *(*NativeFileLoadFinish)(GFile *file, GAsyncResult *result, GError **error);

static NativeRun native_run;
static NativeRunFinish native_run_finish;
static NativeWidgetScope native_widget_scope;
static NativeScopeCancellable native_scope_cancellable;
static NativeStreamNew native_stream_new;
static NativeStreamPush native_stream_push;
static NativeStreamClose native_stream_close;
static NativeStreamNext native_stream_next;
static NativeStreamNextFinish native_stream_next_finish;
static NativeFileLoad native_file_load;
static NativeFileLoadFinish native_file_load_finish;
static gboolean native_enabled;

static void
load_native(void)
{
	static gsize initialized;

	if (g_once_init_enter(&initialized)) {
		const char *mode = g_getenv("SIT_ASYNC");
		GModule *module = g_module_open(NULL, G_MODULE_BIND_LAZY);

		if (module) {
			g_module_symbol(module, "sit_task_run", (gpointer *)&native_run);
			g_module_symbol(module, "sit_task_run_finish", (gpointer *)&native_run_finish);
			g_module_symbol(module, "sit_widget_get_scope", (gpointer *)&native_widget_scope);
			g_module_symbol(module, "sit_scope_get_cancellable", (gpointer *)&native_scope_cancellable);
			g_module_symbol(module, "sit_stream_new", (gpointer *)&native_stream_new);
			g_module_symbol(module, "sit_stream_push", (gpointer *)&native_stream_push);
			g_module_symbol(module, "sit_stream_close", (gpointer *)&native_stream_close);
			g_module_symbol(module, "sit_stream_next", (gpointer *)&native_stream_next);
			g_module_symbol(module, "sit_stream_next_finish", (gpointer *)&native_stream_next_finish);
			g_module_symbol(module, "sit_file_load_async", (gpointer *)&native_file_load);
			g_module_symbol(module, "sit_file_load_finish", (gpointer *)&native_file_load_finish);
			g_module_close(module);
		}
		native_enabled = native_run && native_run_finish && native_widget_scope &&
			native_scope_cancellable && native_stream_new && native_stream_push &&
			native_stream_close && native_stream_next && native_stream_next_finish &&
			g_strcmp0(mode, "off") != 0;
		g_once_init_leave(&initialized, 1);
	}
}

gboolean
singularity_async_native(void)
{
	load_native();
	return native_enabled;
}

typedef struct {
	SingularityAsyncWork work;
	gpointer target;
	GDestroyNotify target_destroy;
	int qos;
} Work;

static void
work_free(gpointer data)
{
	Work *work = data;

	if (work->target_destroy)
		work->target_destroy(work->target);
	g_free(work);
}

static void
run_in_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancellable)
{
	Work *work = data;
	GError *error = NULL;
	gpointer result;

	if (g_task_return_error_if_cancelled(task))
		return;
	int tid = singularity_background_current_tid();
	int normal_nice = singularity_background_nice_of(tid);
	gboolean background = work->qos == 3;
	if (background)
		singularity_background_apply(tid, TRUE, TRUE, normal_nice);
	result = work->work(cancellable, work->target, &error);
	if (background)
		singularity_background_apply(tid, TRUE, FALSE, normal_nice);
	if (error)
		g_task_return_error(task, error);
	else
		g_task_return_pointer(task, result, NULL);
}

static const int fallback_priority[] = {
	G_PRIORITY_HIGH_IDLE + 21,
	G_PRIORITY_DEFAULT_IDLE,
	G_PRIORITY_DEFAULT_IDLE + 10,
	G_PRIORITY_LOW,
};

void
singularity_async_submit(int qos, SingularityAsyncWork work, gpointer work_target,
	GDestroyNotify work_target_destroy, GCancellable *cancellable,
	GAsyncReadyCallback callback, gpointer user_data)
{
	Work *data;
	GTask *task;

	qos = CLAMP(qos, 0, 3);
	if (singularity_async_native()) {
		native_run(NULL, qos, NULL, work, work_target, work_target_destroy,
			cancellable, callback, user_data);
		return;
	}

	data = g_new0(Work, 1);
	data->work = work;
	data->target = work_target;
	data->target_destroy = work_target_destroy;
	data->qos = qos;
	task = g_task_new(NULL, cancellable, callback, user_data);
	g_task_set_source_tag(task, singularity_async_submit);
	g_task_set_priority(task, fallback_priority[qos]);
	g_task_set_task_data(task, data, work_free);
	g_task_run_in_thread(task, run_in_thread);
	g_object_unref(task);
}

gpointer
singularity_async_submit_finish(GAsyncResult *result, GError **error)
{
	if (G_IS_TASK(result) && g_task_get_source_tag(G_TASK(result)) == singularity_async_submit)
		return g_task_propagate_pointer(G_TASK(result), error);
	return native_run_finish(result, error);
}

static void
widget_destroyed(GtkWidget *widget, GCancellable *cancellable)
{
	g_cancellable_cancel(cancellable);
}

static void
widget_cancellable_free(gpointer data)
{
	g_cancellable_cancel(data);
	g_object_unref(data);
}

GCancellable *
singularity_async_widget_cancellable(GtkWidget *widget)
{
	static GQuark quark;
	GCancellable *cancellable;

	g_return_val_if_fail(GTK_IS_WIDGET(widget), NULL);

	if (singularity_async_native())
		return native_scope_cancellable(native_widget_scope(widget));

	if (!quark)
		quark = g_quark_from_static_string("singularity-async-scope");
	cancellable = g_object_get_qdata(G_OBJECT(widget), quark);
	if (!cancellable) {
		cancellable = g_cancellable_new();
		g_object_set_qdata_full(G_OBJECT(widget), quark, cancellable, widget_cancellable_free);
		g_signal_connect(widget, "destroy", G_CALLBACK(widget_destroyed), cancellable);
	}
	return cancellable;
}

typedef struct {
	GMutex lock;
	GPtrArray *items;
	gboolean closed;
	GError *error;
	GTask *waiter;
	GCancellable *waiter_cancellable;
	gulong waiter_handler;
	guint idle;
	gint refs;
} Stream;

static Stream *
stream_ref(Stream *stream)
{
	g_atomic_int_inc(&stream->refs);
	return stream;
}

static void
stream_unref(gpointer data)
{
	Stream *stream = data;

	if (!g_atomic_int_dec_and_test(&stream->refs))
		return;
	g_ptr_array_unref(stream->items);
	g_clear_error(&stream->error);
	g_mutex_clear(&stream->lock);
	g_free(stream);
}

static gboolean
stream_deliver(gpointer data)
{
	Stream *stream = data;
	GTask *task = NULL;
	GPtrArray *batch = NULL;
	GError *error = NULL;
	GCancellable *cancellable = NULL;
	gulong handler = 0;

	g_mutex_lock(&stream->lock);
	stream->idle = 0;
	if (stream->waiter && (stream->items->len > 0 || stream->closed)) {
		task = g_steal_pointer(&stream->waiter);
		cancellable = g_steal_pointer(&stream->waiter_cancellable);
		handler = stream->waiter_handler;
		stream->waiter_handler = 0;
		if (stream->items->len > 0) {
			batch = g_steal_pointer(&stream->items);
			stream->items = g_ptr_array_new_with_free_func(g_object_unref);
		} else if (stream->error) {
			error = g_error_copy(stream->error);
		}
	}
	g_mutex_unlock(&stream->lock);

	if (cancellable) {
		g_cancellable_disconnect(cancellable, handler);
		g_object_unref(cancellable);
	}
	if (task) {
		if (error)
			g_task_return_error(task, error);
		else
			g_task_return_pointer(task, batch, (GDestroyNotify)g_ptr_array_unref);
		g_object_unref(task);
	}
	return G_SOURCE_REMOVE;
}

static void
stream_schedule_locked(Stream *stream)
{
	GSource *source;

	if (!stream->waiter || stream->idle || (stream->items->len == 0 && !stream->closed))
		return;
	source = g_idle_source_new();
	g_source_set_priority(source, G_PRIORITY_HIGH_IDLE + 21);
	g_source_set_callback(source, stream_deliver, stream_ref(stream), stream_unref);
	stream->idle = g_source_attach(source, NULL);
	g_source_unref(source);
}

gpointer
singularity_async_stream_new(void)
{
	Stream *stream;

	if (singularity_async_native())
		return native_stream_new();

	stream = g_new0(Stream, 1);
	g_mutex_init(&stream->lock);
	stream->items = g_ptr_array_new_with_free_func(g_object_unref);
	stream->refs = 1;
	return stream;
}

void
singularity_async_stream_free(gpointer stream)
{
	if (singularity_async_native())
		g_object_unref(stream);
	else
		stream_unref(stream);
}

void
singularity_async_stream_push(gpointer data, GObject *item)
{
	Stream *stream = data;

	if (singularity_async_native()) {
		native_stream_push(data, item);
		return;
	}

	g_mutex_lock(&stream->lock);
	if (stream->closed) {
		g_mutex_unlock(&stream->lock);
		g_object_unref(item);
		return;
	}
	g_ptr_array_add(stream->items, item);
	stream_schedule_locked(stream);
	g_mutex_unlock(&stream->lock);
}

void
singularity_async_stream_close(gpointer data, const GError *error)
{
	Stream *stream = data;

	if (singularity_async_native()) {
		native_stream_close(data, error);
		return;
	}

	g_mutex_lock(&stream->lock);
	if (!stream->closed) {
		stream->closed = TRUE;
		if (error)
			stream->error = g_error_copy(error);
		stream_schedule_locked(stream);
	}
	g_mutex_unlock(&stream->lock);
}

static void
stream_waiter_cancelled(GCancellable *cancellable, gpointer data)
{
	GTask *task = data;
	Stream *stream = g_task_get_task_data(task);
	gboolean mine;

	g_mutex_lock(&stream->lock);
	mine = stream->waiter == task;
	if (mine) {
		stream->waiter = NULL;
		g_clear_object(&stream->waiter_cancellable);
		stream->waiter_handler = 0;
	}
	g_mutex_unlock(&stream->lock);
	if (mine) {
		g_task_return_error_if_cancelled(task);
		g_object_unref(task);
	}
}

void
singularity_async_stream_next(gpointer data, GCancellable *cancellable,
	GAsyncReadyCallback callback, gpointer user_data)
{
	Stream *stream = data;
	GTask *task;
	gulong handler = 0;
	gboolean busy;

	if (singularity_async_native()) {
		native_stream_next(data, cancellable, callback, user_data);
		return;
	}

	task = g_task_new(NULL, cancellable, callback, user_data);
	g_task_set_source_tag(task, singularity_async_stream_next);
	g_task_set_check_cancellable(task, FALSE);
	g_task_set_task_data(task, stream_ref(stream), stream_unref);

	if (cancellable)
		handler = g_cancellable_connect(cancellable, G_CALLBACK(stream_waiter_cancelled),
			g_object_ref(task), g_object_unref);

	g_mutex_lock(&stream->lock);
	busy = stream->waiter != NULL;
	if (!busy) {
		stream->waiter = task;
		if (cancellable) {
			stream->waiter_cancellable = g_object_ref(cancellable);
			stream->waiter_handler = handler;
			handler = 0;
		}
		stream_schedule_locked(stream);
	}
	g_mutex_unlock(&stream->lock);

	if (busy) {
		if (handler)
			g_cancellable_disconnect(cancellable, handler);
		g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_PENDING, "A read is already pending");
		g_object_unref(task);
		return;
	}
	if (cancellable && g_cancellable_is_cancelled(cancellable))
		stream_waiter_cancelled(cancellable, task);
}

GPtrArray *
singularity_async_stream_next_finish(GAsyncResult *result, GError **error)
{
	GObject *source;
	GPtrArray *batch;

	if (G_IS_TASK(result) && g_task_get_source_tag(G_TASK(result)) == singularity_async_stream_next)
		return g_task_propagate_pointer(G_TASK(result), error);
	source = g_async_result_get_source_object(result);
	batch = native_stream_next_finish(source, result, error);
	g_clear_object(&source);
	return batch;
}

static void
bytes_loaded(GObject *source, GAsyncResult *result, gpointer data)
{
	GTask *task = data;
	GError *error = NULL;
	GBytes *bytes = g_file_load_bytes_finish(G_FILE(source), result, NULL, &error);

	if (error)
		g_task_return_error(task, error);
	else
		g_task_return_pointer(task, bytes, (GDestroyNotify)g_bytes_unref);
	g_object_unref(task);
}

void
singularity_async_load(GFile *file, int qos, GCancellable *cancellable,
	GAsyncReadyCallback callback, gpointer user_data)
{
	GTask *task;

	qos = CLAMP(qos, 0, 3);
	if (singularity_async_native() && native_file_load && native_file_load_finish) {
		native_file_load(file, qos, cancellable, callback, user_data);
		return;
	}

	task = g_task_new(file, cancellable, callback, user_data);
	g_task_set_source_tag(task, singularity_async_load);
	g_file_load_bytes_async(file, cancellable, bytes_loaded, task);
}

GBytes *
singularity_async_load_finish(GAsyncResult *result, GError **error)
{
	GObject *file;
	GBytes *bytes;

	if (G_IS_TASK(result) && g_task_get_source_tag(G_TASK(result)) == singularity_async_load)
		return g_task_propagate_pointer(G_TASK(result), error);
	file = g_async_result_get_source_object(result);
	bytes = native_file_load_finish(G_FILE(file), result, error);
	g_object_unref(file);
	return bytes;
}

gboolean
singularity_async_native_io(void)
{
	return singularity_async_native() && native_file_load && native_file_load_finish;
}
