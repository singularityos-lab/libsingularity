using NM;

namespace Singularity {

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
        public signal void access_points_changed();
        public signal void state_changed();
        public signal void vpn_state_changed();
        public signal void vpn_connections_changed();
        // Result of a user-initiated VPN action (import / manual add / remove).
        public signal void vpn_action_result(bool success, string message);

        public bool wifi_hotspot_active { get; private set; default = false; }
        public bool ethernet_sharing_active { get; private set; default = false; }
        public bool has_ethernet { get; private set; default = false; }
        public signal void hotspot_state_changed();
        public signal void sharing_action_result(bool success, string message);

        private const string HOTSPOT_ID = "Singularity Hotspot";
        private const string WIRED_SHARE_ID = "Singularity Wired Sharing";

        // Normalised connection state, shared by OpenVPN-style and WireGuard
        // connections (which report state differently).
        public enum VpnLinkState { DISCONNECTED, CONNECTING, CONNECTED }

        // NetworkManager connection types we treat as "VPN" in the UI.
        private static bool is_vpn_type(string? t) {
            return t == "vpn" || t == "wireguard";
        }

        private NM.Client? client;
        private NM.DeviceWifi? wifi_device;
        private GenericArray<NM.DeviceWifi> wifi_devices = new GenericArray<NM.DeviceWifi>();
        private NM.DeviceEthernet? ethernet_device;
        private GenericArray<NM.DeviceEthernet> ethernet_devices = new GenericArray<NM.DeviceEthernet>();

        public NetworkManagerWrapper() {
            init_client.begin();
        }

        private async void init_client() {
            try {
                client = (NM.Client) GLib.Object.new(typeof(NM.Client));
                yield client.init_async(Priority.DEFAULT, null);
                if (client != null) {
                    message("NetworkManager Client initialized");
                    find_wifi_device();
                    client.notify["wireless-enabled"].connect(() => {
                        update_state();
                    });
                    client.notify["primary-connection"].connect(() => {
                        update_state();
                    });
                    client.active_connection_added.connect((active) => {
                        if (active is NM.VpnConnection) {
                            var vpn_conn = (NM.VpnConnection) active;
                            vpn_conn.notify["vpn-state"].connect(() => {
                                update_vpn_state();
                            });
                        } else if (is_vpn_type(active.get_connection_type())) {
                            // WireGuard et al. activate as a plain ActiveConnection;
                            // track their generic state instead of vpn-state.
                            active.notify["state"].connect(() => {
                                update_vpn_state();
                            });
                        }
                        update_vpn_state();
                        refresh_sharing_state();
                    });
                    client.active_connection_removed.connect((active) => {
                        update_vpn_state();
                        refresh_sharing_state();
                    });
                    client.connection_added.connect((conn) => {
                        vpn_connections_changed();
                    });
                    client.connection_removed.connect((conn) => {
                        vpn_connections_changed();
                    });
                    update_state();
                    update_vpn_state();
                    refresh_sharing_state();
                }
            } catch (Error e) {
                warning("Failed to initialize NetworkManager client: %s", e.message);
            }
        }

        private void find_wifi_device() {
            if (client == null) {
                warning("NetworkManager Client is null");
                return;
            }
            var devices = client.get_devices();
            foreach (var device in devices) {
                if (device is NM.DeviceWifi) {
                    var wd = (NM.DeviceWifi) device;
                    wifi_devices.add(wd);
                    if (wifi_device == null) {
                        wifi_device = wd;
                        has_wifi = true;
                        wifi_device.access_point_added.connect(() => {
                            this.access_points_changed();
                        });
                        wifi_device.access_point_removed.connect(() => {
                            this.access_points_changed();
                        });
                        wifi_device.notify["active-access-point"].connect(() => {
                            update_state();
                            var ap = wifi_device.get_active_access_point();
                            if (ap != null) {
                                ap.notify["strength"].connect(() => update_state());
                            }
                        });
                    }
                } else if (device is NM.DeviceEthernet) {
                    var ed = (NM.DeviceEthernet) device;
                    ethernet_devices.add(ed);
                    if (ethernet_device == null) {
                        ethernet_device = ed;
                        has_ethernet = true;
                        ethernet_device.notify["state"].connect(() => {
                            update_state();
                        });
                    }
                }
            }
            if (wifi_device == null) {
                warning("No WiFi device found!");
            }
        }

