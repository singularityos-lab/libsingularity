using Singularity;

const string KEY_A = "YFyEp8Qx2O2zOUmRkFmUuKZ1lHM7iQ3vU2b9bXJ3Kmw=";
const string KEY_B = "XXdiHLHmLJB8JTBL4XrxxseidpQllzP43uhdKHH5zFQ=";
const string KEY_C = "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=";

Variant? setting (Variant settings, string group, string key) {
    var g = settings.lookup_value (group, new VariantType ("a{sv}"));
    if (g == null) return null;
    return g.lookup_value (key, null);
}

void test_addresses () {
    assert (NmClient.ipv4_valid ("192.168.1.1"));
    assert (!NmClient.ipv4_valid ("192.168.1"));
    assert (!NmClient.ipv4_valid ("fd00::1"));
    uint8[] raw = { 192, 168, 1, 1 };
    uint32 expected = 0;
    Memory.copy (&expected, raw, 4);
    assert (NmClient.ipv4_value ("192.168.1.1") == expected);
    assert (NmClient.ipv4_text (expected) == "192.168.1.1");
    assert (NmClient.ipv4_text (NmClient.ipv4_value ("9.9.9.10")) == "9.9.9.10");
    assert (NmClient.ssid_text (NmClient.ssid_bytes ("Caffè")) == "Caffè");
    assert (NmClient.new_uuid ().length == 36);
    assert (NmClient.new_uuid () != NmClient.new_uuid ());
}

void test_wireguard_conf () throws Error {
    string conf = """
[Interface]
PrivateKey = %s
Address = 10.8.0.2/24, fd00::2/64
DNS = 9.9.9.9, fd00::53, corp.example
ListenPort = 51820
MTU = 1380

[Peer]
PublicKey = %s
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.org:51820
PersistentKeepalive = 25

[Peer]
PublicKey = %s
PresharedKey = %s
AllowedIPs = 10.9.0.0/16
""".printf (KEY_A, KEY_B, KEY_C, KEY_A);
    var s = NmImport.wireguard_conf (conf, "office");
    assert (setting (s, "connection", "id").get_string () == "office");
    assert (setting (s, "connection", "type").get_string () == "wireguard");
    assert (!setting (s, "connection", "autoconnect").get_boolean ());
    assert (setting (s, "wireguard", "private-key").get_string () == KEY_A);
    assert (setting (s, "wireguard", "listen-port").get_uint32 () == 51820);
    assert (setting (s, "wireguard", "mtu").get_uint32 () == 1380);
    var peers = setting (s, "wireguard", "peers");
    assert (peers.n_children () == 2);
    var first = peers.get_child_value (0);
    assert (first.lookup_value ("public-key", VariantType.STRING).get_string () == KEY_B);
    assert (first.lookup_value ("endpoint", VariantType.STRING).get_string () == "vpn.example.org:51820");
    assert (first.lookup_value ("persistent-keepalive", VariantType.UINT32).get_uint32 () == 25);
    var ips = first.lookup_value ("allowed-ips", VariantType.STRING_ARRAY).get_strv ();
    assert (ips.length == 2 && ips[0] == "0.0.0.0/0" && ips[1] == "::/0");
    var second = peers.get_child_value (1);
    assert (second.lookup_value ("preshared-key", VariantType.STRING).get_string () == KEY_A);
    assert (setting (s, "ipv4", "method").get_string () == "manual");
    assert (setting (s, "ipv6", "method").get_string () == "manual");
    var conn = new NmConnection.detached (s);
    var addrs = conn.ipv4_addresses ();
    assert (addrs.length == 1 && addrs[0] == "10.8.0.2/24");
    var a6 = setting (s, "ipv6", "address-data").get_child_value (0);
    assert (a6.lookup_value ("address", VariantType.STRING).get_string () == "fd00::2");
    assert (a6.lookup_value ("prefix", VariantType.UINT32).get_uint32 () == 64);
    var dns = conn.ipv4_dns ();
    assert (dns.length == 1 && dns[0] == "9.9.9.9");
    assert (setting (s, "ipv6", "dns").n_children () == 1);
}

