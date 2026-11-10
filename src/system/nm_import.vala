namespace Singularity {

    public errordomain NmImportError {
        INVALID
    }

    public class NmImport : GLib.Object {

        private static void add_cidrs(NmSettings s, string list, ref bool has4, ref bool has6) throws Error {
            var addr4 = new VariantBuilder(new VariantType("aa{sv}"));
            var addr6 = new VariantBuilder(new VariantType("aa{sv}"));
            foreach (var part in list.split(",")) {
                string t = part.strip();
                if (t == "") continue;
                string ip = t;
                bool v6 = t.contains(":");
                uint prefix = v6 ? 128 : 32;
                int slash = t.index_of("/");
                if (slash >= 0) {
                    ip = t.substring(0, slash).strip();
                    uint64 p;
                    if (!uint64.try_parse(t.substring(slash + 1).strip(), out p) || p > prefix)
                        throw new NmImportError.INVALID("Invalid address %s", t);
                    prefix = (uint) p;
                }
                var addr = new InetAddress.from_string(ip);
                if (addr == null) throw new NmImportError.INVALID("Invalid address %s", t);
                var entry = new VariantBuilder(new VariantType("a{sv}"));
                entry.add("{sv}", "address", new Variant.string(addr.to_string()));
                entry.add("{sv}", "prefix", new Variant.uint32(prefix));
                if (addr.family == SocketFamily.IPV6) {
                    addr6.add_value(entry.end());
                    has6 = true;
                } else {
                    addr4.add_value(entry.end());
                    has4 = true;
                }
            }
            if (has4) s.set("ipv4", "address-data", addr4.end());
            if (has6) s.set("ipv6", "address-data", addr6.end());
        }

        private static void add_dns(NmSettings s, string list) throws Error {
            uint32[] v4 = {};
            string[] v6 = {};
            foreach (var part in list.split(",")) {
                string t = part.strip();
                if (t == "") continue;
                var addr = new InetAddress.from_string(t);
                if (addr == null) throw new NmImportError.INVALID("Invalid DNS server %s", t);
                if (addr.family == SocketFamily.IPV4) v4 += NmClient.ipv4_value(t);
                else v6 += addr.to_string();
            }
            if (v4.length > 0) {
                var b = new VariantBuilder(new VariantType("au"));
                foreach (var v in v4) b.add("u", v);
                s.set("ipv4", "dns", b.end());
            }
            if (v6.length > 0) {
                var b = new VariantBuilder(new VariantType("aay"));
                foreach (var t in v6) {
                    var addr = new InetAddress.from_string(t);
                    var raw = new uint8[16];
                    Memory.copy(raw, addr.to_bytes(), 16);
                    b.add_value(new Variant.from_bytes(new VariantType("ay"), new Bytes(raw), true));
                }
                s.set("ipv6", "dns", b.end());
            }
        }

        private static void ip_methods(NmSettings s, bool has4, bool has6) {
            if (!has4 && !has6) {
                s.set("ipv4", "method", "auto");
                s.set("ipv6", "method", "auto");
                return;
            }
            s.set("ipv4", "method", has4 ? "manual" : "disabled");
            s.set("ipv6", "method", has6 ? "manual" : "disabled");
        }

        private static string key(string text) throws Error {
            string k = text.strip();
            uint8[] raw = Base64.decode(k);
            if (k.length != 44 || raw.length != 32) throw new NmImportError.INVALID("Invalid WireGuard key");
            return k;
        }

        private static void connection(NmSettings s, string name, string type, bool autoconnect) {
            s.set("connection", "id", name);
            s.set("connection", "uuid", NmClient.new_uuid());
            s.set("connection", "type", type);
            s.set("connection", "autoconnect", autoconnect);
        }

        public static Variant wireguard_manual(string name, string private_key, string address, string dns,
                                               string peer_public_key, string endpoint, string allowed_ips,
                                               string? preshared_key) throws Error {
            var s = new NmSettings();
            connection(s, name, "wireguard", false);
            s.set("wireguard", "private-key", key(private_key));
            var peer = new VariantBuilder(new VariantType("a{sv}"));
            peer.add("{sv}", "public-key", new Variant.string(key(peer_public_key)));
            if (endpoint.strip() != "") peer.add("{sv}", "endpoint", new Variant.string(endpoint.strip()));
            if (preshared_key != null && preshared_key.strip() != "")
                peer.add("{sv}", "preshared-key", new Variant.string(key(preshared_key)));
            string aips = allowed_ips.strip() != "" ? allowed_ips.strip() : "0.0.0.0/0, ::/0";
            string[] list = {};
            foreach (var ip in aips.split(",")) if (ip.strip() != "") list += ip.strip();
            peer.add("{sv}", "allowed-ips", new Variant.strv(list));
            var peers = new VariantBuilder(new VariantType("aa{sv}"));
            peers.add_value(peer.end());
            s.set("wireguard", "peers", peers.end());
            bool has4 = false, has6 = false;
            add_cidrs(s, address, ref has4, ref has6);
            ip_methods(s, has4, has6);
            add_dns(s, dns);
            return s.build();
        }

        public static Variant wireguard_conf(string text, string name) throws Error {
            var s = new NmSettings();
            connection(s, name, "wireguard", false);
            s.group("wireguard");
            var peers = new VariantBuilder(new VariantType("aa{sv}"));
            VariantBuilder? peer = null;
            bool peer_key = false;
            int peer_count = 0;
            string section = "";
            string addresses = "";
            string dns = "";
            foreach (var raw in text.split("\n")) {
                int hash = raw.index_of("#");
                string line = (hash >= 0 ? raw.substring(0, hash) : raw).strip();
                if (line == "") continue;
                if (line.has_prefix("[")) {
                    section = line.down();
                    if (section == "[peer]") {
                        if (peer != null) {
                            if (!peer_key) throw new NmImportError.INVALID("A peer has no public key");
                            peers.add_value(peer.end());
                        }
                        peer = new VariantBuilder(new VariantType("a{sv}"));
                        peer_key = false;
                        peer_count++;
                    } else if (section != "[interface]") {
                        throw new NmImportError.INVALID("Unknown section %s", line);
                    }
                    continue;
                }
                int eq = line.index_of("=");
                if (eq < 0 || section == "") throw new NmImportError.INVALID("Unreadable line: %s", line);
                string k = line.substring(0, eq).strip().down();
                string v = line.substring(eq + 1).strip();
                if (section == "[interface]") {
                    switch (k) {
                        case "privatekey": s.set("wireguard", "private-key", key(v)); break;
                        case "listenport": s.set("wireguard", "listen-port", (uint32) uint64.parse(v)); break;
                        case "fwmark": s.set("wireguard", "fwmark", (uint32) uint64.parse(v)); break;
                        case "mtu": s.set("wireguard", "mtu", (uint32) uint64.parse(v)); break;
                        case "address": addresses += (addresses != "" ? "," : "") + v; break;
                        case "dns": dns += (dns != "" ? "," : "") + v; break;
                        default: break;
                    }
                } else {
                    switch (k) {
                        case "publickey": peer.add("{sv}", "public-key", new Variant.string(key(v))); peer_key = true; break;
                        case "presharedkey": peer.add("{sv}", "preshared-key", new Variant.string(key(v))); break;
                        case "endpoint": peer.add("{sv}", "endpoint", new Variant.string(v)); break;
                        case "persistentkeepalive":
                            peer.add("{sv}", "persistent-keepalive", new Variant.uint32((uint32) uint64.parse(v)));
                            break;
                        case "allowedips":
                            string[] list = {};
                            foreach (var ip in v.split(",")) if (ip.strip() != "") list += ip.strip();
                            peer.add("{sv}", "allowed-ips", new Variant.strv(list));
                            break;
                        default: throw new NmImportError.INVALID("Unknown peer key %s", k);
                    }
                }
            }
            if (peer != null) {
                if (!peer_key) throw new NmImportError.INVALID("A peer has no public key");
                peers.add_value(peer.end());
            }
            if (peer_count > 0) s.set("wireguard", "peers", peers.end());
            bool has4 = false, has6 = false;
            add_cidrs(s, addresses, ref has4, ref has6);
            ip_methods(s, has4, has6);
            string[] dns_ips = {};
            foreach (var d in dns.split(",")) {
                string t = d.strip();
                if (t != "" && new InetAddress.from_string(t) != null) dns_ips += t;
            }
            add_dns(s, string.joinv(",", dns_ips));
            return s.build();
        }

        private const string[] BOOL_KEYS = {
            "autoconnect", "read-only", "ignore-auto-dns", "ignore-auto-routes", "never-default",
            "may-fail", "hidden", "dhcp-send-hostname", "auto-negotiate", "private-key-flags-only",
            "autoconnect-slaves", "ip4-auto-default-route", "ip6-auto-default-route", "persistent"
        };
        private const string[] INT32_KEYS = {
            "autoconnect-priority", "autoconnect-retries", "dns-priority", "metered", "auth-retries",
            "lldp", "mdns", "llmnr", "dhcp-timeout", "ip6-privacy", "addr-gen-mode", "wait-device-timeout",
            "dns-over-tls", "required-timeout", "dhcp-hostname-flags", "pmf"
        };
        private const string[] UINT32_KEYS = {
            "mtu", "listen-port", "fwmark", "persistent-keepalive", "channel", "wep-key-type", "speed",
            "psk-flags", "password-flags", "private-key-flags", "preshared-key-flags", "wep-key-flags",
            "secret-flags", "powersave", "mac-address-randomization", "wake-on-lan",
            "route-table", "ipv4.route-table", "multi-connect", "ip-tunnel-flags", "tx-power", "rate",
            "gateway-ping-timeout", "stable-id-flags"
        };
        private const string[] INT64_KEYS = { "route-metric" };
        private const string[] UINT64_KEYS = { "timestamp" };
        private const string[] LIST_KEYS = {
            "dns-search", "allowed-ips", "dns-options", "permissions", "secondaries",
            "mac-address-blacklist", "mac-address-denylist", "seen-bssids", "routing-rules-names"
        };
        private const string[] MAC_KEYS = { "mac-address", "cloned-mac-address", "bssid" };

        private static bool contains(string[] list, string v) {
            foreach (var s in list) if (s == v) return true;
            return false;
        }

        private static Variant typed(string group, string k, string v) throws Error {
            if (contains(BOOL_KEYS, k)) {
                if (v != "true" && v != "false" && v != "yes" && v != "no" && v != "1" && v != "0")
                    throw new NmImportError.INVALID("%s.%s is not a boolean", group, k);
                return new Variant.boolean(v == "true" || v == "yes" || v == "1");
            }
            if (contains(INT32_KEYS, k)) {
                int64 n;
                if (!int64.try_parse(v, out n)) throw new NmImportError.INVALID("%s.%s is not a number", group, k);
                return new Variant.int32((int32) n);
            }
            if (contains(UINT32_KEYS, k)) {
                uint64 n;
                if (!uint64.try_parse(v, out n)) throw new NmImportError.INVALID("%s.%s is not a number", group, k);
                return new Variant.uint32((uint32) n);
            }
            if (contains(INT64_KEYS, k)) {
                int64 n;
                if (!int64.try_parse(v, out n)) throw new NmImportError.INVALID("%s.%s is not a number", group, k);
                return new Variant.int64(n);
            }
            if (contains(UINT64_KEYS, k)) {
                uint64 n;
                if (!uint64.try_parse(v, out n)) throw new NmImportError.INVALID("%s.%s is not a number", group, k);
                return new Variant.uint64(n);
            }
            if (contains(LIST_KEYS, k)) return new Variant.strv(split_list(v));
            if (contains(MAC_KEYS, k)) {
                string[] parts = v.split(":");
                var raw = new uint8[parts.length];
                for (int i = 0; i < parts.length; i++) {
                    uint64 b;
                    if (!uint64.try_parse(parts[i], out b, null, 16) || b > 255)
                        throw new NmImportError.INVALID("%s.%s is not a hardware address", group, k);
                    raw[i] = (uint8) b;
                }
                return new Variant.from_bytes(new VariantType("ay"), new Bytes(raw), true);
            }
            if (group == "802-1x" && (k.has_suffix("-cert") || k.has_suffix("private-key"))) {
                string path = v.has_prefix("file://") ? v : "file://" + v;
                uint8[] raw = path.data;
                raw += 0;
                return new Variant.from_bytes(new VariantType("ay"), new Bytes(raw), true);
            }
            return new Variant.string(v);
        }

        private static string canonical_group(string g) {
            switch (g) {
                case "ethernet": return "802-3-ethernet";
                case "wifi": return "802-11-wireless";
                case "wifi-security": return "802-11-wireless-security";
                case "802-1x": return "802-1x";
                default: return g;
            }
        }

        private static string[] split_list(string v) {
            string[] out = {};
            foreach (var p in v.replace(",", ";").split(";")) if (p.strip() != "") out += p.strip();
            return out;
        }

        public static Variant keyfile(KeyFile kf) throws Error {
            var s = new NmSettings();
            var peers = new VariantBuilder(new VariantType("aa{sv}"));
            int peer_count = 0;
            foreach (var raw_group in kf.get_groups()) {
                if (raw_group.has_prefix("wireguard-peer.")) {
                    var peer = new VariantBuilder(new VariantType("a{sv}"));
                    peer.add("{sv}", "public-key", new Variant.string(key(raw_group.substring(15))));
                    foreach (var k in kf.get_keys(raw_group)) {
                        string v = kf.get_value(raw_group, k).strip();
                        if (k == "allowed-ips") peer.add("{sv}", k, new Variant.strv(split_list(v)));
                        else if (k == "persistent-keepalive" || k == "preshared-key-flags")
                            peer.add("{sv}", k, new Variant.uint32((uint32) uint64.parse(v)));
                        else peer.add("{sv}", k, new Variant.string(v));
                    }
                    peers.add_value(peer.end());
                    peer_count++;
                    continue;
                }
                string group = canonical_group(raw_group);
                s.group(group);
                if (group == "vpn" || group == "vpn-secrets") {
                    var dict = new VariantBuilder(new VariantType("a{ss}"));
                    var dict_keys = new GenericArray<string>();
                    foreach (var k in kf.get_keys(raw_group)) {
                        if (group == "vpn" && (k == "service-type" || k == "user-name" || k == "persistent" || k == "timeout")) {
                            if (k == "persistent") s.set("vpn", k, typed(group, k, kf.get_value(raw_group, k).strip()));
                            else if (k == "timeout") s.set("vpn", k, new Variant.uint32((uint32) uint64.parse(kf.get_value(raw_group, k))));
                            else s.set("vpn", k, kf.get_value(raw_group, k).strip());
                            continue;
                        }
                        dict.add("{ss}", k, kf.get_value(raw_group, k));
                        dict_keys.add(k);
                    }
                    if (dict_keys.length > 0) s.set("vpn", group == "vpn" ? "data" : "secrets", dict.end());
                    continue;
                }
                string addresses4 = "";
                var routes = new VariantBuilder(new VariantType("aa{sv}"));
                int route_count = 0;
                foreach (var k in kf.get_keys(raw_group)) {
                    string v = kf.get_value(raw_group, k).strip();
                    if ((group == "ipv4" || group == "ipv6") && (k.has_prefix("address") || k.has_prefix("addresses"))) {
                        string[] parts = v.split(",");
                        addresses4 += (addresses4 != "" ? "," : "") + parts[0].strip();
                        if (parts.length > 1 && parts[1].strip() != "" && kf.has_key(raw_group, "gateway") == false)
                            s.set(group, "gateway", parts[1].strip());
                        continue;
                    }
                    if ((group == "ipv4" || group == "ipv6") && k == "dns") {
                        add_dns(s, string.joinv(",", split_list(v)));
                        continue;
                    }
                    if ((group == "ipv4" || group == "ipv6") && Regex.match_simple("^routes?[0-9]+$", k)) {
                        string[] parts = v.split(",");
                        string[] dest = parts[0].strip().split("/");
                        var route = new VariantBuilder(new VariantType("a{sv}"));
                        route.add("{sv}", "dest", new Variant.string(dest[0]));
                        route.add("{sv}", "prefix", new Variant.uint32(dest.length > 1 ? (uint32) uint64.parse(dest[1]) : (group == "ipv4" ? 32 : 128)));
                        if (parts.length > 1 && parts[1].strip() != "" && parts[1].strip() != "0.0.0.0" && parts[1].strip() != "::")
                            route.add("{sv}", "next-hop", new Variant.string(parts[1].strip()));
                        if (parts.length > 2 && parts[2].strip() != "")
                            route.add("{sv}", "metric", new Variant.uint32((uint32) uint64.parse(parts[2].strip())));
                        routes.add_value(route.end());
                        route_count++;
                        continue;
                    }
                    if (Regex.match_simple("^routes?[0-9]+_options$", k)) continue;
                    if (group == "connection" && k == "type") {
                        s.set(group, k, canonical_group(v));
                        continue;
                    }
                    if (group == "802-11-wireless" && k == "ssid") {
                        s.set(group, k, NmClient.ssid_bytes(kf.get_string(raw_group, k)));
                        continue;
                    }
                    s.set(group, k, typed(group, k, v));
                }
                if (addresses4 != "") {
                    bool has4 = false, has6 = false;
                    add_cidrs(s, addresses4, ref has4, ref has6);
                }
                if (route_count > 0) s.set(group, "route-data", routes.end());
            }
            if (peer_count > 0) s.set("wireguard", "peers", peers.end());
            var id = s.groups.lookup("connection");
            if (id == null || id.lookup("type") == null) throw new NmImportError.INVALID("The file has no connection type");
            if (id.lookup("uuid") == null) s.set("connection", "uuid", NmClient.new_uuid());
            return s.build();
        }

        private static string word(string[] w, int i) {
            return w.length > i ? w[i] : "";
        }

        private static string write_inline(string dir, string name, string tag, string body) throws Error {
            DirUtils.create_with_parents(dir, 0700);
            string safe = name.replace("/", "_").replace(" ", "_");
            string path = Path.build_filename(dir, "%s-%s.pem".printf(safe, tag));
            FileUtils.set_contents(path, body.strip() + "\n");
            FileUtils.chmod(path, 0600);
            return path;
        }

        public static Variant openvpn(string text, string name, string cert_dir) throws Error {
            var data = new HashTable<string, string>(str_hash, str_equal);
            string? block = null;
            var body = new StringBuilder();
            bool auth_user_pass = false;
            bool has_cert = false;
            foreach (var raw in text.split("\n")) {
                string line = raw.strip();
                if (block != null) {
                    if (line == "</%s>".printf(block)) {
                        string tag = block == "tls-auth" ? "ta" : block;
                        string path = write_inline(cert_dir, name, tag, body.str);
                        switch (block) {
                            case "ca": data.insert("ca", path); break;
                            case "cert": data.insert("cert", path); has_cert = true; break;
                            case "key": data.insert("key", path); break;
                            case "tls-auth": data.insert("ta", path); break;
                            case "tls-crypt": data.insert("tls-crypt", path); break;
                            case "tls-crypt-v2": data.insert("tls-crypt-v2", path); break;
                            default: break;
                        }
                        block = null;
                        body.truncate(0);
                    } else {
                        body.append(raw).append_c('\n');
                    }
                    continue;
                }
                if (line == "" || line.has_prefix("#") || line.has_prefix(";")) continue;
                if (line.has_prefix("<") && line.has_suffix(">") && !line.has_prefix("</")) {
                    block = line.substring(1, line.length - 2);
                    continue;
                }
                string[] w = Regex.split_simple("\\s+", line);
                string a1 = word(w, 1);
                string a2 = word(w, 2);
                string a3 = word(w, 3);
                switch (w[0]) {
                    case "remote":
                        string r = a1;
                        if (a2 != "") r += ":" + a2;
                        if (a3 != "") r += ":" + a3;
                        string? prev = data.lookup("remote");
                        data.insert("remote", prev != null ? prev + ", " + r : r);
                        break;
                    case "port": data.insert("port", a1); break;
                    case "proto": if (a1.has_prefix("tcp")) data.insert("proto-tcp", "yes"); break;
                    case "dev": data.insert("dev-type", a1.has_prefix("tap") ? "tap" : "tun"); break;
                    case "dev-type": data.insert("dev-type", a1); break;
                    case "ca": data.insert("ca", a1); break;
                    case "cert": data.insert("cert", a1); has_cert = true; break;
                    case "key": data.insert("key", a1); break;
                    case "tls-auth":
                        data.insert("ta", a1);
                        if (a2 != "") data.insert("ta-dir", a2);
                        break;
                    case "key-direction": data.insert("ta-dir", a1); break;
                    case "tls-crypt": data.insert("tls-crypt", a1); break;
                    case "cipher": data.insert("cipher", a1); break;
                    case "data-ciphers": data.insert("data-ciphers", a1); break;
                    case "auth": data.insert("auth", a1); break;
                    case "comp-lzo": data.insert("comp-lzo", a1 != "" ? a1 : "adaptive"); break;
                    case "compress": data.insert("compress", a1 != "" ? a1 : "yes"); break;
                    case "remote-cert-tls": data.insert("remote-cert-tls", a1); break;
                    case "verify-x509-name":
                        data.insert("verify-x509-name", a2 != "" ? "%s:%s".printf(a2, a1) : "subject:" + a1);
                        break;
                    case "tun-mtu": data.insert("tunnel-mtu", a1); break;
                    case "fragment": data.insert("fragment-size", a1); break;
                    case "mssfix": data.insert("mssfix", a1 != "" ? a1 : "yes"); break;
                    case "float": data.insert("float", "yes"); break;
                    case "reneg-sec": data.insert("reneg-seconds", a1); break;
                    case "auth-user-pass": auth_user_pass = true; break;
                    case "ping": data.insert("ping", a1); break;
                    case "ping-restart": data.insert("ping-restart", a1); break;
                    case "ping-exit": data.insert("ping-exit", a1); break;
                    case "tls-version-min": data.insert("tls-version-min", a1); break;
                    default: break;
                }
            }
            if (block != null) throw new NmImportError.INVALID("The <%s> block is not closed", block);
            if (data.lookup("remote") == null) throw new NmImportError.INVALID("The file names no server");
            data.insert("connection-type", auth_user_pass ? (has_cert ? "password-tls" : "password") : "tls");
            if (auth_user_pass) data.insert("password-flags", "1");
            var dict = new VariantBuilder(new VariantType("a{ss}"));
            var keys = data.get_keys();
            keys.sort(strcmp);
            foreach (var k in keys) dict.add("{ss}", k, data.lookup(k));
            var s = new NmSettings();
            connection(s, name, "vpn", false);
            s.set("vpn", "service-type", "org.freedesktop.NetworkManager.openvpn");
            s.set("vpn", "data", dict.end());
            s.set("ipv4", "method", "auto");
            s.set("ipv6", "method", "auto");
            return s.build();
        }

        public static Variant openvpn_manual(string name, string gateway, string username, string password,
                                             string? ca_path) {
            var data = new VariantBuilder(new VariantType("a{ss}"));
            if (ca_path != null && ca_path.strip() != "") data.add("{ss}", "ca", ca_path);
            data.add("{ss}", "connection-type", "password");
            data.add("{ss}", "remote", gateway);
            data.add("{ss}", "username", username);
            var secrets = new VariantBuilder(new VariantType("a{ss}"));
            secrets.add("{ss}", "password", password);
            var s = new NmSettings();
            connection(s, name, "vpn", false);
            s.set("vpn", "service-type", "org.freedesktop.NetworkManager.openvpn");
            s.set("vpn", "data", data.end());
            s.set("vpn", "secrets", secrets.end());
            s.set("ipv4", "method", "auto");
            s.set("ipv6", "method", "auto");
            return s.build();
        }

        public static Variant wifi(string ssid, string? password) {
            var s = new NmSettings();
            s.set("802-11-wireless", "ssid", NmClient.ssid_bytes(ssid));
            if (password != null && password != "") {
                s.set("802-11-wireless-security", "key-mgmt", "wpa-psk");
                s.set("802-11-wireless-security", "psk", password);
            }
            return s.build();
        }

        public static Variant hotspot(string id, string ssid, string password, bool wpa3) {
            var s = new NmSettings();
            connection(s, id, "802-11-wireless", false);
            s.set("802-11-wireless", "ssid", NmClient.ssid_bytes(ssid));
            s.set("802-11-wireless", "mode", "ap");
            s.set("802-11-wireless", "band", "bg");
            s.set("802-11-wireless-security", "key-mgmt", wpa3 ? "sae" : "wpa-psk");
            s.set("802-11-wireless-security", "psk", password);
            s.set("ipv4", "method", "shared");
            s.set("ipv6", "method", "ignore");
            return s.build();
        }

        public static Variant wired_share(string id) {
            var s = new NmSettings();
            connection(s, id, "802-3-ethernet", false);
            s.group("802-3-ethernet");
            s.set("ipv4", "method", "shared");
            s.set("ipv6", "method", "ignore");
            return s.build();
        }

        public static Variant ipv4_changes(NmConnection conn, bool manual, string address, string gateway,
                                           string[] dns, bool only_dns, bool autoconnect,
                                           out string? failure) {
            failure = null;
            var ip4 = new HashTable<string, Variant?>(str_hash, str_equal);
            ip4.insert("addresses", null);
            ip4.insert("address-data", null);
            ip4.insert("dns-data", null);
            ip4.insert("gateway", null);
            if (manual) {
                string[] parts = address.strip().split("/");
                int prefix = parts.length > 1 ? int.parse(parts[1]) : 24;
                if (!NmClient.ipv4_valid(parts[0]) || prefix < 1 || prefix > 32) {
                    failure = _("The address is not valid");
                    return conn.settings;
                }
                var entry = new VariantBuilder(new VariantType("a{sv}"));
                entry.add("{sv}", "address", new Variant.string(parts[0].strip()));
                entry.add("{sv}", "prefix", new Variant.uint32((uint32) prefix));
                var list = new VariantBuilder(new VariantType("aa{sv}"));
                list.add_value(entry.end());
                ip4.insert("address-data", list.end());
                if (gateway.strip() != "") {
                    if (!NmClient.ipv4_valid(gateway)) {
                        failure = _("The gateway is not valid");
                        return conn.settings;
                    }
                    ip4.insert("gateway", new Variant.string(gateway.strip()));
                }
            }
            var servers = new VariantBuilder(new VariantType("au"));
            foreach (var server in dns) {
                if (!NmClient.ipv4_valid(server)) {
                    failure = _("The DNS server %s is not valid").printf(server);
                    return conn.settings;
                }
                servers.add("u", NmClient.ipv4_value(server));
            }
            ip4.insert("dns", servers.end());
            ip4.insert("method", new Variant.string(manual ? "manual" : "auto"));
            ip4.insert("ignore-auto-dns", new Variant.boolean(!manual && only_dns));
            var con = new HashTable<string, Variant?>(str_hash, str_equal);
            con.insert("autoconnect", new Variant.boolean(autoconnect));
            var with_ip = new NmConnection.detached(conn.changed("ipv4", ip4));
            return with_ip.changed("connection", con);
        }
    }
}
