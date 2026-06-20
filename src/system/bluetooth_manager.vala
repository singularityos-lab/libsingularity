using GLib;

namespace Singularity {

    [DBus (name = "org.freedesktop.DBus.ObjectManager")]
    public interface ObjectManager : Object {
        public abstract HashTable<ObjectPath, HashTable<string, HashTable<string, Variant>>> get_managed_objects () throws Error;
        public signal void interfaces_added (ObjectPath object_path, HashTable<string, HashTable<string, Variant>> interfaces_and_properties);
        public signal void interfaces_removed (ObjectPath object_path, string[] interfaces);
    }
    [DBus (name = "org.bluez.Adapter1")]
    public interface Adapter1 : Object {
        public abstract bool powered { get; set; }
        public abstract bool discovering { get; set; }
        public abstract string name { owned get; }
        public abstract string address { owned get; }
        public abstract async void start_discovery () throws Error;
        public abstract async void stop_discovery () throws Error;
        public abstract async void remove_device (ObjectPath device) throws Error;
    }
    [DBus (name = "org.bluez.Device1")]
    public interface Device1 : Object {
        public abstract string name { owned get; }
        public abstract string alias { owned get; }
        public abstract string address { owned get; }
        public abstract string icon { owned get; }
        public abstract bool paired { get; }
        public abstract bool connected { get; }
        public abstract bool trusted { get; set; }
        public abstract bool blocked { get; set; }
        public abstract int16 rssi { get; }
        public abstract async void connect () throws Error;
        public abstract async void disconnect () throws Error;
        public abstract async void pair () throws Error;
        public abstract async void cancel_pairing () throws Error;
    }
    [DBus (name = "org.bluez.AgentManager1")]
    public interface AgentManager1 : Object {
        public abstract async void register_agent (ObjectPath agent, string capability) throws Error;
        public abstract async void request_default_agent (ObjectPath agent) throws Error;
        public abstract async void unregister_agent (ObjectPath agent) throws Error;
    }

    [DBus (name = "org.bluez.Agent1")]
    public class BluetoothAgent : Object {
        public void release () throws Error { }
        public string request_pin_code (ObjectPath device) throws Error { return "0000"; }
        public uint32 request_passkey (ObjectPath device) throws Error { return 0; }
        public void display_pin_code (ObjectPath device, string pincode) throws Error { }
        public void display_passkey (ObjectPath device, uint32 passkey, uint16 entered) throws Error { }
        public void request_confirmation (ObjectPath device, uint32 passkey) throws Error { }
        public void request_authorization (ObjectPath device) throws Error { }
        public void authorize_service (ObjectPath device, string uuid) throws Error { }
        public void cancel () throws Error { }
    }

    public class BluetoothManager : Object {
        public struct DeviceInfo {
            public string path;
            public string name;
            public string address;
            public string icon;
            public bool paired;
            public bool connected;
            public int rssi;
        }
        private ObjectManager? object_manager;
        private Adapter1? adapter;
        private BluetoothAgent? agent;
        private uint agent_id = 0;
        private string adapter_path;
        public bool is_available { get; private set; default = false; }
        public bool is_powered { get; private set; default = false; }
        public bool is_discovering { get; private set; default = false; }
        public List<DeviceInfo?> devices;
        public signal void state_changed();
        public signal void device_added(DeviceInfo device);
        public signal void device_removed(string path);
        public signal void device_changed(string path);
        public string? connecting_path { get; private set; default = null; }

        public BluetoothManager() {
            devices = new List<DeviceInfo?>();
            init_bluez();
        }

        private async void init_bluez() {
            try {
                object_manager = yield Bus.get_proxy(BusType.SYSTEM, "org.bluez", "/");
                if (object_manager != null) {
                    message("BluetoothManager: Connected to org.bluez ObjectManager");
                    object_manager.interfaces_added.connect(on_interfaces_added);
                    object_manager.interfaces_removed.connect(on_interfaces_removed);
                    register_agent_flow.begin();
                    var objects = object_manager.get_managed_objects();
                    objects.foreach((path, interfaces) => {
                        if (interfaces.contains("org.bluez.Adapter1")) {
                            setup_adapter(path);
                        }
                        if (interfaces.contains("org.bluez.Device1")) {
                            var props = interfaces.get("org.bluez.Device1");
                            add_device(path, props != null ? props.lookup("Name") : null);
                        }
                    });
                } else {
                    warning("BluetoothManager: ObjectManager proxy is null");
                }
            } catch (Error e) {
                warning("Failed to connect to BlueZ: %s", e.message);
            }
        }