void test_wireguard_errors () {
    string[] bad = {
        "[Interface]\nPrivateKey = %s\n[Peer]\nAllowedIPs = 0.0.0.0/0\n".printf (KEY_A),
        "[Interface]\nPrivateKey = short\n",
        "[Interface]\nPrivateKey = %s\n[Wat]\n".printf (KEY_A),
        "PrivateKey = %s\n".printf (KEY_A),
        "[Interface]\nPrivateKey = %s\nAddress = 10.0.0.1/40\n".printf (KEY_A),
        "[Interface]\nPrivateKey = %s\n[Peer]\nPublicKey = %s\nBogus = 1\n".printf (KEY_A, KEY_B),
    };
    foreach (var text in bad) {
        bool failed = false;
        try {
            NmImport.wireguard_conf (text, "x");
        } catch (Error e) {
            failed = e is NmImportError.INVALID;
        }
        assert (failed);
    }
}

void test_wireguard_manual () throws Error {
    var s = NmImport.wireguard_manual ("home", KEY_A, "10.0.0.5/32", "1.1.1.1", KEY_B, "h.example:51820", "", null);
    var peer = setting (s, "wireguard", "peers").get_child_value (0);
    var ips = peer.lookup_value ("allowed-ips", VariantType.STRING_ARRAY).get_strv ();
    assert (ips.length == 2 && ips[0] == "0.0.0.0/0" && ips[1] == "::/0");
    assert (peer.lookup_value ("preshared-key", null) == null);
    assert (setting (s, "ipv4", "method").get_string () == "manual");
    assert (setting (s, "ipv6", "method").get_string () == "disabled");
}

void test_keyfile () throws Error {
    var kf = new KeyFile ();
    kf.load_from_data ("""
[connection]
id=Cafe
uuid=0b8ad2b5-41a3-4c86-9a3b-6a2a7c1b6c11
type=wifi
autoconnect=false
autoconnect-priority=-5

[wifi]
mode=infrastructure
ssid=Caffè Rosso
mac-address=A8:59:5F:54:2F:E5
seen-bssids=00:11:22:33:44:55;

[wifi-security]
key-mgmt=wpa-psk
psk=hunter22

[ipv4]
method=manual
address1=192.168.1.20/24,192.168.1.1
dns=9.9.9.9;1.1.1.1;
route1=10.0.0.0/8,192.168.1.254,50
route1_options=onlink=true
route-metric=600

[ipv6]
method=auto
""", -1, KeyFileFlags.NONE);
    var s = NmImport.keyfile (kf);
    var conn = new NmConnection.detached (s);
    assert (conn.get_id () == "Cafe");
    assert (conn.get_uuid () == "0b8ad2b5-41a3-4c86-9a3b-6a2a7c1b6c11");
    assert (conn.get_connection_type () == "802-11-wireless");
    assert (!conn.autoconnect);
    assert (setting (s, "connection", "autoconnect-priority").get_int32 () == -5);
    assert (conn.wifi_ssid () == "Caffè Rosso");
    assert (!conn.is_hotspot ());
    var mac = setting (s, "802-11-wireless", "mac-address");
    assert (mac.get_type_string () == "ay" && mac.n_children () == 6);
    assert (mac.get_child_value (0).get_byte () == 0xa8 && mac.get_child_value (5).get_byte () == 0xe5);
    assert (setting (s, "802-11-wireless", "seen-bssids").get_strv ().length == 1);
    assert (setting (s, "802-11-wireless-security", "psk").get_string () == "hunter22");
    assert (conn.ipv4_method () == "manual");
    assert (conn.ipv4_gateway () == "192.168.1.1");
    var addrs = conn.ipv4_addresses ();
    assert (addrs.length == 1 && addrs[0] == "192.168.1.20/24");
    var dns = conn.ipv4_dns ();
    assert (dns.length == 2 && dns[0] == "9.9.9.9" && dns[1] == "1.1.1.1");
    assert (setting (s, "ipv4", "route-metric").get_int64 () == 600);
    var route = setting (s, "ipv4", "route-data").get_child_value (0);
    assert (route.lookup_value ("dest", VariantType.STRING).get_string () == "10.0.0.0");
    assert (route.lookup_value ("prefix", VariantType.UINT32).get_uint32 () == 8);
    assert (route.lookup_value ("next-hop", VariantType.STRING).get_string () == "192.168.1.254");
    assert (route.lookup_value ("metric", VariantType.UINT32).get_uint32 () == 50);

    var wg = new KeyFile ();
    wg.load_from_data ("[connection]\nid=wg\ntype=wireguard\n[wireguard]\nprivate-key=%s\nlisten-port=1234\n[wireguard-peer.%s]\nendpoint=a.example:51820\nallowed-ips=10.0.0.0/8;\npersistent-keepalive=15\n".printf (KEY_A, KEY_B), -1, KeyFileFlags.NONE);
    var w = NmImport.keyfile (wg);
    assert (setting (w, "connection", "uuid").get_string ().length == 36);
    assert (setting (w, "wireguard", "listen-port").get_uint32 () == 1234);
    var peer = setting (w, "wireguard", "peers").get_child_value (0);
    assert (peer.lookup_value ("public-key", VariantType.STRING).get_string () == KEY_B);
    assert (peer.lookup_value ("persistent-keepalive", VariantType.UINT32).get_uint32 () == 15);

    var vpn = new KeyFile ();
    vpn.load_from_data ("[connection]\nid=v\ntype=vpn\n[vpn]\nservice-type=org.freedesktop.NetworkManager.openvpn\nremote=r.example\nconnection-type=tls\n[vpn-secrets]\ncert-pass=x\n", -1, KeyFileFlags.NONE);
    var v = NmImport.keyfile (vpn);
    assert (setting (v, "vpn", "service-type").get_string () == "org.freedesktop.NetworkManager.openvpn");
    assert (setting (v, "vpn", "data").get_type_string () == "a{ss}");
    assert (setting (v, "vpn", "data").lookup_value ("remote", VariantType.STRING).get_string () == "r.example");
    assert (setting (v, "vpn", "secrets").lookup_value ("cert-pass", VariantType.STRING).get_string () == "x");

    var broken = new KeyFile ();
    broken.load_from_data ("[connection]\nid=x\ntype=wifi\nautoconnect=maybe\n", -1, KeyFileFlags.NONE);
    bool failed = false;
    try {
        NmImport.keyfile (broken);
    } catch (Error e) {
        failed = true;
    }
    assert (failed);
    var untyped = new KeyFile ();
    untyped.load_from_data ("[connection]\nid=x\n", -1, KeyFileFlags.NONE);
    failed = false;
    try {
        NmImport.keyfile (untyped);
    } catch (Error e) {
        failed = true;
    }
    assert (failed);
}

