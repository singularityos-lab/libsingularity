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

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/firewall/ports", test_ports);
    Test.add_func ("/firewall/state", test_state);
    Test.add_func ("/hostname/static-name", test_hostname);
    return Test.run ();
}
