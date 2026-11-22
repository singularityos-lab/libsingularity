using GLib;

namespace Singularity {

    public class ModemError {

        public static string? settings_page(Error e) {
            string remote = DBusError.get_remote_error(e) ?? "";
            if (remote.has_suffix(".NotRegistered")) return "network-mobile";
            if (remote.has_suffix(".ServiceUnknown") || remote.has_suffix(".NameHasNoOwner") || remote.has_suffix(".UnknownObject")
                || remote.has_suffix(".ESIM.Error.NoChip"))
                return "dev-modem";
            return null;
        }

        public static Widgets.Toast toast(Error e) {
            return toast_for(describe(e), settings_page(e));
        }

        public static Widgets.Toast toast_for(string text, string? page) {
            var toast = new Widgets.Toast(text);
            if (page != null) {
                string target = page;
                toast.timeout = 10;
                toast.button_label = _("Settings");
                toast.button_clicked.connect(() => open_settings.begin(target));
            }
            return toast;
        }

        private static async void open_settings(string page) {
            try {
                var bus = yield Bus.get(BusType.SESSION);
                yield bus.call("dev.sinty.desktop", "/dev/sinty/Shell", "dev.sinty.Shell", "OpenSettings",
                    new Variant("(s)", page), null, DBusCallFlags.NONE, 5000);
            } catch (Error e) {
                warning("open settings: %s", e.message);
            }
        }

        public static string describe(Error e) {
            string remote = DBusError.get_remote_error(e) ?? "";
            if (remote.has_suffix(".Unauthorized")) return _("Permission was not given.");
            if (remote.has_suffix(".NotRegistered")) return _("There is no mobile network yet. Check the SIM or eSIM in Settings.");
            if (remote.has_suffix(".IncorrectPassword")) return _("That code is not right.");
            if (remote.has_suffix(".ESIM.Error.NoChip")) return _("The eSIM chip did not answer. Switch to the eSIM or restart the modem from Developer settings.");
            if (remote.has_suffix(".ESIM.Error.NoProfile")) return _("This eSIM is no longer on the device.");
            if (remote.has_suffix(".ESIM.Error.Active")) return _("Turn the eSIM off before deleting it.");
            if (remote.has_suffix(".ESIM.Error.InvalidCode")) return _("This is not an eSIM activation code. It starts with LPA:1$");
            if (remote.has_suffix(".ESIM.Error.ConfirmationNeeded")) return _("Enter the confirmation code from your carrier.");
            if (remote.has_suffix(".ESIM.Error.InvalidName")) return _("That name is too long.");
            if (remote.has_suffix(".InvalidArgs") && "access point" in e.message) return _("That access point name is not valid.");
            if (remote.has_suffix(".ServiceUnknown") || remote.has_suffix(".NameHasNoOwner") || remote.has_suffix(".UnknownObject"))
                return _("The modem service is not running. Restart the modem from Developer settings.");
            if (e is IOError.TIMED_OUT) return _("The modem took too long to answer.");
            var copy = e.copy();
            DBusError.strip_remote_error(copy);
            return copy.message;
        }
    }
}