        private async void setup_adapter(string path) {
            try {
                adapter = yield Bus.get_proxy(BusType.SYSTEM, "org.bluez", path);
                adapter_path = path;
                is_available = true;
                adapter.notify["powered"].connect(() => {
                    is_powered = adapter.powered;
                    state_changed();
                });
                adapter.notify["discovering"].connect(() => {
                    is_discovering = adapter.discovering;
                    state_changed();
                });
                is_powered = adapter.powered;
                is_discovering = adapter.discovering;
                state_changed();
            } catch (Error e) {
                warning("Failed to setup adapter: %s", e.message);
            }
        }

        private void on_interfaces_added(ObjectPath path, HashTable<string, HashTable<string, Variant>> interfaces) {
            if (interfaces.contains("org.bluez.Adapter1") && adapter == null) {
                setup_adapter(path);
            }
            if (interfaces.contains("org.bluez.Device1")) {
                var props = interfaces.get("org.bluez.Device1");
                add_device(path, props != null ? props.lookup("Name") : null);
            }
        }

        private void on_interfaces_removed(ObjectPath path, string[] interfaces) {
            foreach (var iface in interfaces) {
                if (iface == "org.bluez.Adapter1" && path == adapter_path) {
                    adapter = null;
                    is_available = false;
                    state_changed();
                }
                if (iface == "org.bluez.Device1") {
                    remove_device_from_list(path);
                }
            }
        }

        private void add_device(string path, Variant? properties) {
            create_device_proxy.begin(path);
        }

        private async void create_device_proxy(string path) {
            try {
                var device = yield Bus.get_proxy<Device1>(BusType.SYSTEM, "org.bluez", path);
                if (device != null) {
                    for (int i = 0; i < devices.length(); i++) {
                        if (devices.nth_data(i).path == path) return;
                    }
                    DeviceInfo info = DeviceInfo();
                    info.path = path;
                    info.name = device.name ?? device.alias ?? device.address;
                    info.address = device.address;
                    info.icon = device.icon ?? "bluetooth-active-symbolic";
                    info.paired = device.paired;
                    info.connected = device.connected;
                    info.rssi = device.rssi;
                    devices.append(info);
                    device_added(info);
                    device.notify.connect((pspec) => {
                        if (pspec.get_name() == "rssi") return;
                        update_device_info(path, device);
                    });
                }
            } catch (Error e) {
                warning("Failed to create device proxy: %s", e.message);
            }
        }

        private void update_device_info(string path, Device1 device) {
            for (int i = 0; i < devices.length(); i++) {
                var d = devices.nth_data(i);
                if (d.path == path) {
                    DeviceInfo updated = DeviceInfo();
                    updated.path = path;
                    updated.name = device.name ?? device.alias ?? device.address;
                    updated.address = d.address;
                    updated.icon = d.icon;
                    updated.connected = device.connected;
                    updated.paired = device.paired;
                    updated.rssi = device.rssi;
                    devices.remove(d);
                    devices.insert(updated, i);
                    break;
                }
            }
            device_changed(path);
        }

        private void remove_device_from_list(string path) {
            for (int i = 0; i < devices.length(); i++) {
                var d = devices.nth_data(i);
                if (d.path == path) {
                    devices.remove(d);
                    device_removed(path);
                    return;
                }
            }
        }

        private async void register_agent_flow() {
            try {
                var conn = yield Bus.get(BusType.SYSTEM);
                agent = new BluetoothAgent();
                agent_id = conn.register_object("/dev/sinty/btagent", agent);
                AgentManager1 am = yield Bus.get_proxy(BusType.SYSTEM, "org.bluez", "/org/bluez");
                yield am.register_agent(new ObjectPath("/dev/sinty/btagent"), "NoInputNoOutput");
                yield am.request_default_agent(new ObjectPath("/dev/sinty/btagent"));
            } catch (Error e) {
                warning("Bluetooth agent registration failed: %s", e.message);
            }
        }

