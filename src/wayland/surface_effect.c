#define _POSIX_C_SOURCE 200809L

#include "surface_effect.h"

#include <stdlib.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>
#include <wayland-client.h>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

#include "singularity-blur-unstable-v1-client-protocol.h"

#ifdef GDK_WINDOWING_WAYLAND

struct manager_probe {
	struct zsingularity_blur_manager_v1 *manager;
	uint32_t version;
};

struct surface_effect {
	struct zsingularity_blur_v1 *proxy;

	bool applied;
	uint32_t mode, strength;
	int x, y, width, height;
};

static struct zsingularity_blur_manager_v1 *cached_manager;
static struct wl_display *cached_display;
static uint32_t cached_version;
static const char *effect_data_key = "singularity-surface-effect";
static const char *effect_signal_key = "singularity-surface-effect-signal";

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	struct manager_probe *probe = data;
	if (strcmp(interface,
			zsingularity_blur_manager_v1_interface.name) != 0) {
		return;
	}

	probe->version = version < 3 ? version : 3;
	probe->manager = wl_registry_bind(registry, name,
		&zsingularity_blur_manager_v1_interface, probe->version);
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

static struct zsingularity_blur_manager_v1 *
get_manager(struct wl_display *display)
{
	if (display == cached_display) {
		return cached_manager;
	}

	struct manager_probe probe = {0};
	struct wl_event_queue *queue = wl_display_create_queue(display);
	if (!queue) {
		return NULL;
	}

	struct wl_registry *registry = wl_display_get_registry(display);
	wl_proxy_set_queue((struct wl_proxy *)registry, queue);
	wl_registry_add_listener(registry, &registry_listener, &probe);
	wl_display_roundtrip_queue(display, queue);
	if (probe.manager) {
		wl_proxy_set_queue((struct wl_proxy *)probe.manager, NULL);
	}
	wl_registry_destroy(registry);
	wl_event_queue_destroy(queue);

	cached_display = display;
	cached_manager = probe.manager;
	cached_version = probe.version;
	return cached_manager;
}

static void
destroy_surface_effect(gpointer data)
{
	struct surface_effect *effect = data;
	if (effect->proxy) {
		zsingularity_blur_v1_destroy(effect->proxy);
	}
	free(effect);
}

static void
handle_widget_unrealize(GtkWidget *widget, gpointer data)
{
	(void)data;
	struct surface_effect *effect = g_object_steal_data(
		G_OBJECT(widget), effect_data_key);
	if (effect) {
		destroy_surface_effect(effect);
	}
}

#endif

void
singularity_surface_effect_set(GtkWidget *widget, uint32_t mode,
		int x, int y, int width, int height, uint32_t strength)
{
#ifdef GDK_WINDOWING_WAYLAND
	GdkDisplay *gdk_display = gtk_widget_get_display(widget);
	if (!GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
		return;
	}

	GdkSurface *gdk_surface = gtk_native_get_surface(GTK_NATIVE(widget));
	if (!gdk_surface || !GDK_IS_WAYLAND_SURFACE(gdk_surface)) {
		return;
	}

	struct wl_display *display = gdk_wayland_display_get_wl_display(
		GDK_WAYLAND_DISPLAY(gdk_display));
	struct zsingularity_blur_manager_v1 *manager = get_manager(display);
	if (!manager) {
		return;
	}

	struct wl_surface *surface = gdk_wayland_surface_get_wl_surface(
		GDK_WAYLAND_SURFACE(gdk_surface));
	if (!surface) {
		return;
	}

	struct surface_effect *effect = g_object_get_data(
		G_OBJECT(widget), effect_data_key);
	if (!effect) {
		effect = calloc(1, sizeof(*effect));
		if (!effect) {
			return;
		}
		effect->proxy = zsingularity_blur_manager_v1_get_blur(
			manager, surface);
		if (!effect->proxy) {
			free(effect);
			return;
		}
		g_object_set_data_full(G_OBJECT(widget), effect_data_key,
			effect, destroy_surface_effect);
		if (!g_object_get_data(G_OBJECT(widget), effect_signal_key)) {
			g_signal_connect(widget, "unrealize",
				G_CALLBACK(handle_widget_unrealize), NULL);
			g_object_set_data(G_OBJECT(widget), effect_signal_key,
				GINT_TO_POINTER(1));
		}
	}

	double offset_x, offset_y;
	gtk_native_get_surface_transform(GTK_NATIVE(widget),
		&offset_x, &offset_y);
	x -= (int) floor(offset_x);
	y -= (int) floor(offset_y);
	if (effect->applied && effect->mode == mode
			&& effect->strength == strength && effect->x == x
			&& effect->y == y && effect->width == width
			&& effect->height == height) {
		return;
	}
	effect->applied = true;
	effect->mode = mode;
	effect->strength = strength;
	effect->x = x;
	effect->y = y;
	effect->width = width;
	effect->height = height;

	if (cached_version >= 2) {
		zsingularity_blur_v1_set_mode(effect->proxy, mode);
		if (cached_version >= 3) {
			zsingularity_blur_v1_set_strength(effect->proxy, strength);
		}
		if (width > 0 && height > 0) {
			struct wl_compositor *compositor =
				gdk_wayland_display_get_wl_compositor(
					GDK_WAYLAND_DISPLAY(gdk_display));
			if (compositor) {
				struct wl_region *region =
					wl_compositor_create_region(compositor);
				wl_region_add(region, x, y, width, height);
				zsingularity_blur_v1_set_region(effect->proxy, region);
				wl_region_destroy(region);
			}
		} else {
			zsingularity_blur_v1_set_region(effect->proxy, NULL);
		}
	} else {
		zsingularity_blur_v1_set_radius(effect->proxy,
			mode == 0 ? 0 : 24);
		zsingularity_blur_v1_set_noise(effect->proxy, 0);
	}
	zsingularity_blur_v1_commit(effect->proxy);
	wl_surface_commit(surface);
#else
	(void)widget;
	(void)mode;
	(void)x;
	(void)y;
	(void)width;
	(void)height;
	(void)strength;
#endif
}
