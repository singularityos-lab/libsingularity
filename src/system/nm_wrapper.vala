namespace Singularity {

    /**
     * One physical wired port, connected or not. NM only tells the UI about
     * a port once it has a device object, so "not connected" and "not
     * present" are the same picture to it -- this exists so the Network
     * settings page can list every port a board actually has, cable in or
     * out, rather than only the one currently carrying traffic.
     */
    public class EthernetPortInfo : GLib.Object {
        public string iface { get; private set; }
        public bool connected { get; private set; }

        /** PCI chipset name from the hardware database, e.g. "RTL8125 2.5GbE Controller". Empty until probed. */
        public string chipset { get; private set; default = ""; }

        /** Highest supported base-T link mode, e.g. "2.5 GbE". Empty until probed or unknown. */
        public string capability { get; private set; default = ""; }

        public EthernetPortInfo(string iface, bool connected) {
            this.iface = iface;
            this.connected = connected;
        }

        internal void mark_connected(bool value) {
            connected = value;
        }

        internal void set_details(string chipset, string capability) {
            this.chipset = chipset;
            this.capability = capability;
        }
    }

    public class NetworkManagerWrapper : GLib.Object {
        public bool wifi_enabled { get; private set; default = true; }
        public bool has_wifi { get; private set; default = false; }
        public bool is_airplane_mode { get; private set; default = false; }
        public bool is_wired_connected { get; private set; default = false; }
        public string wifi_icon { get; private set; default = "network-wireless-symbolic"; }
        public string wifi_ssid { get; private set; default = "Disconnected"; }
        public bool vpn_active { get; private set; default = false; }
        public string vpn_name { get; private set; default = ""; }
        public string vpn_icon { get; private set; default = "network-vpn-symbolic"; }
        public DynamicInternetManager dynamic_internet { get; private set; }
        public signal void access_points_changed();
        public signal void state_changed();
        public signal void vpn_state_changed();
        public signal void vpn_connections_changed();
        public signal void vpn_action_result(bool success, string message);

        public bool wifi_hotspot_active { get; private set; default = false; }
        public bool ethernet_sharing_active { get; private set; default = false; }
        public bool has_ethernet { get; private set; default = false; }
        public signal void hotspot_state_changed();
        public signal void sharing_action_result(bool success, string message);

        public signal void ethernet_ports_changed();
        public signal void wifi_connections_changed();

        private const string HOTSPOT_ID = "Singularity Hotspot";
        private const string WIRED_SHARE_ID = "Singularity Wired Sharing";

        public enum VpnLinkState { DISCONNECTED, CONNECTING, CONNECTED }

        private static bool is_vpn_type(string? t) {
            return t == "vpn" || t == "wireguard";
        }

        private string vpn_failure_message(uint reason) {
            switch (reason) {
                case NmActiveReason.LOGIN_FAILED:
                    return "VPN authentication failed";
                case NmActiveReason.NO_SECRETS:
                    return "VPN credentials are missing";
                case NmActiveReason.CONNECT_TIMEOUT:
                case NmActiveReason.SERVICE_START_TIMEOUT:
                    return "VPN connection timed out";
                case NmActiveReason.IP_CONFIG_INVALID:
                    return "The VPN returned an invalid network configuration";
                case NmActiveReason.SERVICE_START_FAILED:
                case NmActiveReason.SERVICE_STOPPED:
                    return "The VPN service could not start";
                default:
                    return "VPN connection failed";
            }
        }

        private NmClient? client;
        private string? wifi_device;
        private GenericArray<string> wifi_devices = new GenericArray<string>();
        private string? ethernet_device;
        private GenericArray<string> ethernet_devices = new GenericArray<string>();
        private GenericArray<EthernetPortInfo> ethernet_ports_list = new GenericArray<EthernetPortInfo>();
        private HashTable<string, EthernetPortInfo> port_of = new HashTable<string, EthernetPortInfo>(str_hash, str_equal);
        private bool wifi_request_in_flight = false;
        private bool wifi_requested_state = false;
        private GLib.Settings desktop_settings;

        public NetworkManagerWrapper() {
            desktop_settings = new GLib.Settings("dev.sinty.desktop");
            dynamic_internet = new DynamicInternetManager();
            dynamic_internet.set_active(
                desktop_settings.get_boolean("dynamic-internet-enabled"));
            init_client.begin();
        }

        public void set_dynamic_internet_enabled(bool enabled) {
            desktop_settings.set_boolean("dynamic-internet-enabled", enabled);
            dynamic_internet.set_active(enabled);
        }

        private static bool listed(GenericArray<string> list, string path, out uint index = null) {
            for (uint i = 0; i < list.length; i++) {
                if (list.get(i) == path) {
                    index = i;
                    return true;
                }
            }
            index = 0;
            return false;
        }

        private async void init_client() {
            try {
                client = yield NmClient.create();
            } catch (Error e) {
                warning("Failed to initialize NetworkManager client: %s", e.message);
                return;
            }
            message("NetworkManager Client initialized");
            dynamic_internet.set_fallback_backend(new NetworkManagerDynamicInternetBackend(client));
            foreach (var d in client.devices()) register_device(d);
            if (wifi_device == null) warning("No WiFi device found!");
            client.properties_changed.connect(on_properties_changed);
            client.object_added.connect((path) => {
                if (client.has_interface(path, NM_DEVICE_IFACE)) {
                    register_device(path);
                    update_state();
                } else if (client.has_interface(path, NM_ACTIVE_IFACE)) {
                    update_vpn_state();
                    refresh_sharing_state();
                }
            });
            client.object_removed.connect(on_object_removed);
            client.active_state_changed.connect(on_active_state);
            client.vpn_state_changed.connect((path, state, reason) => update_vpn_state());
            client.connection_added.connect((conn) => {
                vpn_connections_changed();
                if (conn.get_connection_type() == "802-11-wireless") wifi_connections_changed();
            });
            client.connection_removed.connect((conn) => {
                vpn_connections_changed();
                if (conn.get_connection_type() == "802-11-wireless") wifi_connections_changed();
            });
            client.connection_updated.connect((conn) => {
                if (is_vpn_type(conn.get_connection_type())) vpn_connections_changed();
                if (conn.get_connection_type() == "802-11-wireless") wifi_connections_changed();
                refresh_sharing_state();
            });
            update_state();
            update_vpn_state();
            refresh_sharing_state();
        }

        private void on_active_state(string path, uint state, uint reason) {
            update_vpn_state();
            refresh_sharing_state();
            if (!is_vpn_type(client.active_type(path))) return;
            if (state == NmActiveState.ACTIVATED) {
                vpn_action_result(true, "VPN connected");
            } else if (state == NmActiveState.DEACTIVATED
                && reason != NmActiveReason.NONE
                && reason != NmActiveReason.USER_DISCONNECTED
                && reason != NmActiveReason.CONNECTION_REMOVED) {
                vpn_action_result(false, vpn_failure_message(reason));
            }
        }

        private void on_properties_changed(string path, string iface) {
            if (path == NM_PATH) {
                update_state();
                update_vpn_state();
                refresh_sharing_state();
                return;
            }
            if (iface == NM_WIRELESS_IFACE) {
                access_points_changed();
                update_state();
                return;
            }
            if (iface == NM_AP_IFACE) {
                foreach (var d in wifi_devices.data) {
                    if (client.prop_path(d, NM_WIRELESS_IFACE, "ActiveAccessPoint") == path) update_state();
                }
                return;
            }
            if (iface == NM_DEVICE_IFACE) {
                var port = port_of.lookup(path);
                if (port != null) {
                    port.mark_connected(client.device_state(path) == NmDeviceState.ACTIVATED);
                    ethernet_ports_changed();
                }
                update_state();
                return;
            }
            if (iface == NM_ACTIVE_IFACE || iface == NM_VPN_IFACE) {
                update_vpn_state();
                refresh_sharing_state();
            }
        }

        private void on_object_removed(string path) {
            uint i;
            if (listed(wifi_devices, path, out i)) {
                wifi_devices.remove_index(i);
                if (wifi_device == path)
                    wifi_device = wifi_devices.length > 0 ? wifi_devices.get(0) : null;
                has_wifi = wifi_devices.length > 0;
                access_points_changed();
                update_state();
                return;
            }
            if (listed(ethernet_devices, path, out i)) {
                ethernet_devices.remove_index(i);
                var port = port_of.lookup(path);
                if (port != null) {
                    ethernet_ports_list.remove(port);
                    port_of.remove(path);
                }
                has_ethernet = ethernet_devices.length > 0;
                if (ethernet_device == path)
                    ethernet_device = ethernet_devices.length > 0 ? ethernet_devices.get(0) : null;
                ethernet_ports_changed();
                update_state();
                return;
            }
            update_vpn_state();
            refresh_sharing_state();
        }

        private void register_device(string path) {
            uint type = client.device_type(path);
            if (type == NmDeviceType.WIFI) {
                if (listed(wifi_devices, path)) return;
                wifi_devices.add(path);
                has_wifi = true;
                if (wifi_device == null) wifi_device = path;
                access_points_changed();
            } else if (type == NmDeviceType.ETHERNET) {
                if (listed(ethernet_devices, path)) return;
                ethernet_devices.add(path);
                has_ethernet = true;
                if (ethernet_device == null) ethernet_device = path;
                var port = new EthernetPortInfo(client.device_iface(path),
                    client.device_state(path) == NmDeviceState.ACTIVATED);
                ethernet_ports_list.add(port);
                port_of.insert(path, port);
                probe_ethernet_port.begin(port);
                ethernet_ports_changed();
            }
        }

        public GenericArray<EthernetPortInfo> ethernet_ports() {
            return ethernet_ports_list;
        }

        private async void probe_ethernet_port(EthernetPortInfo port) {
            string iface = port.iface;
            string chipset = "";
            string capability = "";
            new Thread<bool>("ethernet-probe", () => {
                chipset = probe_chipset(iface);
                capability = probe_capability(iface);
                Idle.add(probe_ethernet_port.callback);
                return true;
            });
            yield;
            port.set_details(chipset, capability);
            ethernet_ports_changed();
        }

        private static string probe_chipset(string iface) {
            SintySystem.DeviceNames names;
            if (SintySystem.device_names("/sys/class/net/%s/device".printf(iface), out names) != 0) return "";
            string model = ((string) names.model).strip();
            return model != "" ? model : ((string) names.vendor).strip();
        }

        private static string probe_capability(string iface) {
            SintySystem.LinkInfo info;
            if (SintySystem.net_link_info(iface, out info) != 0) return "";
            int best_mbps = info.max_supported_mbps;
            if (best_mbps <= 0) return "";
            return best_mbps >= 1000
                ? "%.3g GbE".printf(best_mbps / 1000.0)
                : "%d Mbps".printf(best_mbps);
        }

        private async bool set_radio_enabled_async(string property, bool value) {
            if (client == null) return false;
            try {
                yield client.set_property(NM_PATH, NM_IFACE, property, new GLib.Variant.boolean(value));
                return true;
            } catch (Error e) {
                warning("set %s failed: %s", property, e.message);
                return false;
            }
        }

        private async void apply_wifi_request() {
            if (client == null) return;
            wifi_request_in_flight = true;
            bool target = wifi_requested_state;
            bool ok = false;
            do {
                target = wifi_requested_state;
                ok = yield set_radio_enabled_async("WirelessEnabled", target);
            } while (ok && target != wifi_requested_state);
            wifi_request_in_flight = false;
            update_state();
        }

        public void toggle_wifi() {
            if (client == null) return;
            bool current_intent = wifi_request_in_flight
                ? wifi_requested_state
                : client.wireless_enabled;
            wifi_requested_state = !current_intent;
            if (!wifi_request_in_flight) {
                apply_wifi_request.begin();
            }
        }

        public void toggle_airplane_mode() {
            if (client == null) return;
            bool turn_on = !is_airplane_mode;
            set_radio_enabled_async.begin("WirelessEnabled", !turn_on);
            set_radio_enabled_async.begin("WwanEnabled", !turn_on);
        }

        public void request_scan() {
            if (client == null) return;
            foreach (var device in wifi_devices.data) {
                client.request_scan.begin(device, (obj, res) => {
                    try {
                        client.request_scan.end(res);
                    } catch (Error e) {
                        warning("Scan failed: %s", e.message);
                    }
                });
            }
        }

        private GenericArray<NmAccessPoint> device_access_points(string device) {
            var result = new GenericArray<NmAccessPoint>();
            foreach (var path in client.prop_paths(device, NM_WIRELESS_IFACE, "AccessPoints")) {
                var ap = client.access_point(path, device);
                if (ap != null) result.add(ap);
            }
            return result;
        }

        public GenericArray<NmAccessPoint> get_access_points() {
            var result = new GenericArray<NmAccessPoint>();
            if (client == null) return result;
            foreach (var device in wifi_devices.data) {
                foreach (var ap in device_access_points(device).data) result.add(ap);
            }
            return result;
        }

        public bool has_saved_wifi(string ssid) {
            return saved_wifi_connection(ssid) != null;
        }

        public bool activate_saved_wifi(string ssid, NmAccessPoint? ap) {
            if (client == null || wifi_device == null) return false;
            NmAccessPoint? target_ap;
            var target_device = select_wifi_device(ap, out target_ap);
            if (target_device == null) return false;
            var conn = saved_wifi_connection(ssid);
            if (conn == null) return false;
            client.activate.begin(conn.path, target_device, target_ap != null ? target_ap.path : null, (obj, res) => {
                try {
                    client.activate.end(res);
                } catch (Error e) {
                    warning("Connection failed: %s", e.message);
                }
            });
            return true;
        }

        private string? device_ssid(string device) {
            string? ap = client.prop_path(device, NM_WIRELESS_IFACE, "ActiveAccessPoint");
            if (ap == null) return null;
            string ssid = client.ap_ssid(ap);
            return ssid != "" ? ssid : null;
        }

        public string? active_wifi_ssid() {
            if (client == null || wifi_device == null) return null;
            return device_ssid(wifi_device);
        }

        public bool is_wifi_connected(string ssid) {
            if (client == null) return false;
            foreach (var device in wifi_devices.data) {
                if (device_ssid(device) == ssid) return true;
            }
            return false;
        }

        public GenericArray<NmConnection> get_vpn_connections() {
            var result = new GenericArray<NmConnection>();
            if (client == null) return result;
            foreach (var conn in client.get_connections()) {
                if (is_vpn_type(conn.get_connection_type())) result.add(conn);
            }
            return result;
        }

        private VpnLinkState link_state(string active) {
            if (client.has_interface(active, NM_VPN_IFACE)) {
                switch (client.prop_uint(active, NM_VPN_IFACE, "VpnState")) {
                    case NmVpnState.ACTIVATED:
                        return VpnLinkState.CONNECTED;
                    case NmVpnState.DISCONNECTED:
                    case NmVpnState.FAILED:
                        return VpnLinkState.DISCONNECTED;
                    default:
                        return VpnLinkState.CONNECTING;
                }
            }
            switch (client.active_state(active)) {
                case NmActiveState.ACTIVATED:
                    return VpnLinkState.CONNECTED;
                case NmActiveState.ACTIVATING:
                    return VpnLinkState.CONNECTING;
                default:
                    return VpnLinkState.DISCONNECTED;
            }
        }

        public VpnLinkState vpn_link_state(NmConnection conn) {
            if (client == null) return VpnLinkState.DISCONNECTED;
            string uuid = conn.get_uuid();
            foreach (var ac in client.active_connections()) {
                if (client.active_uuid(ac) == uuid) return link_state(ac);
            }
            return VpnLinkState.DISCONNECTED;
        }

        private string? get_active_vpn(string uuid) {
            if (client == null) return null;
            foreach (var active in client.active_connections()) {
                if (client.active_uuid(active) == uuid && is_vpn_type(client.active_type(active)))
                    return active;
            }
            return null;
        }

        private async bool disable_vpn_autoconnect(NmConnection conn) {
            if (!conn.autoconnect) return true;
            var changes = new HashTable<string, Variant?>(str_hash, str_equal);
            changes.insert("autoconnect", new Variant.boolean(false));
            try {
                yield conn.commit(conn.changed("connection", changes));
                return true;
            } catch (Error e) {
                vpn_action_result(false, "Could not save VPN state: " + e.message);
                return false;
            }
        }

        private async bool deactivate_vpn(NmConnection conn, bool save_state) {
            if (client == null) return false;
            if (save_state && !(yield disable_vpn_autoconnect(conn))) return false;
            var active = get_active_vpn(conn.get_uuid());
            if (active == null) return true;
            try {
                yield client.deactivate(active);
                return true;
            } catch (Error e) {
                vpn_action_result(false, "Could not disconnect VPN: " + e.message);
                return false;
            }
        }

        public GenericArray<NmConnection> saved_wifi_connections() {
            var result = new GenericArray<NmConnection>();
            if (client == null) return result;
            foreach (var conn in client.get_connections()) {
                if (conn.get_connection_type() != "802-11-wireless" || conn.is_hotspot()) continue;
                result.add(conn);
            }
            return result;
        }

        public NmConnection? saved_wifi_connection(string ssid) {
            foreach (var conn in saved_wifi_connections().data) {
                if (conn.wifi_ssid() == ssid) return conn;
            }
            return null;
        }

        public NmConnection? wired_connection(string iface) {
            if (client == null) return null;
            string? device = client.device_by_iface(iface);
            if (device != null) {
                string? active = client.device_active(device);
                var conn = active != null ? client.connection(client.active_connection(active)) : null;
                if (conn != null) return conn;
            }
            NmConnection? fallback = null;
            foreach (var conn in client.get_connections()) {
                if (conn.get_connection_type() != "802-3-ethernet") continue;
                string? bound = conn.get_interface_name();
                if (bound == iface) return conn;
                if (bound == null && fallback == null) fallback = conn;
            }
            return fallback;
        }

        private string? active_of(NmConnection conn) {
            foreach (var active in client.active_connections()) {
                if (client.active_connection(active) == conn.path) return active;
            }
            return null;
        }

        public NmDeviceInfo? active_device(NmConnection conn) {
            if (client == null) return null;
            string? active = active_of(conn);
            if (active == null) return null;
            var devices = client.active_devices(active);
            return devices.length > 0 ? client.device_info(devices[0]) : null;
        }

        public async bool disconnect_connection(NmConnection conn) {
            if (client == null) return false;
            foreach (var active in client.active_connections()) {
                if (client.active_connection(active) != conn.path) continue;
                try {
                    yield client.deactivate(active);
                } catch (Error e) {
                    warning("Disconnect failed: %s", e.message);
                    return false;
                }
            }
            return true;
        }

        public async bool forget_connection(NmConnection conn) {
            yield disconnect_connection(conn);
            try {
                yield conn.delete_async();
            } catch (Error e) {
                warning("Forget failed: %s", e.message);
                return false;
            }
            wifi_connections_changed();
            return true;
        }

        public async string? save_ipv4(NmConnection conn, bool manual, string address,
                                       string gateway, string[] dns, bool only_dns,
                                       bool autoconnect) {
            string? failure;
            var updated = NmImport.ipv4_changes(conn, manual, address, gateway, dns, only_dns, autoconnect,
                out failure);
            if (failure != null) return failure;
            var device = active_device(conn);
            try {
                yield conn.commit(updated);
                if (device != null) {
                    yield disconnect_connection(conn);
                    yield client.activate(conn.path, device.path, null);
                }
            } catch (Error e) {
                return e.message;
            }
            return null;
        }

        public async void deactivate_connection(NmConnection conn) {
            bool ok = yield deactivate_vpn(conn, true);
            if (ok) vpn_action_result(true, "VPN disconnected");
            update_vpn_state();
        }

        public async void delete_vpn(NmConnection conn) {
            if (!(yield deactivate_vpn(conn, false))) return;
            try {
                yield conn.delete_async();
                vpn_action_result(true, "VPN removed");
                vpn_connections_changed();
            } catch (Error e) {
                vpn_action_result(false, "Could not remove VPN: " + e.message);
            }
        }

        public async void activate_vpn(NmConnection conn) {
            if (client == null) {
                vpn_action_result(false, "NetworkManager unavailable");
                return;
            }
            var active_vpns = new GenericArray<NmConnection>();
            foreach (var active in client.active_connections()) {
                if (!is_vpn_type(client.active_type(active)) || client.active_uuid(active) == conn.get_uuid())
                    continue;
                var other = client.connection(client.active_connection(active));
                if (other != null) active_vpns.add(other);
            }
            foreach (var other in active_vpns.data) {
                if (!(yield deactivate_vpn(other, true))) return;
            }
            try {
                yield client.activate(conn.path, null, null);
            } catch (Error e) {
                vpn_action_result(false, "Could not connect VPN: " + e.message);
            }
            update_vpn_state();
        }

        private async bool add_connection(Variant settings, string ok_msg) {
            if (client == null) {
                vpn_action_result(false, "NetworkManager unavailable");
                return false;
            }
            try {
                yield client.add_connection(settings);
                vpn_action_result(true, ok_msg);
                vpn_connections_changed();
                return true;
            } catch (Error e) {
                vpn_action_result(false, "Failed to add VPN: " + e.message);
                return false;
            }
        }

        public async bool import_vpn(string file_path) {
            string lower = file_path.down();
            string name = Path.get_basename(file_path);
            int dot = name.last_index_of(".");
            if (dot > 0) name = name.substring(0, dot);
            Variant settings;
            try {
                if (lower.has_suffix(".nmconnection")) {
                    var kf = new GLib.KeyFile();
                    kf.load_from_file(file_path, GLib.KeyFileFlags.NONE);
                    settings = NmImport.keyfile(kf);
                } else {
                    string text;
                    FileUtils.get_contents(file_path, out text);
                    if (lower.has_suffix(".conf")) {
                        settings = NmImport.wireguard_conf(text, name);
                    } else {
                        string certs = Path.build_filename(Environment.get_user_data_dir(),
                            "networkmanagement", "certificates");
                        settings = NmImport.openvpn(text, name, certs);
                    }
                }
            } catch (Error e) {
                vpn_action_result(false, "Import failed: " + e.message);
                return false;
            }
            return yield add_connection(settings, "VPN imported");
        }

        public async bool add_openvpn(string name, string gateway, string username,
                                      string password, string? ca_path) {
            return yield add_connection(NmImport.openvpn_manual(name, gateway, username, password, ca_path),
                "VPN added");
        }

        public async bool add_wireguard(string name, string private_key, string address,
                                        string dns, string peer_public_key, string endpoint,
                                        string allowed_ips, string? preshared_key) {
            Variant settings;
            try {
                settings = NmImport.wireguard_manual(name, private_key, address, dns, peer_public_key,
                    endpoint, allowed_ips, preshared_key);
            } catch (Error e) {
                vpn_action_result(false, "Failed to add VPN: " + e.message);
                return false;
            }
            return yield add_connection(settings, "WireGuard VPN added");
        }

        public void connect_to_ap(NmAccessPoint ap, string? password) {
            if (client == null || wifi_device == null) return;
            NmAccessPoint? target_ap;
            var target_device = select_wifi_device(ap, out target_ap);
            if (target_device == null || target_ap == null) return;
            client.add_and_activate.begin(NmImport.wifi(ap.ssid, password), target_device, target_ap.path,
                (obj, res) => {
                try {
                    client.add_and_activate.end(res);
                } catch (Error e) {
                    warning("Connection failed: %s", e.message);
                }
            });
        }

        private string? select_wifi_device(NmAccessPoint? requested, out NmAccessPoint? selected_ap) {
            selected_ap = requested;
            if (requested == null)
                return dynamic_internet.enabled ? get_free_wifi_device() ?? wifi_device : wifi_device;
            string? owner = null;
            foreach (var device in wifi_devices.data) {
                foreach (var candidate in device_access_points(device).data) {
                    if (candidate.path == requested.path) owner = device;
                    if (dynamic_internet.enabled && client.device_active(device) == null
                            && candidate.ssid == requested.ssid) {
                        selected_ap = candidate;
                        return device;
                    }
                }
            }
            return owner ?? wifi_device;
        }

        public bool wifi_is_upstream() {
            if (client == null) return false;
            string? active = client.primary_connection();
            return active != null && client.active_type(active) == "802-11-wireless";
        }

        private string? get_free_wifi_device() {
            foreach (var d in wifi_devices.data) {
                if (client.device_active(d) == null) return d;
            }
            return null;
        }

        public bool hotspot_needs_disconnect() {
            return get_free_wifi_device() == null && wifi_is_upstream();
        }

        public static string generate_password() {
            const string chars = "abcdefghijkmnpqrstuvwxyz23456789";
            var sb = new StringBuilder();
            for (int i = 0; i < 8; i++)
                sb.append_c(chars[Random.int_range(0, chars.length)]);
            return sb.str;
        }

        private async void delete_connections_by_id(string id) {
            if (client == null) return;
            foreach (var c in client.get_connections()) {
                if (c.get_id() != id) continue;
                try {
                    yield c.delete_async();
                } catch (Error e) {
                    warning("Cannot remove %s: %s", id, e.message);
                }
            }
        }

        public void start_wifi_hotspot(string ssid, string password, bool wpa3) {
            if (client == null || wifi_device == null) {
                sharing_action_result(false, "No WiFi device available");
                return;
            }
            start_wifi_hotspot_async.begin(ssid, password, wpa3);
        }

        private async void start_wifi_hotspot_async(string ssid, string password, bool wpa3) {
            yield delete_connections_by_id(HOTSPOT_ID);
            var host_dev = get_free_wifi_device() ?? wifi_device;
            try {
                yield client.add_and_activate(NmImport.hotspot(HOTSPOT_ID, ssid, password, wpa3), host_dev, null);
                sharing_action_result(true, "Hotspot started");
            } catch (Error e) {
                sharing_action_result(false, "Could not start hotspot: " + e.message);
            }
        }

        public void stop_wifi_hotspot() {
            if (client == null) return;
            foreach (var ac in client.active_connections()) {
                var conn = client.connection(client.active_connection(ac));
                if (conn != null && conn.is_hotspot()) {
                    client.deactivate.begin(ac, (o, r) => {
                        try {
                            client.deactivate.end(r);
                        } catch (Error e) {
                            warning("Cannot stop the hotspot: %s", e.message);
                        }
                    });
                }
            }
            delete_connections_by_id.begin(HOTSPOT_ID);
        }

        private string? get_share_ethernet_device() {
            string? up_iface = null;
            string? primary = client.primary_connection();
            if (primary != null) {
                var devs = client.active_devices(primary);
                if (devs.length > 0) up_iface = client.device_iface(devs[0]);
            }
            foreach (var d in ethernet_devices.data) {
                if (up_iface != null && client.device_iface(d) == up_iface) continue;
                return d;
            }
            return null;
        }

        public void start_ethernet_sharing() {
            var dev = client != null ? get_share_ethernet_device() : null;
            if (client == null || dev == null) {
                sharing_action_result(false, "No spare wired port to share on");
                return;
            }
            start_ethernet_sharing_async.begin(dev);
        }

        private async void start_ethernet_sharing_async(string dev) {
            yield delete_connections_by_id(WIRED_SHARE_ID);
            try {
                yield client.add_and_activate(NmImport.wired_share(WIRED_SHARE_ID), dev, null);
                sharing_action_result(true, "Wired sharing started");
            } catch (Error e) {
                sharing_action_result(false, "Could not start wired sharing: " + e.message);
            }
        }

        public void stop_ethernet_sharing() {
            if (client == null) return;
            foreach (var ac in client.active_connections()) {
                if (client.active_type(ac) != "802-3-ethernet") continue;
                var conn = client.connection(client.active_connection(ac));
                if (conn != null && conn.ipv4_method() == "shared") {
                    client.deactivate.begin(ac, (o, r) => {
                        try {
                            client.deactivate.end(r);
                        } catch (Error e) {
                            warning("Cannot stop wired sharing: %s", e.message);
                        }
                    });
                }
            }
            delete_connections_by_id.begin(WIRED_SHARE_ID);
        }

        private void refresh_sharing_state() {
            bool wifi_ap = false, eth_share = false;
            if (client != null) {
                foreach (var ac in client.active_connections()) {
                    var conn = client.connection(client.active_connection(ac));
                    if (conn == null) continue;
                    if (conn.is_hotspot()) wifi_ap = true;
                    if (client.active_type(ac) == "802-3-ethernet" && conn.ipv4_method() == "shared") eth_share = true;
                }
            }
            if (wifi_ap != wifi_hotspot_active || eth_share != ethernet_sharing_active) {
                wifi_hotspot_active = wifi_ap;
                ethernet_sharing_active = eth_share;
                hotspot_state_changed();
            }
        }

        private void update_vpn_state() {
            string? active = null;
            if (client != null) {
                foreach (var ac in client.active_connections()) {
                    if (is_vpn_type(client.active_type(ac))) {
                        active = ac;
                        break;
                    }
                }
            }
            if (active != null) {
                vpn_name = client.active_id(active);
                var st = link_state(active);
                vpn_active = (st == VpnLinkState.CONNECTED);
                vpn_icon = vpn_active ? "network-vpn-symbolic"
                         : (st == VpnLinkState.CONNECTING ? "network-vpn-acquiring-symbolic"
                                                          : "network-vpn-no-route-symbolic");
            } else {
                vpn_active = false;
                vpn_name = "";
                vpn_icon = "network-vpn-symbolic";
            }
            vpn_state_changed();
        }

        private void update_state() {
            if (client == null) return;
            wifi_enabled = client.wireless_enabled;
            bool wwan_off = !client.wwan_enabled;
            is_airplane_mode = !wifi_enabled && wwan_off;
            foreach (var cand in ethernet_devices.data) {
                if (client.device_state(cand) == NmDeviceState.ACTIVATED) {
                    ethernet_device = cand;
                    break;
                }
            }
            is_wired_connected = (ethernet_device != null &&
                client.device_state(ethernet_device) == NmDeviceState.ACTIVATED);
            if (!wifi_enabled) {
                wifi_icon = "network-wireless-disabled-symbolic";
                wifi_ssid = "Wi-Fi Disabled";
            } else {
                string? active = client.primary_connection();
                if (active != null) {
                    if (client.active_type(active) == "802-11-wireless") {
                        wifi_ssid = client.active_id(active);
                        string? ap = wifi_device != null
                            ? client.prop_path(wifi_device, NM_WIRELESS_IFACE, "ActiveAccessPoint") : null;
                        if (ap != null) {
                            uint s = client.prop_uint(ap, NM_AP_IFACE, "Strength");
                            if (s < 25)       wifi_icon = "network-wireless-signal-weak-symbolic";
                            else if (s < 50)  wifi_icon = "network-wireless-signal-ok-symbolic";
                            else if (s < 75)  wifi_icon = "network-wireless-signal-good-symbolic";
                            else              wifi_icon = "network-wireless-signal-excellent-symbolic";
                        } else {
                            wifi_icon = "network-wireless-connected-symbolic";
                        }
                    } else {
                        wifi_ssid = "Connected";
                        wifi_icon = "network-wired-symbolic";
                    }
                } else {
                    wifi_ssid = "Disconnected";
                    wifi_icon = "network-wireless-offline-symbolic";
                }
            }
            state_changed();
        }
    }
}
