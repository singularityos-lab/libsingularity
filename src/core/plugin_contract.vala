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
    }
}
