using GLib;

namespace Singularity {

    public enum MobileCommand {
        SET_RADIO, SET_LTE_ONLY, SET_DATA, SET_ROAMING, SET_APN, GET_IMEI, SEND_PIN, SEND_PUK, CHANGE_PIN, SEARCH_NETWORKS, SELECT_NETWORK,
        GET_EID, LIST_PROFILES, ENABLE_PROFILE, DISABLE_PROFILE, RENAME_PROFILE, DELETE_PROFILE, ADD_PROFILE, SEND_NOTIFICATIONS,
        SELECT_SLOT, RESTART_SERVICE, RESTART_MODEM, DIAGNOSTICS, SET_STANDBY, SET_DATA_LINE, MODEM_REQUEST
    }

    public class MobileProfile : Object {
        public string iccid { get; construct; }
        public string name { get; construct; }
        public string nickname { get; construct; }
        public string provider { get; construct; }
        public bool enabled { get; construct; }

        public MobileProfile(string iccid, string name, string nickname, string provider, bool enabled) {
            Object(iccid: iccid, name: name, nickname: nickname, provider: provider, enabled: enabled);
        }

        public string title {
            owned get {
                if (nickname != "") return nickname;
                if (provider != "") return provider;
                return name != "" ? name : _("eSIM");
            }
        }
    }

    public class MobileOperator : Object {
        public string code { get; construct; }
        public uint status { get; construct; }

        public MobileOperator(string code, uint status) {
            Object(code: code, status: status);
        }
    }

    public class MobileNetwork : Object {
        public const uint SIM_SLOT = 0;
        public const uint ESIM_SLOT = 1;

        private const string MM_BUS = "org.freedesktop.ModemManager1";
        private const string MM_MODEM = "/org/freedesktop/ModemManager1/Modem/0";
        private const string MM_MODEM_IFACE = "org.freedesktop.ModemManager1.Modem";
        private const string MM_3GPP_IFACE = "org.freedesktop.ModemManager1.Modem.Modem3gpp";
        private const string MM_VOICE_IFACE = "org.freedesktop.ModemManager1.Modem.Voice";
        private const string MM_SIM_IFACE = "org.freedesktop.ModemManager1.Sim";
        private const string STACK_BUS = "dev.sinty.Modem1";
        private const string STACK_PATH = "/dev/sinty/Modem1";
        private const string DEVICE_CONFIG = "/run/sinty/modem.conf";
        private const int LONG_TIMEOUT = 360000;
        private const uint MODE_2G = 1 << 1;
        private const uint MODE_3G = 1 << 2;
        private const uint MODE_4G = 1 << 3;

        private static MobileNetwork? instance = null;
        private DBusConnection? bus = null;
        private string sim_path = "";
        private uint refresh_id = 0;

        public bool available { get; private set; default = false; }
        public int state { get; private set; default = 0; }
        public uint failed_reason { get; private set; default = 0; }
        public uint registration { get; private set; default = 4; }
        public uint technology { get; private set; default = 0; }
        public uint signal_quality { get; private set; default = 0; }
        public uint unlock_required { get; private set; default = 0; }
        public string operator_name { get; private set; default = ""; }
        public string revision { get; private set; default = ""; }
        public bool data_enabled { get; private set; default = false; }
        public bool roaming_enabled { get; private set; default = false; }
        public string apn { get; private set; default = ""; }
        public bool has_settings { get; private set; default = false; }
        public bool lte_only { get; private set; default = false; }
        public bool has_modes { get; private set; default = false; }
        public bool has_usage { get; private set; default = false; }
        public uint64 data_used { get; private set; default = 0; }
        public bool has_voice { get; private set; default = false; }
        public bool calls_ready { get; private set; default = false; }

        public signal void changed();

        public static MobileNetwork get_default() {
            if (instance == null) instance = new MobileNetwork();
            return instance;
        }

        public bool supported {
            get { return available || FileUtils.test(DEVICE_CONFIG, FileTest.EXISTS); }
        }

        public bool roaming {
            get { return registration == 5; }
        }

        public bool sim_missing {
            get { return state == -1 && failed_reason == 2; }
        }

        construct {
            start.begin();
        }

        private async void start() {
            try {
                bus = yield Bus.get(BusType.SYSTEM);
            } catch (Error e) {
                warning("mobile network: %s", e.message);
                return;
            }
            bus.signal_subscribe(MM_BUS, "org.freedesktop.DBus.Properties", "PropertiesChanged", MM_MODEM, null,
                DBusSignalFlags.NONE, () => queue_refresh());
            Bus.watch_name_on_connection(bus, MM_BUS, BusNameWatcherFlags.NONE,
                () => queue_refresh(), () => queue_refresh());
        }

