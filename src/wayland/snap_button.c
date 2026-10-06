#define _POSIX_C_SOURCE 200809L

#include "snap_button.h"

#include <string.h>
#include <wayland-client.h>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

#include "singularity-snap-unstable-v1-client-protocol.h"

#ifdef GDK_WINDOWING_WAYLAND

static struct zsingularity_snap_manager_v1 *cached_manager;
static struct wl_display *cached_display;
static const char *entered_key = "singularity-snap-button-surface";

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	struct zsingularity_snap_manager_v1 **out = data;
	if (strcmp(interface,
			zsingularity_snap_manager_v1_interface.name) != 0
			|| version < 2) {
		return;
	}
	*out = wl_registry_bind(registry, name,
		&zsingularity_snap_manager_v1_interface, 2);
}

static void
registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	(void)data;
	(void)registry;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static struct zsingularity_snap_manager_v1 *
get_manager(struct wl_display *display)
{
	if (display == cached_display) {
		return cached_manager;
	}

	struct zsingularity_snap_manager_v1 *found = NULL;
	struct wl_event_queue *queue = wl_display_create_queue(display);
	if (!queue) {
		return NULL;
	}

	struct wl_registry *registry = wl_display_get_registry(display);
	wl_proxy_set_queue((struct wl_proxy *)registry, queue);
	wl_registry_add_listener(registry, &registry_listener, &found);
	wl_display_roundtrip_queue(display, queue);
	if (found) {
		wl_proxy_set_queue((struct wl_proxy *)found, NULL);
	}
	wl_registry_destroy(registry);
	wl_event_queue_destroy(queue);

	cached_display = display;
	cached_manager = found;
	return cached_manager;
}

static struct zsingularity_snap_manager_v1 *
manager_for_widget(GtkWidget *widget, struct wl_surface **surface_out)
{
	GdkDisplay *gdk_display = gtk_widget_get_display(widget);
	if (!GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
		return NULL;
	}
	GtkNative *native = gtk_widget_get_native(widget);
	if (!native || !GTK_IS_WINDOW(native)) {
		return NULL;
	}
	GdkSurface *gdk_surface = gtk_native_get_surface(native);
	if (!gdk_surface || !GDK_IS_WAYLAND_SURFACE(gdk_surface)) {
		return NULL;
	}
	struct wl_surface *surface = gdk_wayland_surface_get_wl_surface(
		GDK_WAYLAND_SURFACE(gdk_surface));
	if (!surface) {
		return NULL;
	}
	struct wl_display *display = gdk_wayland_display_get_wl_display(
		GDK_WAYLAND_DISPLAY(gdk_display));
	if (surface_out) {
		*surface_out = surface;
	}
	return get_manager(display);
}

#endif

gboolean
singularity_snap_button_available(GtkWidget *widget)
{
#ifdef GDK_WINDOWING_WAYLAND
	GdkDisplay *gdk_display = gtk_widget_get_display(widget);
	if (!GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
		return FALSE;
	}
	return get_manager(gdk_wayland_display_get_wl_display(
		GDK_WAYLAND_DISPLAY(gdk_display))) != NULL;
#else
	(void)widget;
	return FALSE;
#endif
}

void
singularity_snap_button_enter(GtkWidget *widget)
{
#ifdef GDK_WINDOWING_WAYLAND
	struct wl_surface *surface = NULL;
	struct zsingularity_snap_manager_v1 *manager =
		manager_for_widget(widget, &surface);
	if (!manager) {
		return;
	}
	GtkNative *native = gtk_widget_get_native(widget);
	graphene_rect_t bounds;
	if (!gtk_widget_compute_bounds(widget, GTK_WIDGET(native), &bounds)) {
		return;
	}
	double sx = 0;
	double sy = 0;
	gtk_native_get_surface_transform(native, &sx, &sy);
	int x = (int)(bounds.origin.x + sx);
	int y = (int)(bounds.origin.y + sy);
	int width = (int)bounds.size.width;
	int height = (int)bounds.size.height;
	if (width < 1 || height < 1) {
		return;
	}
	zsingularity_snap_manager_v1_button_enter(manager, surface, x, y,
		width, height);
	g_object_set_data(G_OBJECT(widget), entered_key, surface);
	wl_display_flush(cached_display);
#else
	(void)widget;
#endif
}

void
singularity_snap_button_leave(GtkWidget *widget)
{
#ifdef GDK_WINDOWING_WAYLAND
	struct wl_surface *entered = g_object_steal_data(G_OBJECT(widget),
		entered_key);
	if (!entered) {
		return;
	}
	struct wl_surface *surface = NULL;
	struct zsingularity_snap_manager_v1 *manager =
		manager_for_widget(widget, &surface);
	if (!manager || surface != entered) {
		return;
	}
	zsingularity_snap_manager_v1_button_leave(manager, surface);
	wl_display_flush(cached_display);
#else
	(void)widget;
#endif
}
