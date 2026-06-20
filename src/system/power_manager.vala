using UPower;

namespace Singularity {

    public class PowerManager : Object {
        public double percentage { get; private set; default = 0.0; }
        public bool is_charging { get; private set; default = false; }
        public bool is_present { get; private set; default = false; }
        public string icon_name { get; private set; default = "battery-missing-symbolic"; }
        public int64 time_to_empty { get; private set; default = 0; }
        public int64 time_to_full { get; private set; default = 0; }
        public signal void state_changed();
        private UPower.Client client;
        private UPower.Device? display_device;

        public PowerManager() {
            try {
                client = new UPower.Client();
                display_device = client.get_display_device();
                if (display_device != null) {
                    update_state();
                    display_device.notify.connect(() => {
                        update_state();
                    });
                }
                // Note: UpClient.device-changed was removed in UPower 0.99.
                // display_device.notify already covers all property-change updates.
            } catch (Error e) {
                warning("Failed to initialize UPower: %s", e.message);
            }
        }

        private void update_state() {
            if (display_device == null) return;
            percentage = display_device.percentage;
            icon_name = display_device.icon_name;
            if (icon_name == null || icon_name == "") {
                if (percentage < 20) icon_name = "battery-level-10-symbolic";
                else if (percentage < 40) icon_name = "battery-level-30-symbolic";
                else if (percentage < 60) icon_name = "battery-level-50-symbolic";
                else if (percentage < 80) icon_name = "battery-level-70-symbolic";
                else icon_name = "battery-level-100-symbolic";
            }
            var state = display_device.state;
            // A battery is "present" if it exists and is not in UNKNOWN/EMPTY state
            // with 0% (which typically means desktop with no battery)
            is_present = (display_device.kind == UPower.DeviceKind.BATTERY ||
                          display_device.kind == UPower.DeviceKind.UPS) &&
                          percentage > 0.0;
            is_charging = (state == UPower.DeviceState.CHARGING || state == UPower.DeviceState.PENDING_CHARGE);
            time_to_empty = display_device.time_to_empty;
            time_to_full = display_device.time_to_full;
            state_changed();
        }
    }
}