        private void queue_refresh() {
            if (refresh_id != 0) return;
            refresh_id = Timeout.add(150, () => {
                refresh_id = 0;
                refresh.begin();
                return Source.REMOVE;
            });
        }

        private async Variant? read_properties(string iface) {
            try {
                var reply = yield bus.call(MM_BUS, MM_MODEM, "org.freedesktop.DBus.Properties", "GetAll",
                    new Variant("(s)", iface), new VariantType("(a{sv})"), DBusCallFlags.NO_AUTO_START, 5000);
                return reply.get_child_value(0);
            } catch (Error e) {
                return null;
            }
        }

        public async void refresh() {
            if (bus == null) return;
            var modem = yield read_properties(MM_MODEM_IFACE);
            var gpp = yield read_properties(MM_3GPP_IFACE);
            var voice = yield read_properties(MM_VOICE_IFACE);
            var emergency_only = voice != null ? voice.lookup_value("EmergencyOnly", VariantType.BOOLEAN) : null;
            has_voice = emergency_only != null;
            calls_ready = has_voice && !emergency_only.get_boolean();
            available = modem != null;
            state = 0;
            failed_reason = 0;
            registration = 4;
            technology = 0;
            signal_quality = 0;
            unlock_required = 0;
            operator_name = "";
            sim_path = "";
            lte_only = false;
            has_modes = false;
            if (modem != null) {
                var v = modem.lookup_value("State", VariantType.INT32);
                if (v != null) state = v.get_int32();
                v = modem.lookup_value("StateFailedReason", VariantType.UINT32);
                if (v != null) failed_reason = v.get_uint32();
                v = modem.lookup_value("AccessTechnologies", VariantType.UINT32);
                if (v != null) technology = v.get_uint32();
                v = modem.lookup_value("SignalQuality", new VariantType("(ub)"));
                if (v != null) signal_quality = v.get_child_value(0).get_uint32();
                v = modem.lookup_value("UnlockRequired", VariantType.UINT32);
                if (v != null) unlock_required = v.get_uint32();
                v = modem.lookup_value("Revision", VariantType.STRING);
                if (v != null) revision = v.get_string();
                v = modem.lookup_value("CurrentModes", new VariantType("(uu)"));
                if (v != null) {
                    has_modes = true;
                    lte_only = v.get_child_value(0).get_uint32() == MODE_4G;
                }
                v = modem.lookup_value("Sim", VariantType.OBJECT_PATH);
                if (v != null) sim_path = v.get_string();
            }
            if (gpp != null) {
                var v = gpp.lookup_value("RegistrationState", VariantType.UINT32);
                if (v != null) registration = v.get_uint32();
                v = gpp.lookup_value("OperatorName", VariantType.STRING);
                if (v != null) operator_name = v.get_string();
            }
            yield read_settings();
            yield read_usage();
            changed();
        }

        private async void read_usage() {
            has_usage = false;
            if (!available) return;
            try {
                var reply = yield bus.call(MM_BUS, "/dev/sinty/Modem1/Network", "dev.sinty.Modem1.Network", "GetUsage",
                    null, new VariantType("(tt)"), DBusCallFlags.NO_AUTO_START, 5000);
                data_used = reply.get_child_value(0).get_uint64() + reply.get_child_value(1).get_uint64();
                has_usage = true;
            } catch (Error e) {
                debug("mobile data usage: %s", e.message);
            }
        }

        private async void read_settings() {
            has_settings = false;
            if (!available) return;
            try {
                var reply = yield bus.call(MM_BUS, "/dev/sinty/Modem1/Network", "dev.sinty.Modem1.Network", "GetSettings",
                    null, new VariantType("(bbs)"), DBusCallFlags.NO_AUTO_START, 5000);
                data_enabled = reply.get_child_value(0).get_boolean();
                roaming_enabled = reply.get_child_value(1).get_boolean();
                apn = reply.get_child_value(2).get_string();
                has_settings = true;
            } catch (Error e) {
                debug("mobile network settings: %s", e.message);
            }
        }