        // Setting client.wireless_enabled / wwan_enabled directly is a
        // synchronous D-Bus call that blocks the GTK main thread for seconds.
        // Drive the radios via nmcli asynchronously instead; NetworkManager
        // emits notify::wireless-enabled which update_state() picks up.
        private void nmcli_async(string[] args) {
            string[] argv = new string[args.length + 1];
            argv[0] = "nmcli";
            for (int i = 0; i < args.length; i++) argv[i + 1] = args[i];
            try {
                var proc = new GLib.Subprocess.newv(argv,
                    GLib.SubprocessFlags.STDOUT_SILENCE | GLib.SubprocessFlags.STDERR_SILENCE);
                proc.wait_async.begin(null, (obj, res) => {
                    try { proc.wait_async.end(res); } catch (Error e) {}
                });
            } catch (Error e) {
                warning("nmcli %s failed: %s", string.joinv(" ", args), e.message);
            }
        }

        public void toggle_wifi() {
            if (client == null) return;
            bool target = !client.wireless_enabled;
            nmcli_async({ "radio", "wifi", target ? "on" : "off" });
            if (wifi_enabled != target) {
                wifi_enabled = target;
                state_changed();
            }
        }

        public void toggle_airplane_mode() {
            if (client == null) return;
            bool turn_on = !is_airplane_mode;
            nmcli_async({ "radio", "all", turn_on ? "off" : "on" });
        }

        public void request_scan() {
            if (wifi_device != null) {
                try {
                    wifi_device.request_scan_async.begin(null);
                } catch (Error e) {
                    warning("Scan failed: %s", e.message);
                }
            }
        }

        public GenericArray<NM.AccessPoint> get_access_points() {
            if (wifi_device != null) {
                var aps = wifi_device.get_access_points();
                return aps;
            }
            warning("Cannot get APs: No WiFi device");
            return new GenericArray<NM.AccessPoint>();
        }

        public GenericArray<NM.RemoteConnection> get_vpn_connections() {
            var result = new GenericArray<NM.RemoteConnection>();
            if (client == null) return result;
            var connections = client.get_connections();
            foreach (var conn in connections) {
                if (is_vpn_type(conn.get_connection_type())) {
                    result.add(conn);
                }
            }
            return result;
        }

        // Normalised state of a specific VPN connection (works for both
        // OpenVPN-style NM.VpnConnection and WireGuard ActiveConnection).
        public VpnLinkState vpn_link_state(NM.RemoteConnection conn) {
            if (client == null) return VpnLinkState.DISCONNECTED;
            string uuid = conn.get_uuid();
            foreach (var ac in client.get_active_connections()) {
                if (ac.get_uuid() != uuid) continue;
                if (ac is NM.VpnConnection) {
                    switch (((NM.VpnConnection) ac).vpn_state) {
                        case NM.VpnConnectionState.ACTIVATED:
                            return VpnLinkState.CONNECTED;
                        case NM.VpnConnectionState.DISCONNECTED:
                        case NM.VpnConnectionState.FAILED:
                            return VpnLinkState.DISCONNECTED;
                        default:
                            return VpnLinkState.CONNECTING;
                    }
                } else {
                    switch (ac.get_state()) {
                        case NM.ActiveConnectionState.ACTIVATED:
                            return VpnLinkState.CONNECTED;
                        case NM.ActiveConnectionState.ACTIVATING:
                            return VpnLinkState.CONNECTING;
                        default:
                            return VpnLinkState.DISCONNECTED;
                    }
                }
            }
            return VpnLinkState.DISCONNECTED;
        }

        // Deactivate a specific VPN connection by matching its active instance.
        public void deactivate_connection(NM.RemoteConnection conn) {
            if (client == null) return;
            string uuid = conn.get_uuid();
            foreach (var ac in client.get_active_connections()) {
                if (ac.get_uuid() == uuid) {
                    client.deactivate_connection_async.begin(ac, null, (obj, res) => {
                        try {
                            client.deactivate_connection_async.end(res);
                        } catch (Error e) {
                            warning("VPN disconnect failed: %s", e.message);
                        }
                    });
                    return;
                }
            }
        }

        // Permanently remove a VPN connection ("forget").
        public void delete_vpn(NM.RemoteConnection conn) {
            conn.delete_async.begin(null, (obj, res) => {
                try {
                    conn.delete_async.end(res);
                    vpn_action_result(true, "VPN removed");
                    vpn_connections_changed();
                } catch (Error e) {
                    vpn_action_result(false, "Could not remove VPN: " + e.message);
                }
            });
        }

