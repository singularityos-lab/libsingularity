using Singularity;

void test_ports () {
    int a, b;
    string proto;
    assert (FirewallPorts.parse ("5900/tcp", out a, out b, out proto) && a == 5900 && b == 5900 && proto == "tcp");
    assert (FirewallPorts.parse (" 1714-1764/UDP ", out a, out b, out proto) && a == 1714 && b == 1764 && proto == "udp");
    assert (!FirewallPorts.parse ("0/tcp", out a, out b, out proto));
    assert (!FirewallPorts.parse ("70000/tcp", out a, out b, out proto));
    assert (!FirewallPorts.parse ("80/sctp", out a, out b, out proto));
    assert (!FirewallPorts.parse ("90-80/tcp", out a, out b, out proto));
    assert (!FirewallPorts.parse ("80-80/tcp", out a, out b, out proto));
    assert (!FirewallPorts.parse ("80;drop/tcp", out a, out b, out proto));
    assert (FirewallPorts.valid ({ "80/tcp", "53/udp" }));
    assert (!FirewallPorts.valid ({}));
    assert (FirewallPorts.valid_id ("remote-desktop"));
    assert (!FirewallPorts.valid_id ("Remote Desktop"));
    assert (FirewallPorts.clean_label ("Say \"hi\"\n") == "Say hi");
    assert (FirewallPorts.clean_label ("") == "App");
}

void test_state () {
    var st = NftablesBackend.parse_state ("enabled 1\nprofile public\nrule nearby 1 1714-1764/tcp,1714-1764/udp Nearby Devices\nrule x\n");
    assert (st.enabled);
    assert (st.profile == FirewallProfile.PUBLIC);
    assert (st.rules.size == 1);
    assert (st.rules[0].id == "nearby" && st.rules[0].label == "Nearby Devices" && st.rules[0].public_too);
    assert (st.rules[0].ports.length == 2);
    assert (st.rules[0].ports_text () == "1714-1764 TCP, 1714-1764 UDP");
    var empty = NftablesBackend.parse_state ("");
    assert (!empty.enabled && empty.profile == FirewallProfile.HOME && empty.rules.size == 0);
}

void test_hostname () {
    assert (HostnameManager.static_name ("Mirko's Laptop") == "mirko-s-laptop");
    assert (HostnameManager.static_name ("Città  Nuova!") == "citta-nuova");
    assert (HostnameManager.static_name ("***") == "computer");
    assert (HostnameManager.static_name (string.nfill (80, 'a')).length == 63);
    assert (HostnameManager.display_name ("  ", "box") == "box");
    assert (HostnameManager.display_name ("My Box", "box") == "My Box");
}

[DBus (name = "dev.sinty.Firewall1.Error")]
public errordomain MockFirewallError {
    [DBus (name = "Invalid")]
    INVALID
}

public struct MockRule {
    public string id;
    public bool public_too;
    public string ports;
    public string label;
}

[DBus (name = "dev.sinty.Firewall1")]
public class MockFirewall : Object {
    public bool enabled = true;
    public string profile = "home";
    public MockRule[] rules = {};

    public void status (out bool enabled, out string profile, out MockRule[] rules) throws Error {
        enabled = this.enabled;
        profile = this.profile;
        rules = this.rules;
    }

    public void set_enabled (bool on) throws Error {
        enabled = on;
    }

    public void set_profile (string name) throws Error {
        if (name != "home" && name != "public") throw new MockFirewallError.INVALID ("the profile is home or public");
        profile = name;
    }

    public void allow (string id, bool public_too, string ports, string label) throws Error {
        if (!FirewallPorts.valid_id (id)) throw new MockFirewallError.INVALID ("bad id");
        MockRule[] kept = {};
        foreach (var r in rules) if (r.id != id) kept += r;
        kept += MockRule () { id = id, public_too = public_too, ports = ports, label = label };
        rules = kept;
    }

    public void revoke (string id) throws Error {
        MockRule[] kept = {};
        foreach (var r in rules) if (r.id != id) kept += r;
        rules = kept;
    }
}

delegate void AsyncStep (SourceFunc done) throws Error;

void drive (owned AsyncStep step) {
    var loop = new MainLoop ();
    Idle.add (() => {
        try {
            step (() => { loop.quit (); return false; });
        } catch (Error e) {
            error ("%s", e.message);
        }
        return Source.REMOVE;
    });
    loop.run ();
}

void test_sinty_backend () {
    var bus = new TestDBus (TestDBusFlags.NONE);
    bus.up ();
    Environment.set_variable ("DBUS_SYSTEM_BUS_ADDRESS", bus.get_bus_address (), true);
    var mock = new MockFirewall ();
    try {
        var conn = Bus.get_sync (BusType.SYSTEM);
        conn.register_object ("/dev/sinty/Firewall1", mock);
        conn.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            new Variant ("(su)", "dev.sinty.Firewall1", 0), null, DBusCallFlags.NONE, -1);
    } catch (Error e) {
        error ("mock: %s", e.message);
    }
    var b = new SintyFirewallBackend ();
    bool available = false;
    FirewallStatus? st = null;
    Error? failure = null;
    drive ((done) => {
        b.is_available.begin ((o, r) => { available = b.is_available.end (r); done (); });
    });
    assert (available);
    drive ((done) => {
        b.allow.begin (new FirewallRule ("ssh", "Remote \"Login\"", { " 22/TCP ", "6000-6010/udp" }, true), (o, r) => {
            try { b.allow.end (r); } catch (Error e) { failure = e; }
            done ();
        });
    });
    assert (failure == null);
    assert (mock.rules.length == 1 && mock.rules[0].ports == "22/tcp,6000-6010/udp" && mock.rules[0].label == "Remote Login");
    drive ((done) => {
        b.set_profile.begin (FirewallProfile.PUBLIC, (o, r) => {
            try { b.set_profile.end (r); } catch (Error e) { failure = e; }
            done ();
        });
    });
    drive ((done) => {
        b.status.begin ((o, r) => {
            try { st = b.status.end (r); } catch (Error e) { failure = e; }
            done ();
        });
    });
    assert (failure == null && st != null);
    assert (st.enabled && st.profile == FirewallProfile.PUBLIC && st.rules.size == 1);
    assert (st.rules[0].id == "ssh" && st.rules[0].public_too && st.rules[0].ports.length == 2);
    drive ((done) => {
        b.allow.begin (new FirewallRule ("Bad Id", "X", { "1/tcp" }, false), (o, r) => {
            try { b.allow.end (r); } catch (Error e) { failure = e; }
            done ();
        });
    });
    assert (failure is FirewallError.INVALID);
    failure = null;
    drive ((done) => {
        b.revoke.begin ("ssh", (o, r) => {
            try { b.revoke.end (r); } catch (Error e) { failure = e; }
            done ();
        });
    });
    assert (failure == null && mock.rules.length == 0);
    bus.down ();
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/firewall/ports", test_ports);
    Test.add_func ("/firewall/state", test_state);
    Test.add_func ("/hostname/static-name", test_hostname);
    Test.add_func ("/firewall/sinty-backend", test_sinty_backend);
    return Test.run ();
}