        public async Variant run(MobileCommand command, Variant? args = null) throws Error {
            if (bus == null) bus = yield Bus.get(BusType.SYSTEM);
            string name = MM_BUS;
            string path = "/dev/sinty/Modem1/ESIM";
            string iface = "dev.sinty.Modem1.ESIM";
            Variant? body = args;
            string method = "";
            switch (command) {
                case MobileCommand.SET_RADIO:
                    path = MM_MODEM; iface = MM_MODEM_IFACE; method = "Enable"; break;
                case MobileCommand.SET_LTE_ONLY:
                    path = MM_MODEM; iface = MM_MODEM_IFACE; method = "SetCurrentModes";
                    bool only = args.get_child_value(0).get_boolean();
                    uint allowed = only ? MODE_4G : MODE_2G | MODE_3G | MODE_4G;
                    uint preferred = only ? 0 : MODE_4G;
                    body = new Variant("((uu))", allowed, preferred);
                    break;
                case MobileCommand.SET_DATA:
                case MobileCommand.SET_ROAMING:
                case MobileCommand.SET_APN:
                case MobileCommand.GET_IMEI:
                    path = "/dev/sinty/Modem1/Network";
                    iface = "dev.sinty.Modem1.Network";
                    if (command == MobileCommand.SET_DATA) method = "SetData";
                    else if (command == MobileCommand.SET_ROAMING) method = "SetRoaming";
                    else if (command == MobileCommand.SET_APN) method = "SetAPN";
                    else method = "GetIMEI";
                    break;
                case MobileCommand.SEND_PIN:
                case MobileCommand.SEND_PUK:
                    if (sim_path == "") throw new IOError.NOT_FOUND(_("No SIM"));
                    path = sim_path; iface = MM_SIM_IFACE;
                    method = command == MobileCommand.SEND_PIN ? "SendPin" : "SendPuk";
                    break;
                case MobileCommand.CHANGE_PIN:
                    if (sim_path == "") throw new IOError.NOT_FOUND(_("No SIM"));
                    path = sim_path; iface = MM_SIM_IFACE; method = "ChangePin"; break;
                case MobileCommand.SEARCH_NETWORKS:
                case MobileCommand.SELECT_NETWORK:
                    path = MM_MODEM; iface = MM_3GPP_IFACE;
                    method = command == MobileCommand.SEARCH_NETWORKS ? "Scan" : "Register";
                    break;
                case MobileCommand.GET_EID: method = "GetEID"; break;
                case MobileCommand.LIST_PROFILES: method = "ListProfiles"; break;
                case MobileCommand.ENABLE_PROFILE: method = "EnableProfile"; break;
                case MobileCommand.DISABLE_PROFILE: method = "DisableProfile"; break;
                case MobileCommand.RENAME_PROFILE: method = "RenameProfile"; break;
                case MobileCommand.DELETE_PROFILE: method = "DeleteProfile"; break;
                case MobileCommand.ADD_PROFILE: method = "AddProfile"; break;
                case MobileCommand.SEND_NOTIFICATIONS: method = "SendNotifications"; break;
                case MobileCommand.SELECT_SLOT:
                case MobileCommand.RESTART_SERVICE:
                case MobileCommand.SET_STANDBY:
                case MobileCommand.SET_DATA_LINE:
                case MobileCommand.MODEM_REQUEST:
                    path = MM_MODEM;
                    iface = "dev.sinty.Modem1.Recovery";
                    if (command == MobileCommand.SELECT_SLOT) method = "SelectSlot";
                    else if (command == MobileCommand.SET_STANDBY) method = "SetStandby";
                    else if (command == MobileCommand.SET_DATA_LINE) method = "SetDataLine";
                    else if (command == MobileCommand.MODEM_REQUEST) method = "Request";
                    else method = "Restart";
                    break;
                case MobileCommand.RESTART_MODEM:
                case MobileCommand.DIAGNOSTICS:
                    name = STACK_BUS;
                    path = STACK_PATH;
                    iface = "dev.sinty.Modem1.Stack";
                    method = command == MobileCommand.RESTART_MODEM ? "Restart" : "Diagnostics";
                    break;
            }
            try {
                return yield bus.call(name, path, iface, method, body, null,
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, LONG_TIMEOUT);
            } finally {
                queue_refresh();
            }
        }

        public async Gee.List<MobileOperator> search_operators() throws Error {
            var list = new Gee.ArrayList<MobileOperator>();
            var items = (yield run(MobileCommand.SEARCH_NETWORKS)).get_child_value(0);
            for (size_t i = 0; i < items.n_children(); i++) {
                var item = items.get_child_value(i);
                var code = item.lookup_value("operator-code", VariantType.STRING);
                var status = item.lookup_value("status", VariantType.UINT32);
                if (code != null) list.add(new MobileOperator(code.get_string(), status != null ? status.get_uint32() : 0));
            }
            return list;
        }

        public async Gee.List<MobileProfile> list_profiles() throws Error {
            var list = new Gee.ArrayList<MobileProfile>();
            var items = (yield run(MobileCommand.LIST_PROFILES)).get_child_value(0);
            for (size_t i = 0; i < items.n_children(); i++) {
                var p = items.get_child_value(i);
                list.add(new MobileProfile(p.get_child_value(0).get_string(), p.get_child_value(1).get_string(),
                    p.get_child_value(2).get_string(), p.get_child_value(3).get_string(), p.get_child_value(4).get_boolean()));
            }
            return list;
        }
    }
}
