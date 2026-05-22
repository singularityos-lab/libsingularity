using GLib;

namespace Singularity {

    /**
     * The replaceable surfaces of the shell. A plugin can claim a role to
     * either fill it (content-injection) or own it outright
     * (surface-ownership).
     */
    public enum ShellRole {
        DOCK,
        PANEL,
        OVERVIEW,
        WORKSPACES,
        LAUNCHER,
        NOTIFICATIONS;

        public string to_key() {
            switch (this) {
                case DOCK:          return "dock";
                case PANEL:         return "panel";
                case OVERVIEW:      return "overview";
                case WORKSPACES:    return "workspaces";
                case LAUNCHER:      return "launcher";
                case NOTIFICATIONS: return "notifications";
                default:            return "unknown";
            }
        }

        public static ShellRole from_key(string k) {
            switch (k) {
                case "dock":          return DOCK;
                case "panel":         return PANEL;
                case "overview":      return OVERVIEW;
                case "workspaces":    return WORKSPACES;
                case "launcher":      return LAUNCHER;
                case "notifications": return NOTIFICATIONS;
                default:              return DOCK;
            }
        }
    }

    public enum ShellSurfaceMode {
        /**
         * The shell keeps the layer-shell window (anchoring, exclusive
         * zone, multi-monitor, cross-surface coordination) and embeds the
         * provider's content widget. Lowest effort; the provider can't
         * redefine the layer geometry.
         */
        CONTENT_INJECTION,
        /**
         * The provider owns its own layer-shell surface end to end. The
         * shell suppresses its built-in for the role and just tells the
         * provider when to show/hide. Maximum freedom; the provider
         * reimplements the plumbing.
         */
        SURFACE_OWNERSHIP
    }

    /**
     * Anchoring hint used by the shell-owned host window in
     * CONTENT_INJECTION mode. Mirrors the built-in surfaces' geometry so a
     * plugin gets sensible placement without owning the window.
     */
    public enum ShellSurfaceAnchor {
        BOTTOM,   // dock-like: anchored to the bottom edge, centred
        TOP,      // panel-like: full-width top strip
        LEFT,
        RIGHT,
        FULLSCREEN // overview-like: covers the whole monitor
    }

    /**
     * A plugin-provided replacement for one of the shell's surfaces.
     *
     * Register via PluginContext.add_shell_surface_provider(). At startup
     * (and whenever the set changes) the shell arbitrates per role: the
     * highest-priority provider for a role wins, the shell suppresses its
     * own built-in for that role, and hands over per `mode`.
     */
    public interface ShellSurfaceProvider : Object {
        /** Which surface this provider replaces. */
        public abstract ShellRole role { get; }
        /** Injection vs full ownership. */
        public abstract ShellSurfaceMode mode { get; }
        /** Higher wins when multiple providers claim the same role. */
        public abstract int priority { get; }

        /**
         * CONTENT_INJECTION: anchoring hint for the shell-owned host window.
         * Ignored in SURFACE_OWNERSHIP mode.
         */
        public virtual ShellSurfaceAnchor anchor {
            get { return ShellSurfaceAnchor.BOTTOM; }
        }

        /**
         * CONTENT_INJECTION: build the content widget embedded by the shell.
         * Called once per monitor the surface is shown on. Return null to
         * decline (the shell falls back to its built-in).
         */
        public virtual Gtk.Widget? create_content(Gdk.Monitor monitor) { return null; }

        /**
         * SURFACE_OWNERSHIP: the shell yields the role - show your surface.
         * `monitor` is the target; called per monitor.
         */
        public virtual void surface_activate(Gdk.Monitor monitor) {}

        /** SURFACE_OWNERSHIP: hide / tear down the surface for `monitor`. */
        public virtual void surface_deactivate(Gdk.Monitor monitor) {}

        /**
         * For toggled surfaces (overview / workspaces / launcher) the shell
         * routes its show/hide request here instead of to the built-in.
         */
        public virtual void toggle() {}
    }

    /**
     * Registry of shell-surface providers. Singleton, mirrors the other
     * plugin registries. The shell subscribes to `changed` to re-arbitrate.
     */
    public class ShellSurfaceRegistry : Object {
        private static ShellSurfaceRegistry? _instance = null;
        public static ShellSurfaceRegistry get_default() {
            if (_instance == null) _instance = new ShellSurfaceRegistry();
            return _instance;
        }

        public signal void changed();

        private GLib.GenericArray<ShellSurfaceProvider> _providers =
            new GLib.GenericArray<ShellSurfaceProvider>();

        public void add(ShellSurfaceProvider p) {
            _providers.add(p);
            changed();
        }

        public void remove(ShellSurfaceProvider p) {
            for (int i = 0; i < _providers.length; i++) {
                if (_providers[i] == p) { _providers.remove_index(i); changed(); return; }
            }
        }

        /** Highest-priority provider that claims `role`, or null. */
        public ShellSurfaceProvider? claimant(ShellRole role) {
            ShellSurfaceProvider? best = null;
            for (int i = 0; i < _providers.length; i++) {
                var p = _providers[i];
                if (p.role != role) continue;
                if (best == null || p.priority > best.priority) best = p;
            }
            return best;
        }

        /** True if any provider claims `role` (built-in should be suppressed). */
        public bool is_claimed(ShellRole role) {
            return claimant(role) != null;
        }
    }
}
