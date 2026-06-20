using GLib;

namespace Singularity {

    [DBus (name = "org.freedesktop.timedate1")]
    public interface Timedate1 : Object {
        public abstract string timezone { owned get; }
        public abstract bool local_rtc { owned get; }
        public abstract bool ntp { owned get; }
        public abstract void set_time(int64 usec_utc, bool relative, bool interactive) throws Error;
        public abstract void set_timezone(string timezone, bool interactive) throws Error;
        public abstract void set_local_rtc(bool local_rtc, bool fix_system, bool interactive) throws Error;
        public abstract void set_ntp(bool use_ntp, bool interactive) throws Error;
    }

    public class DateTimeManager : Object {
        private Timedate1? proxy;

        public string timezone { get; private set; default = "UTC"; }
        public bool ntp_active { get; private set; default = false; }
        public signal void state_changed();

        public DateTimeManager() {
            init_async.begin();
        }

        private async void init_async() {
            try {

                proxy = yield Bus.get_proxy(BusType.SYSTEM, "org.freedesktop.timedate1", "/org/freedesktop/timedate1");
                message("DateTimeManager: Connected to org.freedesktop.timedate1");

                proxy.notify["ntp"].connect(() => {
                    ntp_active = proxy.ntp;
                    state_changed();
                });
                proxy.notify["timezone"].connect(() => {
                    timezone = proxy.timezone;
                    state_changed();
                });

                ntp_active = proxy.ntp;
                timezone = proxy.timezone;
                state_changed();
            } catch (Error e) {
                warning("Failed to connect to timedate1: %s", e.message);
            }
        }


        public void set_ntp(bool active) {
            if (proxy == null) return;
            try {
                proxy.set_ntp(active, true);
            } catch (Error e) {
                warning("Failed to set NTP: %s", e.message);
            }
        }

        public void update_timezone(string tz) {
            if (proxy == null) return;
            try {
                proxy.set_timezone(tz, true);
            } catch (Error e) {
                warning("Failed to set timezone: %s", e.message);
            }
        }

        public void set_time(int64 usec_utc) {
            if (proxy == null) return;
            try {
                proxy.set_time(usec_utc, false, true);
            } catch (Error e) {
                warning("Failed to set time: %s", e.message);
            }
        }
    }
}
