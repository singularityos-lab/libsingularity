using Gtk;
using Peas;

namespace Singularity {

    /**
     * Describes the app being right-clicked on the dock.
     */
    public class DockContextMenuRequest : Object {
        public string app_id { get; construct; }
        public string? display_name { get; construct; }
        public bool is_running { get; construct; }
        public bool is_pinned { get; construct; }
        public int window_count { get; construct; }

        public DockContextMenuRequest(string app_id, string? display_name,
                                      bool is_running, bool is_pinned, int window_count) {
            Object(app_id: app_id, display_name: display_name,
                   is_running: is_running, is_pinned: is_pinned,
                   window_count: window_count);
        }
    }

    /**
     * Interface for plugins that add items to dock context menus.
     */
    public interface DockContextMenuProvider : Object {
        /**
         * Called when a dock icon is right-clicked.
         * Use menu.add_item() or menu.add_widget() to add entries.
         * Return true if items were added, false otherwise.
         */
        public abstract bool populate_context_menu(Singularity.Widgets.ContextMenu menu,
                                                    DockContextMenuRequest request);
    }

    /**
     * Interface for plugins that extend a dock item's appearance: override
     * its icon (e.g. album art) and/or inject widgets in the suffix slot
     * shown next to the icon when the user hovers (or pins) the dock entry.
     *
     * Extensions are queried per app_id during a dock refresh. Emit
     * `changed(app_id)` whenever the icon or the widget for that app needs
     * to be rebuilt; the dock will rerun matches / get_icon_override /
     * create_suffix_widget.
     */
    public interface DockItemExtension : Object {
        /** Emitted when the appearance for `app_id` may have changed. Empty string = all. */
        public signal void changed(string app_id);

        /** Return true if this extension is currently active for `app_id`. */
        public abstract bool matches(string app_id);

        /**
         * Optional icon override. Return a `Gdk.Paintable` to replace the
         * default app icon (used for album art), or `null` to keep the
         * default icon. The dock automatically composes the original app
         * icon as a small badge in the bottom-right corner when overridden.
         */
        public abstract Gdk.Paintable? get_icon_override(string app_id);

        /**
         * Optional widget to inject in the dock item's suffix slot (to the
         * right of the icon, inside the rounded "pill" container). Return
         * `null` for no widget. The dock reveals this widget on hover, and
         * keeps it open if the user toggled "Keep expanded" on the item.
         */
        public abstract Gtk.Widget? create_suffix_widget(string app_id);

        /**
         * Optional widget overlaid ON TOP of the dock icon - usually a
         * small badge at the bottom-centre showing a count or status dot.
         * Default impl returns null. Use this instead of a suffix widget
         * for short numeric / state info that should always be visible
         * (the suffix is hidden until hover), without taking horizontal
         * space.
         *
         * The widget is positioned by the dock at bottom-centre via halign/
         * valign + the `.dock-icon-badge` CSS class. Plugins should keep it
         * small (under ~24px wide) - anything bigger belongs in the suffix.
         */
        public virtual Gtk.Widget? create_icon_overlay(string app_id) { return null; }
    }

    /**
     * Grid footprint of an OverviewWidget instance. Cells are measured in
     * the overview grid's natural unit (one app icon = 1×1).
     */
    public struct WidgetSize {
        public int w;
        public int h;
        public WidgetSize(int width, int height) { w = width; h = height; }
    }

    /**
     * A widget that can be placed on the overview grid alongside app icons.
     * Providers come from two places:
     *
     *   1. Peas plugins (third-party): a .so + .plugin file in the usual
     *      plugin search path. The plugin's activate() calls
     *      `PluginContext.add_overview_widget(provider)`.
     *
     *   2. libsingularity-bundled apps (first-party): a .widget manifest in
     *      $XDG_DATA_DIRS/singularity/widgets/ describing the provider, and
     *      an optional .so loaded by the overview itself - NOT by the app
     *      process. This is what makes "the music widget works offline"
     *      possible: the widget code lives in libmusic-widget.so loaded by
     *      the overview, talking to the app via DBus when it's running and
     *      falling back to a cached / informative state when it isn't.
     *
     * Widgets choose their own size from `supported_sizes` (e.g. 2×1 row,
     * 2×2 card). The overview wraps the returned Gtk.Widget in chrome
     * (drag handle, "remove", "configure") - providers focus on content.
     */
    public interface OverviewWidgetProvider : Object {
        /** Stable identifier, e.g. "music.now-playing". */
        public abstract string id { get; }
        /** App or plugin that owns this widget - used for grouping in pickers. */
        public abstract string provider_id { get; }
        /** Human-visible name in the widget picker. */
        public abstract string display_name { get; }
        /** Icon name used in the widget picker. */
        public abstract string icon_name { get; }
        /** Sizes this widget can be instantiated at. Must be non-empty. */
        public abstract WidgetSize[] supported_sizes { get; }
        /**
         * Build a new instance. `instance_id` is unique per layout slot;
         * `config` is the per-instance Variant previously stored, or null
         * for a fresh instance.
         */
        public abstract Gtk.Widget create_instance(string instance_id,
                                                   WidgetSize size,
                                                   Variant? config);
        /** Open a configuration dialog for this instance. Optional. */
        public virtual void configure_instance(string instance_id) {}
    }