        public void activate_vpn(NM.RemoteConnection conn) {
            if (client == null) return;
            client.activate_connection_async.begin(conn, null, null, null, (obj, res) => {
                try {
                    client.activate_connection_async.end(res);
                } catch (Error e) {
                    warning("VPN connect failed: %s", e.message);
                }
            });
        }

        // Add a fully-built connection through libnm (same D-Bus/polkit path as
        // GNOME) and report the outcome.
        private async bool add_connection(NM.Connection conn, string ok_msg) {
            if (client == null) { vpn_action_result(false, "NetworkManager unavailable"); return false; }
            try {
                var added = yield client.add_connection_async(conn, true, null);
                bool ok = (added != null);
                vpn_action_result(ok, ok ? ok_msg : "Failed to add VPN");
                if (ok) vpn_connections_changed();
                return ok;
            } catch (Error e) {
                vpn_action_result(false, "Failed to add VPN: " + e.message);
                return false;
            }
        }

        // Load the installed OpenVPN editor plugin so we can parse .ovpn files
        // exactly as GNOME does - no nmcli subprocess.
        private NM.VpnEditorPlugin? load_openvpn_plugin() {
            try {
                var info = new NM.VpnPluginInfo.from_file(
                    "/usr/lib/NetworkManager/VPN/nm-openvpn-service.name");
                return info.load_editor_plugin();
            } catch (Error e) {
                warning("Cannot load OpenVPN plugin: %s", e.message);
                return null;
            }
        }

        // Import a VPN configuration file using libnm only (no nmcli):
        //   .nmconnection -> keyfile reader
        //   .conf         -> WireGuard wg-quick importer
        //   .ovpn / other -> OpenVPN editor plugin importer
        public async bool import_vpn(string file_path) {
            string lower = file_path.down();
            NM.Connection? conn = null;
            try {
                if (lower.has_suffix(".nmconnection")) {
                    var kf = new GLib.KeyFile();
                    kf.load_from_file(file_path, GLib.KeyFileFlags.NONE);
                    conn = NM.keyfile_read(kf, GLib.Path.get_dirname(file_path),
                                           NM.KeyfileHandlerFlags.NONE, null);
                } else if (lower.has_suffix(".conf")) {
                    conn = NM.conn_wireguard_import(file_path);
                } else {
                    var plugin = load_openvpn_plugin();
                    if (plugin == null) {
                        vpn_action_result(false, "OpenVPN plugin not available");
                        return false;
                    }
                    conn = plugin.import(file_path);
                }
            } catch (Error e) {
                vpn_action_result(false, "Import failed: " + e.message);
                return false;
            }
            if (conn == null) {
                vpn_action_result(false, "Could not read VPN configuration");
                return false;
            }
            return yield add_connection(conn, "VPN imported");
        }

        // Manually add an OpenVPN connection via libnm.
        public async bool add_openvpn(string name, string gateway, string username,
                                      string password, string? ca_path) {
            var conn = (NM.SimpleConnection) GLib.Object.new(typeof(NM.SimpleConnection));
            var s_con = (NM.SettingConnection) GLib.Object.new(typeof(NM.SettingConnection));
            s_con.id = name;
            s_con.uuid = NM.Utils.uuid_generate();
            ((GLib.Object) s_con).set("type", "vpn");
            conn.add_setting(s_con);

            var s_vpn = (NM.SettingVpn) GLib.Object.new(typeof(NM.SettingVpn));
            s_vpn.service_type = "org.freedesktop.NetworkManager.openvpn";
            s_vpn.add_data_item("remote", gateway);
            s_vpn.add_data_item("connection-type", "password");
            s_vpn.add_data_item("username", username);
            if (ca_path != null && ca_path.strip() != "")
                s_vpn.add_data_item("ca", ca_path);
            s_vpn.add_secret("password", password);
            conn.add_setting(s_vpn);

            return yield add_connection(conn, "VPN added");
        }

