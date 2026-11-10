namespace Singularity {

    public class NetworkManagerDynamicInternetBackend : GLib.Object, DynamicInternetBackend {
        private const int64 PREFERRED_METRIC = 50;
        private const int64 STANDBY_METRIC = 600;
        private const uint CHECKPOINT_SECONDS = 12;

        public string name { owned get { return "NetworkManager"; } }

        private NmClient client;
        private HashTable<string, int64?> original_ip4 =
            new HashTable<string, int64?>(str_hash, str_equal);
        private HashTable<string, int64?> original_ip6 =
            new HashTable<string, int64?>(str_hash, str_equal);
        private int probe_target;

        [CCode (cname = "singularity_socket_bind_to_device",
                cheader_filename = "src/system/dynamic_internet_socket.h")]
        private static extern bool bind_to_device(GLib.Socket socket, string interface_name)
            throws GLib.Error;

        public NetworkManagerDynamicInternetBackend(NmClient client) {
            this.client = client;
            client.object_added.connect((path) => {
                if (client.has_interface(path, NM_ACTIVE_IFACE) || client.has_interface(path, NM_DEVICE_IFACE))
                    changed();
            });
            client.object_removed.connect(() => changed());
        }

        public async Gee.List<InternetUplink> probe(Cancellable? cancellable) throws Error {
            var result = new Gee.ArrayList<InternetUplink>();
            foreach (var device in client.devices()) {
                if (!is_uplink(device) || client.device_state(device) != NmDeviceState.ACTIVATED) continue;
                string? active = client.device_active(device);
                if (active == null || client.prop_bool(active, NM_ACTIVE_IFACE, "Vpn")) continue;

                string iface = client.device_iface(device);
                var uplink = new InternetUplink(iface, iface, display_name(device, active),
                    kind_for(client.device_type(device)));
                uplink.primary = client.prop_bool(active, NM_ACTIVE_IFACE, "Default");
                uplink.captive = client.prop_uint(device, NM_DEVICE_IFACE, "Ip4Connectivity") == NM_CONNECTIVITY_PORTAL;
                uint metered = client.prop_uint(device, NM_DEVICE_IFACE, "Metered");
                uplink.metered = metered == NM_METERED_YES || metered == NM_METERED_GUESS_YES;
                uplink.latency_ms = yield measure_latency(device, cancellable);
                uplink.reachable = !uplink.captive && uplink.latency_ms >= 0;
                result.add(uplink);
            }
            probe_target = (probe_target + 1) % 2;
            return result;
        }

        public async void prefer(string uplink_id, Cancellable? cancellable) throws Error {
            var devices = active_uplinks();
            string? preferred = null;
            foreach (var device in devices) {
                if (client.device_iface(device) == uplink_id) preferred = device;
            }
            if (preferred == null) throw new IOError.NOT_FOUND("Connection is no longer available");

            var reply = yield client.call(NM_PATH, NM_IFACE, "CheckpointCreate",
                new Variant("(^aouu)", devices, CHECKPOINT_SECONDS, 0x8), cancellable);
            string checkpoint = reply.get_child_value(0).get_string();
            try {
                foreach (var device in devices)
                    yield set_metric(device, device == preferred ? PREFERRED_METRIC : STANDBY_METRIC,
                        cancellable);

                int latency = yield measure_latency(preferred, cancellable);
                if (latency < 0) {
                    throw new IOError.HOST_UNREACHABLE("The selected connection failed its safety check");
                }
                yield client.call(NM_PATH, NM_IFACE, "CheckpointDestroy", new Variant("(o)", checkpoint), cancellable);
            } catch (Error e) {
                try {
                    yield client.call(NM_PATH, NM_IFACE, "CheckpointRollback", new Variant("(o)", checkpoint), cancellable);
                } catch (Error rollback_error) {
                    warning("Dynamic Internet rollback failed: %s", rollback_error.message);
                }
                throw e;
            }
        }

        public async void reset(Cancellable? cancellable) throws Error {
            foreach (var device in active_uplinks()) {
                string iface = client.device_iface(device);
                if (!original_ip4.contains(iface) && !original_ip6.contains(iface)) continue;
                yield reapply(device, original_ip4[iface], original_ip6[iface], cancellable);
            }
            original_ip4.remove_all();
            original_ip6.remove_all();
        }

        private string[] active_uplinks() {
            string[] result = {};
            foreach (var device in client.devices()) {
                if (is_uplink(device) && client.device_state(device) == NmDeviceState.ACTIVATED)
                    result += device;
            }
            return result;
        }

        private static int64? metric_of(Variant applied, string group) {
            var g = applied.lookup_value(group, new VariantType("a{sv}"));
            if (g == null) return null;
            var v = g.lookup_value("route-metric", VariantType.INT64);
            return v != null ? v.get_int64() : -1;
        }

        private async void reapply(string device, int64? metric4, int64? metric6, Cancellable? cancellable)
            throws Error {
            var reply = yield client.call(device, NM_DEVICE_IFACE, "GetAppliedConnection",
                new Variant("(u)", 0), cancellable);
            var applied = new NmConnection.detached(reply.get_child_value(0));
            uint64 version = reply.get_child_value(1).get_uint64();
            var settings = applied.settings;
            if (metric4 != null && applied.has_setting("ipv4")) {
                var c = new HashTable<string, Variant?>(str_hash, str_equal);
                c.insert("route-metric", new Variant.int64(metric4));
                settings = new NmConnection.detached(settings).changed("ipv4", c);
            }
            if (metric6 != null && applied.has_setting("ipv6")) {
                var c = new HashTable<string, Variant?>(str_hash, str_equal);
                c.insert("route-metric", new Variant.int64(metric6));
                settings = new NmConnection.detached(settings).changed("ipv6", c);
            }
            yield client.call(device, NM_DEVICE_IFACE, "Reapply",
                new Variant("(@a{sa{sv}}tu)", settings, version, 0), cancellable);
        }

        private async void set_metric(string device, int64 metric, Cancellable? cancellable)
            throws Error {
            var reply = yield client.call(device, NM_DEVICE_IFACE, "GetAppliedConnection",
                new Variant("(u)", 0), cancellable);
            var applied = reply.get_child_value(0);
            string iface = client.device_iface(device);
            var m4 = metric_of(applied, "ipv4");
            var m6 = metric_of(applied, "ipv6");
            if (m4 != null && !original_ip4.contains(iface)) original_ip4[iface] = m4;
            if (m6 != null && !original_ip6.contains(iface)) original_ip6[iface] = m6;
            yield reapply(device, m4 != null ? (int64?) metric : null, m6 != null ? (int64?) metric : null,
                cancellable);
        }

        private async int measure_latency(string device, Cancellable? parent) {
            string source = client.ip_address(device, false);
            bool ipv6 = false;
            if (source == "") {
                source = client.ip_address(device, true);
                ipv6 = true;
            }
            if (source == "") return -1;
            var source_address = new InetAddress.from_string(source);
            if (source_address == null) return -1;

            string target = ipv6
                ? (probe_target == 0 ? "2606:4700:4700::1111" : "2001:4860:4860::8888")
                : (probe_target == 0 ? "1.1.1.1" : "8.8.8.8");
            int latency = yield connect_latency(client.device_iface(device), source_address, target, parent);
            if (latency >= 0 || (parent != null && parent.is_cancelled())) return latency;
            target = ipv6
                ? (probe_target == 0 ? "2001:4860:4860::8888" : "2606:4700:4700::1111")
                : (probe_target == 0 ? "8.8.8.8" : "1.1.1.1");
            return yield connect_latency(client.device_iface(device), source_address, target, parent);
        }

        private async int connect_latency(string interface_name, InetAddress source_address,
                                          string target, Cancellable? parent) {
            var timeout = new Cancellable();
            uint timeout_source = Timeout.add(800, () => {
                timeout.cancel();
                return Source.REMOVE;
            });
            ulong cancelled_id = 0;
            if (parent != null) {
                if (parent.is_cancelled()) timeout.cancel();
                else cancelled_id = parent.cancelled.connect(() => timeout.cancel());
            }
            var socket = new SocketClient();
            socket.enable_proxy = false;
            socket.set_local_address(new InetSocketAddress(source_address, 0));
            bool bind_failed = false;
            socket.event.connect((event, connectable, stream) => {
                if (event != SocketClientEvent.CONNECTING || !(stream is SocketConnection))
                    return;
                try {
                    bind_to_device(((SocketConnection) stream).get_socket(), interface_name);
                } catch (Error e) {
                    bind_failed = true;
                    timeout.cancel();
                }
            });
            int64 started = get_monotonic_time();
            try {
                var connection = yield socket.connect_to_host_async(target, 443, timeout);
                connection.close();
                if (timeout_source != 0) Source.remove(timeout_source);
                if (parent != null && cancelled_id != 0) parent.disconnect(cancelled_id);
                return bind_failed ? -1
                    : (int) ((get_monotonic_time() - started) / TimeSpan.MILLISECOND);
            } catch (Error e) {
                if (timeout_source != 0 && !timeout.is_cancelled()) Source.remove(timeout_source);
                if (parent != null && cancelled_id != 0) parent.disconnect(cancelled_id);
                return -1;
            }
        }

        private bool is_uplink(string device) {
            switch (client.device_type(device)) {
                case NmDeviceType.ETHERNET:
                case NmDeviceType.WIFI:
                case NmDeviceType.MODEM:
                case NmDeviceType.BT:
                    return true;
                default:
                    return false;
            }
        }

        private static InternetUplinkKind kind_for(uint type) {
            switch (type) {
                case NmDeviceType.ETHERNET: return InternetUplinkKind.ETHERNET;
                case NmDeviceType.WIFI: return InternetUplinkKind.WIFI;
                case NmDeviceType.MODEM:
                case NmDeviceType.BT: return InternetUplinkKind.MOBILE;
                default: return InternetUplinkKind.OTHER;
            }
        }

        private string display_name(string device, string active) {
            if (client.device_type(device) == NmDeviceType.ETHERNET)
                return "Ethernet (%s)".printf(client.device_iface(device));
            return "%s (%s)".printf(client.active_id(active), client.device_iface(device));
        }
    }
}
