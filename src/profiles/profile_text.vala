using GLib;

namespace Singularity.Profiles {

    public string display_name(Profile p) {
        if (!p.builtin) return p.name;
        switch (p.id) {
            case "work": return _("Work");
            case "evening": return _("Evening");
            case "game": return _("Game");
            case "presentation": return _("Presentation");
            case "sleep": return _("Sleep");
        }
        return p.name;
    }

    public string area_label(string id) {
        switch (id) {
            case Areas.NOTIFICATIONS: return _("Notifications");
            case Areas.APPS: return _("Apps and Windows");
            case Areas.APPEARANCE: return _("Appearance");
            case Areas.DISPLAY: return _("Display");
            case Areas.ENERGY: return _("Energy");
            case Areas.AUDIO: return _("Sound");
            case Areas.BLUETOOTH: return _("Bluetooth");
            case Areas.VPN: return _("VPN");
            case Areas.PRINTER: return _("Printing");
            case Areas.SYSTEM: return _("System");
            case Areas.DOCK: return _("Dock");
            case Areas.LAUNCHER: return _("Launcher");
            case Areas.WIDGETS: return _("Widgets");
            case Areas.AGENT: return _("Sinty Agent");
        }
        return id;
    }

    public string days_text(int days) {
        if ((days & Condition.ALL_DAYS) == Condition.ALL_DAYS) return _("every day");
        if (days == 0x1f) return _("on weekdays");
        if (days == 0x60) return _("at weekends");
        string[] names = { _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat"), _("Sun") };
        string[] picked = {};
        for (int i = 0; i < 7; i++) {
            if ((days & (1 << i)) != 0) picked += names[i];
        }
        return string.joinv(", ", picked);
    }

    public string describe_condition(Condition c) {
        switch (c.kind) {
            case ConditionKind.TIME:
                return _("From %s to %s, %s").printf(Condition.format_minute(c.start_minute),
                    Condition.format_minute(c.end_minute), days_text(c.days));
            case ConditionKind.WIFI:
                return c.match == "" ? _("On any Wi-Fi network") : _("On the Wi-Fi network %s").printf(c.match);
            case ConditionKind.SCREEN:
                return c.match == "" ? _("With an external screen connected") : _("With the screen %s connected").printf(c.match);
            case ConditionKind.DEVICE:
                return c.match == "" ? _("With a dock or device connected") : _("With %s connected").printf(c.match);
            case ConditionKind.FULLSCREEN:
                return _("While an app is full screen");
            case ConditionKind.GAME:
                return _("While a game is running");
            case ConditionKind.PRESENTING:
                return _("While presenting or sharing the screen");
            case ConditionKind.KEY:
                return c.match == "" ? _("While a Sinty Key is inserted") : _("While the Sinty Key of %s is inserted").printf(c.match);
            default:
                return _("On battery below %d%%").printf(c.below_percent);
        }
    }

    public string describe_rule(Rule r) {
        string[] parts = {};
        foreach (var c in r.conditions) parts += describe_condition(c);
        return string.joinv(_(" and "), parts);
    }

    public string condition_kind_label(ConditionKind kind) {
        switch (kind) {
            case ConditionKind.TIME: return _("Time");
            case ConditionKind.WIFI: return _("Wi-Fi Network");
            case ConditionKind.SCREEN: return _("Screen Connected");
            case ConditionKind.DEVICE: return _("Dock or Device Connected");
            case ConditionKind.FULLSCREEN: return _("Full Screen App");
            case ConditionKind.GAME: return _("Game Running");
            case ConditionKind.PRESENTING: return _("Presenting");
            case ConditionKind.KEY: return _("Sinty Key Inserted");
            default: return _("Battery Low");
        }
    }
}