    /**
     * Interface that all Singularity plugins must implement.
     */
    public interface Plugin : Object {
        /**
         * Called when the plugin is loaded and should set itself up.
         *
         * @param context Provides access to shell APIs (panel, sidebar, notifications, ..).
         */
        public abstract void activate(PluginContext context);

        /** Called when the plugin is about to be unloaded; release all resources. */
        public abstract void deactivate();

        /**
         * Returns a settings widget for this plugin, or `null` if it has none.
         *
         * The returned widget is displayed in the Singularity Settings app under
         * the plugin's entry.
         */
        public abstract Gtk.Widget? get_settings_widget();
    }

    /**
     * Lightweight workspace descriptor passed to plugins via PluginContext.
     */
    public class WorkspaceDescriptor : Object {
        public string name { get; construct; }
        public bool active { get; construct; }
        public int index { get; construct; }

        public WorkspaceDescriptor(string name, bool active, int index) {
            Object(name: name, active: active, index: index);
        }
    }

    /**
     * Provides plugins with safe access to the desktop environment.
     */
    public class PluginContext : Object {
        /** Emitted when a plugin adds a widget to the top panel. */
        public signal void panel_widget_added(Gtk.Widget widget, Gtk.Align alignment);
        /** Emitted when a plugin removes a widget from the top panel. */
        public signal void panel_widget_removed(Gtk.Widget widget);

        /** Emitted when a plugin adds a widget to the sidebar (SystemView). */
        public signal void sidebar_widget_added(Gtk.Widget widget);
        /** Emitted when a plugin removes a widget from the sidebar. */
        public signal void sidebar_widget_removed(Gtk.Widget widget);

        /** Emitted when a plugin adds a widget to the right of the clock button. */
        public signal void clock_suffix_widget_added(Gtk.Widget widget);
        /** Emitted when a plugin removes a widget from the right of the clock button. */
        public signal void clock_suffix_widget_removed(Gtk.Widget widget);

        /** Emitted when a plugin registers a dock context menu provider. */
        public signal void dock_context_menu_provider_added(DockContextMenuProvider provider);
        /** Emitted when a plugin unregisters a dock context menu provider. */
        public signal void dock_context_menu_provider_removed(DockContextMenuProvider provider);

        public PluginContext() {
        }

        /**
         * Adds a widget to the top panel.
         *
         * @param widget    The widget to add.
         * @param alignment Gtk.Align.START (left), Gtk.Align.CENTER (centre),
         *                  or Gtk.Align.END (right).
         */
        public void add_panel_widget(Gtk.Widget widget, Gtk.Align alignment) {
            panel_widget_added(widget, alignment);
        }

        /** Removes a previously added widget from the panel. */
        public void remove_panel_widget(Gtk.Widget widget) {
            panel_widget_removed(widget);
        }

        /**
         * Adds a widget to the sidebar (SystemView).
         *
         * @param widget The widget to add.
         */
        public void add_sidebar_widget(Gtk.Widget widget) {
            sidebar_widget_added(widget);
        }

        /** Removes a previously added widget from the sidebar. */
        public void remove_sidebar_widget(Gtk.Widget widget) {
            sidebar_widget_removed(widget);
        }

        /** Adds a widget to the right of the clock button in the panel. */
        public void add_clock_suffix_widget(Gtk.Widget widget) {
            clock_suffix_widget_added(widget);
        }

        /** Removes a previously added clock-suffix widget. */
        public void remove_clock_suffix_widget(Gtk.Widget widget) {
            clock_suffix_widget_removed(widget);
        }

        /**
         * Registers a dock context menu provider.
         * The dock will call provider.populate_context_menu() for each
         * right-clicked app, letting the plugin insert custom items.
         */
        public void add_dock_context_menu_provider(DockContextMenuProvider provider) {
            dock_context_menu_provider_added(provider);
        }

        /** Unregisters a dock context menu provider. */
        public void remove_dock_context_menu_provider(DockContextMenuProvider provider) {
            dock_context_menu_provider_removed(provider);
        }

        /** Emitted when a plugin registers a dock item extension. */
        public signal void dock_item_extension_added(DockItemExtension extension);
        /** Emitted when a plugin unregisters a dock item extension. */
        public signal void dock_item_extension_removed(DockItemExtension extension);

        /**
         * Registers a dock item extension. The extension can override the
         * icon and/or inject a hover-revealed widget on the right of any
         * dock item it matches.
         */
        public void add_dock_item_extension(DockItemExtension extension) {
            dock_item_extension_added(extension);
        }

        /** Unregisters a previously added dock item extension. */
        public void remove_dock_item_extension(DockItemExtension extension) {
            dock_item_extension_removed(extension);
        }

