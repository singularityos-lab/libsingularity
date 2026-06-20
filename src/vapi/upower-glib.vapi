[CCode (cheader_filename = "libupower-glib/upower.h")]
namespace UPower {
    [CCode (cname = "UpClient", cprefix = "up_client_", type_id = "up_client_get_type ()")]
    public class Client : GLib.Object {
        public Client ();
        public static UPower.Client new_full (GLib.Cancellable? cancellable = null) throws GLib.Error;
        public UPower.Device get_display_device ();
        public GLib.PtrArray get_devices ();
        public string get_critical_action ();
        public bool get_on_battery ();
        public bool get_lid_is_closed ();
        public bool get_lid_is_present ();
        
        public signal void device_added (UPower.Device device);
        public signal void device_removed (UPower.Device device);
        public signal void device_changed (UPower.Device device);
    }

    [CCode (cname = "UpDevice", cprefix = "up_device_", type_id = "up_device_get_type ()")]
    public class Device : GLib.Object {
        [NoAccessorMethod]
        public double percentage { get; }
        [NoAccessorMethod]
        public UPower.DeviceState state { get; }
        [NoAccessorMethod]
        public UPower.DeviceKind kind { get; }
        [NoAccessorMethod]
        public string icon_name { owned get; }
        [NoAccessorMethod]
        public bool is_present { get; }
        [NoAccessorMethod]
        public bool is_rechargeable { get; }
        [NoAccessorMethod]
        public int64 time_to_empty { get; }
        [NoAccessorMethod]
        public int64 time_to_full { get; }
    }

    [CCode (cname = "UpDeviceState", cprefix = "UP_DEVICE_STATE_", has_type_id = false)]
    public enum DeviceState {
        UNKNOWN,
        CHARGING,
        DISCHARGING,
        EMPTY,
        FULLY_CHARGED,
        PENDING_CHARGE,
        PENDING_DISCHARGE
    }

    [CCode (cname = "UpDeviceKind", cprefix = "UP_DEVICE_KIND_", has_type_id = false)]
    public enum DeviceKind {
        UNKNOWN,
        LINE_POWER,
        BATTERY,
        UPS,
        MONITOR,
        MOUSE,
        KEYBOARD,
        PDA,
        PHONE,
        MEDIA_PLAYER,
        TABLET,
        COMPUTER,
        GAMING_INPUT,
        PEN,
        VIDEO,
        HEADPHONES,
        HEADSET,
        MICROPHONE,
        OTHER,
        LAST
    }
}
