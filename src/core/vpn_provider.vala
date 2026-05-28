using GLib;

namespace Singularity {

    /** Link state of a VPN entry, normalized across providers. */
    public enum VpnState {
        DISCONNECTED,
        CONNECTING,
        CONNECTED
    }

    /**
     * A single VPN connection exposed by a VpnProvider. The owning provider
     * keeps it alive; the Network page holds a ref only while its row is
     * shown and calls the async actions in response to the user.
     */
    public interface VpnConnection : Object {
        /** Stable identifier, unique within the owning provider. */
        public abstract string id { get; }
        /** Human-visible name shown in the VPN list. */
        public abstract string display_name { get; }
        /** Current link state. */
        public abstract VpnState state { get; }
        /** Symbolic icon name for the row. */
        public abstract string icon_name { get; }
        /** Whether the UI should offer a "Remove" action for this entry. */
        public abstract bool can_remove { get; }

        /** Bring the connection up. Returns true on success. */
        public abstract async bool activate() throws Error;
        /** Bring the connection down. Returns true on success. */
        public abstract async bool deactivate() throws Error;
        /** Permanently remove the connection. Only invoked when `can_remove`. */
        public abstract async bool remove() throws Error;
    }

    /**
     * A source of VPN connections shown in the Network settings page.
     *
     * The built-in NetworkManager backend is intentionally *not* a provider
     * (it predates this interface and is rendered directly). Providers exist
     * so plugins can add VPN technologies NetworkManager does not manage,
     * e.g. Tailscale, which runs as its own daemon rather than as an NM
     * connection.
     *
     * Register from a plugin's `activate()` via
     * `PluginContext.add_vpn_provider()`. The Network page lists every
     * registered provider's connections alongside the NM ones and subscribes
     * to `changed` to refresh.
     */
    public interface VpnProvider : Object {
        /** Stable identifier, e.g. "tailscale". */
        public abstract string id { get; }
        /** Human-visible name of the backend (used in tooltips / grouping). */
        public abstract string display_name { get; }

        /** Current snapshot of the provider's connections. */
        public abstract GLib.List<VpnConnection> get_connections();

        /** Emitted when the connection list or any connection state changes. */
        public signal void changed();
        /** Emitted to surface the result of a user action (shown as a dialog). */
        public signal void action_result(bool success, string message);
    }

    /**
     * Global registry of VPN providers. Same shape as
     * SearchProviderRegistry: plugins register through PluginContext (the
     * signals are funnelled here in main), and the Network page subscribes to
     * `added`/`removed` and reads `list()`.
     */
    public class VpnProviderRegistry : Object {
        private static VpnProviderRegistry? _instance = null;
        public static VpnProviderRegistry get_default() {
            if (_instance == null) _instance = new VpnProviderRegistry();
            return _instance;
        }

        public signal void added(VpnProvider provider);
        public signal void removed(VpnProvider provider);

        private GLib.GenericArray<VpnProvider> _providers =
            new GLib.GenericArray<VpnProvider>();

        public void add(VpnProvider p) {
            for (int i = 0; i < _providers.length; i++)
                if (_providers[i].id == p.id) return; // dedup by id
            _providers.add(p);
            added(p);
        }

        public void remove(VpnProvider p) {
            for (int i = 0; i < _providers.length; i++) {
                if (_providers[i] == p) {
                    _providers.remove_index(i);
                    removed(p);
                    return;
                }
            }
        }

        public VpnProvider[] list() {
            var r = new VpnProvider[_providers.length];
            for (int i = 0; i < _providers.length; i++) r[i] = _providers[i];
            return r;
        }
    }
}