        /**
         * Emitted whenever the desktop's notification daemon receives a
         * Notify() call. Plugins can subscribe to react to specific senders
         * (e.g. Telegram, Slack) without needing direct access to those apps.
         *
         * `id` is the notification id assigned by the daemon - plugins can
         * pass it back to dismiss_notification() to close that specific
         * notification (popup + history entry).
         */
        public signal void notification_received(uint id, string app_name, string summary,
                                                 string body, string icon);

        /** Called by the shell to fan out notifications to plugins. */
        public void emit_notification(uint id, string app_name, string summary,
                                       string body, string icon) {
            notification_received(id, app_name, summary, body, icon);
        }

        /**
         * Request the shell's notification daemon to close (dismiss) the
         * notification with the given id. Used by plugins that "consume" the
         * notification by surfacing it in another UI (dock bubble, sidebar).
         */
        public signal void notification_dismiss_requested(uint id);

        public void dismiss_notification(uint id) {
            notification_dismiss_requested(id);
        }

        /**
         * Emitted when a notification is closed - either dismissed by the user
         * in the notification centre, expired naturally, or programmatically
         * closed. Plugins use this to keep their derived state (unread counts,
         * dock badges) in sync with the actual notification daemon.
         */
        public signal void notification_closed(uint id, uint reason);

        public void emit_notification_closed(uint id, uint reason) {
            notification_closed(id, reason);
        }

        /**
         * Sends a desktop notification via the default GLib.Application.
         *
         * @param summary Short title of the notification.
         * @param body    Longer description shown below the title.
         */
        public void notify(string summary, string body) {
            var notification = new GLib.Notification(summary);
            notification.set_body(body);
             var app = GLib.Application.get_default();
             if (app != null) {
                 app.send_notification("plugin-notify", notification);
             }
        }

        // ── Workspace API ─────────────────────────────────────────────────────
        /** Emitted when the workspace list changes. */
        public signal void workspaces_changed();
        /** Emitted when a plugin requests switching to a workspace by index. */
        public signal void workspace_switch_requested(int index);

        private List<WorkspaceDescriptor> _workspaces = new List<WorkspaceDescriptor>();

        /** Returns a copy of the current workspace snapshot. */
        public List<WorkspaceDescriptor> get_workspaces() {
            return _workspaces.copy_deep((ws) => new WorkspaceDescriptor(
                ((WorkspaceDescriptor)ws).name,
                ((WorkspaceDescriptor)ws).active,
                ((WorkspaceDescriptor)ws).index));
        }

        /** Called by the main shell to push a workspace update to plugins. */
        public void update_workspaces(List<WorkspaceDescriptor> descs) {
            _workspaces = descs.copy_deep((ws) => new WorkspaceDescriptor(
                ((WorkspaceDescriptor)ws).name,
                ((WorkspaceDescriptor)ws).active,
                ((WorkspaceDescriptor)ws).index));
            workspaces_changed();
        }

        /**
         * Requests switching to the workspace at the given zero-based index.
         *
         * @param index Zero-based index of the target workspace.
         */
        public void switch_workspace(int index) {
            workspace_switch_requested(index);
        }

        // ── Overview widgets ──────────────────────────────────────────────
        public signal void overview_widget_added(OverviewWidgetProvider provider);
        public signal void overview_widget_removed(OverviewWidgetProvider provider);

        public void add_overview_widget(OverviewWidgetProvider provider) {
            overview_widget_added(provider);
        }
        public void remove_overview_widget(OverviewWidgetProvider provider) {
            overview_widget_removed(provider);
        }

        // ── Search providers ──────────────────────────────────────────────
        public signal void search_provider_added(SearchProvider provider);
        public signal void search_provider_removed(SearchProvider provider);

        public void add_search_provider(SearchProvider provider) {
            search_provider_added(provider);
        }
        public void remove_search_provider(SearchProvider provider) {
            search_provider_removed(provider);
        }

        // ── VPN providers (Tailscale and other non-NetworkManager backends) ─
        public signal void vpn_provider_added(VpnProvider provider);
        public signal void vpn_provider_removed(VpnProvider provider);

        /**
         * Registers a VPN provider. Its connections appear in the Network
         * settings page alongside the built-in NetworkManager VPNs, with
         * connect / disconnect (and optionally remove) controls.
         */
        public void add_vpn_provider(VpnProvider provider) {
            vpn_provider_added(provider);
        }
        public void remove_vpn_provider(VpnProvider provider) {
            vpn_provider_removed(provider);
        }

        // ── Shell surfaces (replaceable dock / panel / overview / …) ───────
        public signal void shell_surface_provider_added(ShellSurfaceProvider provider);
        public signal void shell_surface_provider_removed(ShellSurfaceProvider provider);

        public void add_shell_surface_provider(ShellSurfaceProvider provider) {
            shell_surface_provider_added(provider);
        }
        public void remove_shell_surface_provider(ShellSurfaceProvider provider) {
            shell_surface_provider_removed(provider);
        }
    }
}