        // Add one "address/prefix" to the right family's IP setting. Returns the
        // family added, or -1 on parse failure.
        private int add_ip_address(string cidr, NM.SettingIP4Config ip4, NM.SettingIP6Config ip6) {
            bool is6 = cidr.contains(":");
            string addr = cidr;
            uint prefix = is6 ? 128 : 32;
            int slash = cidr.index_of("/");
            if (slash >= 0) {
                addr = cidr.substring(0, slash).strip();
                prefix = (uint) int.parse(cidr.substring(slash + 1).strip());
            }
            int family = is6 ? (int) GLib.SocketFamily.IPV6 : (int) GLib.SocketFamily.IPV4;
            try {
                var ip = new NM.IPAddress(family, addr, prefix);
                if (is6) ip6.add_address(ip); else ip4.add_address(ip);
                return family;
            } catch (Error e) {
                warning("Invalid VPN address '%s': %s", cidr, e.message);
                return -1;
            }
        }

        // Manually add a WireGuard connection via libnm typed settings - no
        // subprocess and no temp file holding the private key.
        public async bool add_wireguard(string name, string private_key, string address,
                                        string dns, string peer_public_key, string endpoint,
                                        string allowed_ips, string? preshared_key) {
            var conn = (NM.SimpleConnection) GLib.Object.new(typeof(NM.SimpleConnection));

            var s_con = (NM.SettingConnection) GLib.Object.new(typeof(NM.SettingConnection));
            s_con.id = name;
            s_con.uuid = NM.Utils.uuid_generate();
            ((GLib.Object) s_con).set("type", "wireguard");
            conn.add_setting(s_con);

            var s_wg = (NM.SettingWireGuard) GLib.Object.new(typeof(NM.SettingWireGuard));
            ((GLib.Object) s_wg).set("private-key", private_key.strip());
            var peer = new NM.WireGuardPeer();
            peer.set_public_key(peer_public_key.strip(), false);
            if (endpoint.strip() != "") peer.set_endpoint(endpoint.strip(), false);
            if (preshared_key != null && preshared_key.strip() != "")
                peer.set_preshared_key(preshared_key.strip(), false);
            string aips = allowed_ips.strip() != "" ? allowed_ips.strip() : "0.0.0.0/0, ::/0";
            foreach (var ip in aips.split(",")) {
                string t = ip.strip();
                if (t != "") peer.append_allowed_ip(t, false);
            }
            s_wg.append_peer(peer);
            conn.add_setting(s_wg);

            var s_ip4 = (NM.SettingIP4Config) GLib.Object.new(typeof(NM.SettingIP4Config));
            var s_ip6 = (NM.SettingIP6Config) GLib.Object.new(typeof(NM.SettingIP6Config));
            bool has4 = false, has6 = false;
            foreach (var a in address.split(",")) {
                string t = a.strip();
                if (t == "") continue;
                int fam = add_ip_address(t, s_ip4, s_ip6);
                if (fam == (int) GLib.SocketFamily.IPV6) has6 = true;
                else if (fam == (int) GLib.SocketFamily.IPV4) has4 = true;
            }
            s_ip4.method = has4 ? "manual" : "disabled";
            s_ip6.method = has6 ? "manual" : "disabled";
            if (!has4 && !has6) { s_ip4.method = "auto"; s_ip6.method = "auto"; }
            foreach (var d in dns.split(",")) {
                string t = d.strip();
                if (t == "") continue;
                if (t.contains(":")) s_ip6.add_dns(t); else s_ip4.add_dns(t);
            }
            conn.add_setting(s_ip4);
            conn.add_setting(s_ip6);

            return yield add_connection(conn, "WireGuard VPN added");
        }

        public void connect_to_ap(NM.AccessPoint ap, string? password) {
            if (client == null || wifi_device == null) return;
            try {
                var connection = (NM.SimpleConnection) GLib.Object.new(typeof(NM.SimpleConnection));
                var s_wifi = (NM.SettingWireless) GLib.Object.new(typeof(NM.SettingWireless));
                s_wifi.ssid = ap.ssid;
                connection.add_setting(s_wifi);
                if (password != null && password != "") {
                    var s_security = (NM.SettingWirelessSecurity) GLib.Object.new(typeof(NM.SettingWirelessSecurity));
                    s_security.key_mgmt = "wpa-psk";
                    s_security.psk = password;
                    connection.add_setting(s_security);
                }
                client.add_and_activate_connection_async.begin(connection, wifi_device, ap.get_path(), null, (obj, res) => {
                    try {
                        client.add_and_activate_connection_async.end(res);
                    } catch (Error e) {
                        warning("Connection failed: %s", e.message);
                    }
                });
            } catch (Error e) {
                warning("Failed to create connection: %s", e.message);
            }
        }