void test_openvpn () throws Error {
    string dir = Path.build_filename (Environment.get_tmp_dir (), "nm-import-%d".printf ((int) Posix.getpid ()));
    string text = """
client
dev tun
proto udp
remote vpn.example.org 1194
remote backup.example.org 443 tcp
cipher AES-256-GCM
auth SHA256
remote-cert-tls server
auth-user-pass
key-direction 1
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
<tls-auth>
-----BEGIN OpenVPN Static key V1-----
abcd
-----END OpenVPN Static key V1-----
</tls-auth>
""";
    var s = NmImport.openvpn (text, "My VPN", dir);
    assert (setting (s, "connection", "type").get_string () == "vpn");
    assert (setting (s, "vpn", "service-type").get_string () == "org.freedesktop.NetworkManager.openvpn");
    var data = setting (s, "vpn", "data");
    assert (data.lookup_value ("remote", VariantType.STRING).get_string () == "vpn.example.org:1194, backup.example.org:443:tcp");
    assert (data.lookup_value ("connection-type", VariantType.STRING).get_string () == "password");
    assert (data.lookup_value ("cipher", VariantType.STRING).get_string () == "AES-256-GCM");
    assert (data.lookup_value ("ta-dir", VariantType.STRING).get_string () == "1");
    assert (data.lookup_value ("password-flags", VariantType.STRING).get_string () == "1");
    string ca = data.lookup_value ("ca", VariantType.STRING).get_string ();
    assert (ca == Path.build_filename (dir, "My_VPN-ca.pem"));
    string body;
    FileUtils.get_contents (ca, out body);
    assert (body == "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n");
    Posix.Stat st;
    assert (Posix.stat (ca, out st) == 0 && (st.st_mode & 0777) == 0600);
    assert (FileUtils.test (Path.build_filename (dir, "My_VPN-ta.pem"), FileTest.EXISTS));
    foreach (var f in new string[] { "My_VPN-ca.pem", "My_VPN-ta.pem" }) FileUtils.unlink (Path.build_filename (dir, f));
    DirUtils.remove (dir);

    string[] bad = { "client\ndev tun\n", "remote a.example\n<ca>\nxx\n" };
    foreach (var b in bad) {
        bool failed = false;
        try {
            NmImport.openvpn (b, "x", dir);
        } catch (Error e) {
            failed = true;
        }
        assert (failed);
    }
    DirUtils.remove (dir);
}

