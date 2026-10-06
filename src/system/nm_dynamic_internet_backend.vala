using NM;

namespace Singularity {

    public class NetworkManagerDynamicInternetBackend : GLib.Object, DynamicInternetBackend {
        private const int64 PREFERRED_METRIC = 50;
        private const int64 STANDBY_METRIC = 600;
        private const uint CHECKPOINT_SECONDS = 12;

        public string name { owned get { return "NetworkManager"; } }

        private NM.Client client;
        private HashTable<string, int64?> original_ip4 =
            new HashTable<string, int64?>(str_hash, str_equal);
        private HashTable<string, int64?> original_ip6 =
            new HashTable<string, int64?>(str_hash, str_equal);
        private int probe_target;

        [CCode (cname = "singularity_socket_bind_to_device",
                cheader_filename = "src/system/dynamic_internet_socket.h")]
        private static extern bool bind_to_device(GLib.Socket socket, string interface_name)
            throws GLib.Error;

        public NetworkManagerDynamicInternetBackend(NM.Client client) {
            this.client = client;
            client.active_connection_added.connect(() => changed());
            client.active_connection_removed.connect(() => changed());
            client.device_added.connect(() => changed());
            client.device_removed.connect(() => changed());
        }

        public async Gee.List<InternetUplink> probe(Cancellable? cancellable) throws Error {
            var result = new Gee.ArrayList<InternetUplink>();
            foreach (var device in client.get_devices()) {
                if (!is_uplink(device) || device.get_state() != NM.DeviceState.ACTIVATED) continue;
                var active = device.get_active_connection();
                if (active == null || active.get_vpn()) continue;

                string iface = device.get_iface();
                var uplink = new InternetUplink(iface, iface, display_name(device, active),
                    kind_for(device.get_device_type()));
                uplink.primary = active.get_default();
                uplink.captive = device.get_connectivity(Posix.AF_INET) == NM.ConnectivityState.PORTAL;
                var metered = (NM.Metered) device.metered;
                uplink.metered = metered == NM.Metered.YES || metered == NM.Metered.GUESS_YES;
                uplink.latency_ms = yield measure_latency(device, cancellable);
                uplink.reachable = !uplink.captive && uplink.latency_ms >= 0;
                result.add(uplink);
            }
            probe_target = (probe_target + 1) % 2;
            return result;
        }

        public async void prefer(string uplink_id, Cancellable? cancellable) throws Error {
            var devices = active_uplinks();
            NM.Device? preferred = null;
            foreach (var device in devices.data) {
                if (device.get_iface() == uplink_id) preferred = device;
            }
            if (preferred == null) throw new IOError.NOT_FOUND("Connection is no longer available");

            var checkpoint = yield client.checkpoint_create(devices, CHECKPOINT_SECONDS,
                NM.CheckpointCreateFlags.ALLOW_OVERLAPPING, cancellable);
            try {
                foreach (var device in devices.data)
                    yield set_metric(device, device == preferred ? PREFERRED_METRIC : STANDBY_METRIC,
                        cancellable);

                int latency = yield measure_latency(preferred, cancellable);
                if (latency < 0) {
                    throw new IOError.HOST_UNREACHABLE("The selected connection failed its safety check");
                }
                yield client.checkpoint_destroy(checkpoint.get_path(), cancellable);
            } catch (Error e) {
                try {
                    yield client.checkpoint_rollback(checkpoint.get_path(), cancellable);
                } catch (Error rollback_error) {
                    warning("Dynamic Internet rollback failed: %s", rollback_error.message);
                }
                throw e;
            }
        }

        public async void reset(Cancellable? cancellable) throws Error {
            var devices = active_uplinks();
            foreach (var device in devices.data) {
                string iface = device.get_iface();
                if (!original_ip4.contains(iface) && !original_ip6.contains(iface)) continue;
                uint64 version;
                var applied = yield device.get_applied_connection_async(0, cancellable, out version);
                var ip4 = applied.get_setting_ip4_config();
                var ip6 = applied.get_setting_ip6_config();
                int64? metric4 = original_ip4[iface];
                int64? metric6 = original_ip6[iface];
                if (ip4 != null && metric4 != null) ip4.route_metric = metric4;
                if (ip6 != null && metric6 != null) ip6.route_metric = metric6;
                yield device.reapply_async(applied, version, 0, cancellable);
            }
            original_ip4.remove_all();
            original_ip6.remove_all();
        }

        private GenericArray<NM.Device> active_uplinks() {
            var result = new GenericArray<NM.Device>();
            foreach (var device in client.get_devices()) {
                if (is_uplink(device) && device.get_state() == NM.DeviceState.ACTIVATED)
                    result.add(device);
            }
            return result;
        }

        private async void set_metric(NM.Device device, int64 metric, Cancellable? cancellable)
            throws Error {
            uint64 version;
            var applied = yield device.get_applied_connection_async(0, cancellable, out version);
            string iface = device.get_iface();
            var ip4 = applied.get_setting_ip4_config();
            var ip6 = applied.get_setting_ip6_config();
            if (ip4 != null) {
                if (!original_ip4.contains(iface)) original_ip4[iface] = ip4.route_metric;
                ip4.route_metric = metric;
            }
            if (ip6 != null) {
                if (!original_ip6.contains(iface)) original_ip6[iface] = ip6.route_metric;
                ip6.route_metric = metric;
            }
            yield device.reapply_async(applied, version, 0, cancellable);
        }

        private async int measure_latency(NM.Device device, Cancellable? parent) {
            NM.IPConfig? config = device.get_ip4_config();
            bool ipv6 = false;
            if (config == null || config.get_addresses().length == 0) {
                config = device.get_ip6_config();
                ipv6 = true;
            }
            if (config == null || config.get_addresses().length == 0) return -1;
            string source = config.get_addresses().get(0).get_address();
            var source_address = new InetAddress.from_string(source);
            if (source_address == null) return -1;

            string target = ipv6
                ? (probe_target == 0 ? "2606:4700:4700::1111" : "2001:4860:4860::8888")
                : (probe_target == 0 ? "1.1.1.1" : "8.8.8.8");
            int latency = yield connect_latency(device.get_iface(), source_address, target, parent);
            if (latency >= 0 || (parent != null && parent.is_cancelled())) return latency;
            target = ipv6
                ? (probe_target == 0 ? "2001:4860:4860::8888" : "2606:4700:4700::1111")
                : (probe_target == 0 ? "8.8.8.8" : "1.1.1.1");
            return yield connect_latency(device.get_iface(), source_address, target, parent);
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

        private static bool is_uplink(NM.Device device) {
            switch (device.get_device_type()) {
                case NM.DeviceType.ETHERNET:
                case NM.DeviceType.WIFI:
                case NM.DeviceType.MODEM:
                case NM.DeviceType.BT:
                    return true;
                default:
                    return false;
            }
        }

        private static InternetUplinkKind kind_for(NM.DeviceType type) {
            switch (type) {
                case NM.DeviceType.ETHERNET: return InternetUplinkKind.ETHERNET;
                case NM.DeviceType.WIFI: return InternetUplinkKind.WIFI;
                case NM.DeviceType.MODEM:
                case NM.DeviceType.BT: return InternetUplinkKind.MOBILE;
                default: return InternetUplinkKind.OTHER;
            }
        }

        private static string display_name(NM.Device device, NM.ActiveConnection active) {
            if (device.get_device_type() == NM.DeviceType.ETHERNET)
                return "Ethernet (%s)".printf(device.get_iface());
            return "%s (%s)".printf(active.get_id(), device.get_iface());
        }
    }
}