        public bool wifi_is_upstream() {
            if (client == null) return false;
            var active = client.primary_connection;
            return active != null && active.get_connection_type() == "802-11-wireless";
        }

        private NM.DeviceWifi? get_free_wifi_device() {
            for (int i = 0; i < wifi_devices.length; i++) {
                var d = wifi_devices.get(i);
                if (d.get_active_connection() == null) return d;
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

        private void delete_connections_by_id(string id) {
            if (client == null) return;
            foreach (var c in client.get_connections()) {
                if (c.get_id() == id) {
                    c.delete_async.begin(null, (o, r) => {
                        try { c.delete_async.end(r); } catch (Error e) {}
                    });
                }
            }
        }

        public void start_wifi_hotspot(string ssid, string password, bool wpa3) {
            if (client == null || wifi_device == null) {
                sharing_action_result(false, "No WiFi device available");
                return;
            }
            delete_connections_by_id(HOTSPOT_ID);

            var conn = (NM.SimpleConnection) GLib.Object.new(typeof(NM.SimpleConnection));
            var s_con = (NM.SettingConnection) GLib.Object.new(typeof(NM.SettingConnection));
            s_con.id = HOTSPOT_ID;
            s_con.uuid = NM.Utils.uuid_generate();
            ((GLib.Object) s_con).set("type", "802-11-wireless");
            s_con.autoconnect = false;
            conn.add_setting(s_con);

            var s_wifi = (NM.SettingWireless) GLib.Object.new(typeof(NM.SettingWireless));
            s_wifi.ssid = new Bytes(ssid.data);
            ((GLib.Object) s_wifi).set("mode", "ap");
            ((GLib.Object) s_wifi).set("band", "bg");
            conn.add_setting(s_wifi);

            var s_sec = (NM.SettingWirelessSecurity) GLib.Object.new(typeof(NM.SettingWirelessSecurity));
            s_sec.key_mgmt = wpa3 ? "sae" : "wpa-psk";
            s_sec.psk = password;
            conn.add_setting(s_sec);

            var s_ip4 = (NM.SettingIP4Config) GLib.Object.new(typeof(NM.SettingIP4Config));
            s_ip4.method = "shared";
            conn.add_setting(s_ip4);
            var s_ip6 = (NM.SettingIP6Config) GLib.Object.new(typeof(NM.SettingIP6Config));
            s_ip6.method = "ignore";
            conn.add_setting(s_ip6);

            var host_dev = get_free_wifi_device();
            if (host_dev == null) host_dev = wifi_device;

            client.add_and_activate_connection_async.begin(conn, host_dev, null, null, (obj, res) => {
                try {
                    client.add_and_activate_connection_async.end(res);
                    sharing_action_result(true, "Hotspot started");
                } catch (Error e) {
                    sharing_action_result(false, "Could not start hotspot: " + e.message);
                }
            });
        }

        public void stop_wifi_hotspot() {
            if (client == null) return;
            foreach (var ac in client.get_active_connections()) {
                var rc = ac.get_connection();
                var sw = rc != null ? rc.get_setting_wireless() : null;
                if (sw != null && sw.mode == "ap") {
                    client.deactivate_connection_async.begin(ac, null, (o, r) => {
                        try { client.deactivate_connection_async.end(r); } catch (Error e) {}
                    });
                }
            }
            delete_connections_by_id(HOTSPOT_ID);
        }

        private NM.DeviceEthernet? get_share_ethernet_device() {
            string? up_iface = null;
            if (client != null) {
                var primary = client.primary_connection;
                if (primary != null) {
                    var devs = primary.get_devices();
                    if (devs.length > 0) up_iface = devs.get(0).get_iface();
                }
            }
            for (int i = 0; i < ethernet_devices.length; i++) {
                var d = ethernet_devices.get(i);
                if (up_iface != null && d.get_iface() == up_iface) continue;
                return d;
            }
            return null;
        }

        public void start_ethernet_sharing() {
            var dev = get_share_ethernet_device();
            if (client == null || dev == null) {
                sharing_action_result(false, "No spare wired port to share on");
                return;
            }
            delete_connections_by_id(WIRED_SHARE_ID);

            var conn = (NM.SimpleConnection) GLib.Object.new(typeof(NM.SimpleConnection));
            var s_con = (NM.SettingConnection) GLib.Object.new(typeof(NM.SettingConnection));
            s_con.id = WIRED_SHARE_ID;
            s_con.uuid = NM.Utils.uuid_generate();
            ((GLib.Object) s_con).set("type", "802-3-ethernet");
            s_con.autoconnect = false;
            conn.add_setting(s_con);

            var s_eth = (NM.SettingWired) GLib.Object.new(typeof(NM.SettingWired));
            conn.add_setting(s_eth);

            var s_ip4 = (NM.SettingIP4Config) GLib.Object.new(typeof(NM.SettingIP4Config));
            s_ip4.method = "shared";
            conn.add_setting(s_ip4);
            var s_ip6 = (NM.SettingIP6Config) GLib.Object.new(typeof(NM.SettingIP6Config));
            s_ip6.method = "ignore";
            conn.add_setting(s_ip6);

            client.add_and_activate_connection_async.begin(conn, dev, null, null, (obj, res) => {
                try {
                    client.add_and_activate_connection_async.end(res);
                    sharing_action_result(true, "Wired sharing started");
                } catch (Error e) {
                    sharing_action_result(false, "Could not start wired sharing: " + e.message);
                }
            });
        }

        public void stop_ethernet_sharing() {
            if (client == null) return;
            foreach (var ac in client.get_active_connections()) {
                if (ac.get_connection_type() != "802-3-ethernet") continue;
                var rc = ac.get_connection();
                var ip4 = rc != null ? rc.get_setting_ip4_config() : null;
                if (ip4 != null && ip4.method == "shared") {
                    client.deactivate_connection_async.begin(ac, null, (o, r) => {
                        try { client.deactivate_connection_async.end(r); } catch (Error e) {}
                    });
                }
            }
            delete_connections_by_id(WIRED_SHARE_ID);
        }

        private void refresh_sharing_state() {
            bool wifi_ap = false, eth_share = false;
            if (client != null) {
                foreach (var ac in client.get_active_connections()) {
                    var rc = ac.get_connection();
                    if (rc == null) continue;
                    var sw = rc.get_setting_wireless();
                    if (sw != null && sw.mode == "ap") wifi_ap = true;
                    if (ac.get_connection_type() == "802-3-ethernet") {
                        var ip4 = rc.get_setting_ip4_config();
                        if (ip4 != null && ip4.method == "shared") eth_share = true;
                    }
                }
            }
            if (wifi_ap != wifi_hotspot_active || eth_share != ethernet_sharing_active) {
                wifi_hotspot_active = wifi_ap;
                ethernet_sharing_active = eth_share;
                hotspot_state_changed();
            }
        }

        private void update_vpn_state() {
            // Find the first active VPN-like connection (OpenVPN or WireGuard).
            NM.ActiveConnection? active = null;
            if (client != null) {
                foreach (var ac in client.get_active_connections()) {
                    if (is_vpn_type(ac.get_connection_type())) { active = ac; break; }
                }
            }

            if (active != null) {
                vpn_name = active.get_id();
                VpnLinkState st;
                if (active is NM.VpnConnection) {
                    var s = ((NM.VpnConnection) active).vpn_state;
                    if (s == NM.VpnConnectionState.ACTIVATED) st = VpnLinkState.CONNECTED;
                    else if (s == NM.VpnConnectionState.DISCONNECTED || s == NM.VpnConnectionState.FAILED)
                        st = VpnLinkState.DISCONNECTED;
                    else st = VpnLinkState.CONNECTING;
                } else {
                    var s = active.get_state();
                    if (s == NM.ActiveConnectionState.ACTIVATED) st = VpnLinkState.CONNECTED;
                    else if (s == NM.ActiveConnectionState.ACTIVATING) st = VpnLinkState.CONNECTING;
                    else st = VpnLinkState.DISCONNECTED;
                }
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
            is_wired_connected = (ethernet_device != null &&
                ethernet_device.state == NM.DeviceState.ACTIVATED);
            if (!wifi_enabled) {
                wifi_icon = "network-wireless-disabled-symbolic";
                wifi_ssid = "Wi-Fi Disabled";
            } else {
                var active = client.primary_connection;
                if (active != null) {
                    if (active.get_connection_type() == "802-11-wireless") {
                        wifi_ssid = active.id;
                        var ap = wifi_device != null ? wifi_device.get_active_access_point() : null;
                        if (ap != null) {
                            uint8 s = ap.strength;
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
                    wifi_icon = "network-wireless-symbolic";
                }
            }
            state_changed();
        }
    }
}