void test_simple_profiles () {
    var w = NmImport.wifi ("Home", "secret99");
    assert (setting (w, "802-11-wireless-security", "key-mgmt").get_string () == "wpa-psk");
    assert (setting (NmImport.wifi ("Open", null), "802-11-wireless-security", "key-mgmt") == null);
    var h = new NmConnection.detached (NmImport.hotspot ("Hotspot", "Mine", "pw123456", true));
    assert (h.is_hotspot ());
    assert (h.wifi_ssid () == "Mine");
    assert (h.ipv4_method () == "shared");
    var share = new NmConnection.detached (NmImport.wired_share ("Share"));
    assert (share.get_connection_type () == "802-3-ethernet");
    assert (share.ipv4_method () == "shared");
}

void test_ipv4_changes () throws Error {
    var base_conn = new NmConnection.detached (NmImport.wifi ("Home", "secret99"));
    string? failure;
    var manual = new NmConnection.detached (NmImport.ipv4_changes (base_conn, true, "192.168.1.20/24",
        "192.168.1.1", { "9.9.9.9", "1.1.1.1" }, false, false, out failure));
    assert (failure == null);
    assert (manual.ipv4_method () == "manual");
    var addrs = manual.ipv4_addresses ();
    assert (addrs.length == 1 && addrs[0] == "192.168.1.20/24");
    assert (manual.ipv4_gateway () == "192.168.1.1");
    var dns = manual.ipv4_dns ();
    assert (dns.length == 2 && dns[1] == "1.1.1.1");
    assert (!manual.autoconnect);
    assert (!manual.ipv4_ignore_auto_dns);
    assert (manual.wifi_ssid () == "Home");

    var back = new NmConnection.detached (NmImport.ipv4_changes (manual, false, "", "", { "9.9.9.9" },
        true, true, out failure));
    assert (failure == null);
    assert (back.ipv4_method () == "auto");
    assert (back.ipv4_addresses ().length == 0);
    assert (back.ipv4_gateway () == "");
    assert (back.ipv4_ignore_auto_dns);
    assert (back.autoconnect);

    NmImport.ipv4_changes (base_conn, true, "300.1.1.1/24", "", {}, false, true, out failure);
    assert (failure != null);
    NmImport.ipv4_changes (base_conn, true, "10.0.0.2/33", "", {}, false, true, out failure);
    assert (failure != null);
    NmImport.ipv4_changes (base_conn, true, "10.0.0.2/8", "nope", {}, false, true, out failure);
    assert (failure != null);
    NmImport.ipv4_changes (base_conn, false, "", "", { "fd00::1" }, false, true, out failure);
    assert (failure != null);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/nm/addresses", test_addresses);
    Test.add_func ("/nm/wireguard-conf", () => { try { test_wireguard_conf (); } catch (Error e) { error (e.message); } });
    Test.add_func ("/nm/wireguard-errors", test_wireguard_errors);
    Test.add_func ("/nm/wireguard-manual", () => { try { test_wireguard_manual (); } catch (Error e) { error (e.message); } });
    Test.add_func ("/nm/keyfile", () => { try { test_keyfile (); } catch (Error e) { error (e.message); } });
    Test.add_func ("/nm/openvpn", () => { try { test_openvpn (); } catch (Error e) { error (e.message); } });
    Test.add_func ("/nm/simple", test_simple_profiles);
    Test.add_func ("/nm/ipv4-changes", () => { try { test_ipv4_changes (); } catch (Error e) { error (e.message); } });
    return Test.run ();
}