        public async void set_power(bool power) {
            if (adapter == null) return;
            if (!power && is_discovering) {
                try { yield adapter.stop_discovery(); } catch (Error e) { }
                if (is_discovering) {
                    is_discovering = false;
                    state_changed();
                }
            }
            adapter.powered = power;
            if (is_powered != power) {
                is_powered = power;
                state_changed();
            }
        }

        public async void start_discovery() {
            if (adapter == null) return;
            try {
                yield adapter.start_discovery();
            } catch (Error e) {
            }
            if (!is_discovering) {
                is_discovering = true;
                state_changed();
            }
        }

        public async void stop_discovery() {
            if (adapter == null) return;
            try {
                yield adapter.stop_discovery();
            } catch (Error e) {
            }
            if (is_discovering) {
                is_discovering = false;
                state_changed();
            }
        }

        public async void refresh() {
            if (object_manager == null) return;
            HashTable<ObjectPath, HashTable<string, HashTable<string, Variant>>> objects;
            try {
                objects = object_manager.get_managed_objects();
            } catch (Error e) {
                return;
            }
            var present = new GenericArray<string>();
            objects.foreach((path, interfaces) => {
                if (interfaces.contains("org.bluez.Device1")) present.add(path);
            });
            for (int i = 0; i < present.length; i++) {
                string p = present.get(i);
                bool known = false;
                for (int j = 0; j < devices.length(); j++) {
                    if (devices.nth_data(j).path == p) { known = true; break; }
                }
                if (!known) add_device(p, null);
            }
            var gone = new GenericArray<string>();
            for (int j = 0; j < devices.length(); j++) {
                string p = devices.nth_data(j).path;
                bool still = false;
                for (int i = 0; i < present.length; i++) {
                    if (present.get(i) == p) { still = true; break; }
                }
                if (!still) gone.add(p);
            }
            for (int k = 0; k < gone.length; k++) {
                remove_device_from_list(gone.get(k));
            }
            if (is_powered && adapter != null && !adapter.discovering) {
                start_discovery.begin();
            }
        }

        public async void connect_device(string path) {
            connecting_path = path;
            device_changed(path);
            try {
                var device = yield Bus.get_proxy<Device1>(BusType.SYSTEM, "org.bluez", path);
                if (device != null) {
                    if (!device.paired) {
                        yield device.pair();
                    }
                    device.trusted = true;
                    yield device.connect();
                }
            } catch (Error e) {
                warning("Connect failed: %s", e.message);
            }
            connecting_path = null;
            device_changed(path);
        }

        public DeviceInfo? get_connected_device() {
            for (int i = 0; i < devices.length(); i++) {
                var d = devices.nth_data(i);
                if (d.connected) return d;
            }
            return null;
        }

        public static string bt_icon_for(string? bluez_icon) {
            switch (bluez_icon ?? "") {
                case "phone":            return "phone-symbolic";
                case "audio-headset":    return "audio-headset-symbolic";
                case "audio-headphones": return "audio-headphones-symbolic";
                case "audio-card":       return "audio-speakers-symbolic";
                case "input-mouse":      return "input-mouse-symbolic";
                case "input-keyboard":   return "input-keyboard-symbolic";
                case "input-gaming":     return "input-gaming-symbolic";
                case "input-tablet":     return "input-tablet-symbolic";
                case "camera-photo":
                case "camera-video":     return "camera-photo-symbolic";
                case "computer":         return "computer-symbolic";
                case "printer":          return "printer-symbolic";
                default:                 return "bluetooth-active-symbolic";
            }
        }

        public async void disconnect_device(string path) {
            try {
                var device = yield Bus.get_proxy<Device1>(BusType.SYSTEM, "org.bluez", path);
                if (device != null) {
                    yield device.disconnect();
                }
            } catch (Error e) {
                warning("Disconnect failed: %s", e.message);
            }
        }

        public async void remove_device(string path) {
            if (adapter != null) {
                try {
                    yield adapter.remove_device(new ObjectPath(path));
                } catch (Error e) {
                    warning("Remove device failed: %s", e.message);
                }
            }
        }
    }
}
