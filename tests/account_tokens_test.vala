using Singularity.Accounts;

[DBus (name = "dev.sinty.Accounts")]
class TokenService : Object {
    [DBus (visible = false)]
    public Gee.HashMap<string, int> calls = new Gee.HashMap<string, int>();
    [DBus (visible = false)]
    public bool reject_refresh;
    [DBus (visible = false)]
    public bool mail_enabled = true;
    [DBus (visible = false)]
    public bool hold_request;
    [DBus (visible = false)]
    public bool waiting;
    [DBus (visible = false)]
    public Gee.HashSet<string> removed = new Gee.HashSet<string>();

    public signal void account_removed(string id);

    public async HashTable<string, Variant>[] list_accounts() throws DBusError, IOError {
        HashTable<string, Variant>[] accounts = {};
        foreach (string id in new string[] { "microsoft", "disabled", "google", "password", "disabled-password" }) {
            if (removed.contains(id)) continue;
            var data = new HashTable<string, Variant>(str_hash, str_equal);
            data.insert("id", id);
            data.insert("provider", id == "google" ? "google" : "microsoft");
            data.insert("identity", id + "@example.test");
            data.insert("auth", id.has_suffix("password") ? "password" : "oauth2");
            data.insert("capabilities", new Variant.strv({ "mail", "files" }));
            data.insert("enabled", new Variant.strv(id.has_prefix("disabled") || !mail_enabled ? new string[] { "files" } : new string[] { "mail", "files" }));
            accounts += data;
        }
        return accounts;
    }

    public async void get_access_token(string id, string capability, bool refresh, out string token, out int expires_in) throws DBusError, IOError {
        string key = id + "|" + capability;
        int count = calls[key] + 1;
        calls[key] = count;
        waiting = true;
        while (hold_request) {
            Timeout.add(10, get_access_token.callback);
            yield;
        }
        waiting = false;
        if (refresh && capability == "mail-graph" && reject_refresh) {
            reject_refresh = false;
            throw new DBusError.ACCESS_DENIED("Synthetic expired grant");
        }
        token = key + ":" + count.to_string();
        expires_in = 3600;
        if (refresh) token += ":refresh";
    }

    public async void get_credentials(string id, string capability, out string username, out string secret, out string mechanism) throws DBusError, IOError {
        string key = id + "|" + capability;
        calls[key] = calls[key] + 1;
        waiting = true;
        while (hold_request) {
            Timeout.add(10, get_credentials.callback);
            yield;
        }
        waiting = false;
        username = id + "@example.test";
        secret = "synthetic-password";
        mechanism = "password";
    }
}

async AccountCredentials requested_credentials(Account account, string route, bool refresh = false) throws Error {
    if (route == "mail-graph") return yield account.get_graph_mail_credentials(refresh);
    return yield account.get_credentials(route == "files" ? Capability.FILES : Capability.MAIL, refresh);
}

async void remove_fixture_account(Manager manager, TokenService service, string id, bool notify) {
    service.removed.add(id);
    if (notify) {
        service.account_removed(id);
        int64 deadline = get_monotonic_time() + 5000000;
        while (manager.get_account(id) != null && get_monotonic_time() < deadline) {
            Timeout.add(10, remove_fixture_account.callback);
            yield;
        }
    } else {
        yield manager.reload();
    }
    assert(manager.get_account(id) == null);
}

async void check_removed_credentials(Manager manager, TokenService service) throws Error {
    foreach (bool notify in new bool[] { true, false }) {
        foreach (string route in new string[] { "mail", "mail-graph", "files", "password" }) {
            string id = route == "password" ? "password" : "microsoft";
            string key = id + "|" + (route == "password" ? "mail" : route);
            var held = manager.get_account(id);
            yield requested_credentials(held, route);
            int count = service.calls[key];
            yield remove_fixture_account(manager, service, id, notify);
            bool denied = false;
            try { yield requested_credentials(held, route); }
            catch (AccountsError.INVALID e) { denied = true; }
            assert(denied && service.calls[key] == count);
            service.removed.remove(id);
            yield manager.reload();
            var replacement = manager.get_account(id);
            assert(replacement != null && replacement != held);
            yield requested_credentials(replacement, route);
            assert(service.calls[key] == count + 1);
            denied = false;
            try { yield requested_credentials(held, route); }
            catch (AccountsError.INVALID e) { denied = true; }
            assert(denied && service.calls[key] == count + 1);
            service.hold_request = true;
            service.waiting = false;
            bool finished = false;
            denied = false;
            requested_credentials.begin(replacement, route, true, (obj, res) => {
                try { requested_credentials.end(res); }
                catch (AccountsError.INVALID e) { denied = true; }
                catch (Error e) { assert_not_reached(); }
                finished = true;
            });
            int64 deadline = get_monotonic_time() + 5000000;
            while (!service.waiting && get_monotonic_time() < deadline) {
                Timeout.add(10, check_removed_credentials.callback);
                yield;
            }
            assert(service.waiting);
            count = service.calls[key];
            yield remove_fixture_account(manager, service, id, notify);
            service.removed.remove(id);
            yield manager.reload();
            assert(manager.get_account(id) != replacement);
            service.hold_request = false;
            while (!finished && get_monotonic_time() < deadline) {
                Timeout.add(10, check_removed_credentials.callback);
                yield;
            }
            assert(finished && denied && service.calls[key] == count);
            yield requested_credentials(manager.get_account(id), route);
            assert(service.calls[key] == count + 1);
        }
    }
}

async void check_disabled_credentials(Manager manager, TokenService service) throws Error {
    foreach (string id in new string[] { "disabled", "disabled-password" }) {
        bool rejected = false;
        try {
            yield manager.get_account(id).get_credentials(Capability.MAIL);
        } catch (AccountsError.INVALID e) {
            rejected = true;
        }
        assert(rejected && !service.calls.has_key(id + "|mail"));
    }
    var account = manager.get_account("microsoft");
    bool rejected = false;
    try {
        yield account.get_credentials(Capability.CALENDAR);
    } catch (AccountsError.INVALID e) {
        rejected = true;
    }
    assert(rejected && !service.calls.has_key("microsoft|calendar"));
    service.mail_enabled = false;
    yield manager.reload();
    assert(manager.get_account("microsoft") == account);
    rejected = false;
    try {
        yield account.get_credentials(Capability.MAIL);
    } catch (AccountsError.INVALID e) {
        rejected = true;
    }
    assert(rejected && service.calls["microsoft|mail"] == 1);
    rejected = false;
    try {
        yield account.get_graph_mail_credentials();
    } catch (AccountsError.INVALID e) {
        rejected = true;
    }
    assert(rejected && service.calls["microsoft|mail-graph"] == 4);
    yield account.get_credentials(Capability.FILES);
    service.mail_enabled = true;
    yield manager.reload();
    foreach (string route in new string[] { "mail", "mail-graph", "password" }) {
        foreach (bool reenable in new bool[] { false, true }) {
            var current = manager.get_account(route == "password" ? "password" : "microsoft");
            string key = current.id + "|" + (route == "mail-graph" ? route : "mail");
            service.hold_request = true;
            service.waiting = false;
            bool finished = false;
            bool denied = false;
            if (route == "mail-graph") {
                current.get_graph_mail_credentials.begin(true, (obj, res) => {
                    try { current.get_graph_mail_credentials.end(res); }
                    catch (AccountsError.INVALID e) { denied = true; }
                    catch (Error e) { assert_not_reached(); }
                    finished = true;
                });
            } else {
                current.get_credentials.begin(Capability.MAIL, true, (obj, res) => {
                    try { current.get_credentials.end(res); }
                    catch (AccountsError.INVALID e) { denied = true; }
                    catch (Error e) { assert_not_reached(); }
                    finished = true;
                });
            }
            int64 deadline = get_monotonic_time() + 5000000;
            while (!service.waiting && get_monotonic_time() < deadline) {
                Timeout.add(10, check_disabled_credentials.callback);
                yield;
            }
            assert(service.waiting);
            int count = service.calls[key];
            service.mail_enabled = false;
            yield manager.reload();
            if (reenable) {
                service.mail_enabled = true;
                yield manager.reload();
            }
            service.hold_request = false;
            while (!finished && get_monotonic_time() < deadline) {
                Timeout.add(10, check_disabled_credentials.callback);
                yield;
            }
            assert(finished && denied && service.calls[key] == count);
            service.mail_enabled = true;
            yield manager.reload();
            if (route == "mail-graph") yield current.get_graph_mail_credentials();
            else yield current.get_credentials(Capability.MAIL);
            assert(service.calls[key] == count + 1);
        }
    }
}

async void check_token_routes() throws Error {
    var connection = yield Bus.get(BusType.SESSION);
    var service = new TokenService();
    uint registration = connection.register_object(Manager.OBJECT_PATH, service);
    yield connection.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        new Variant("(su)", Manager.BUS_NAME, 0u), new VariantType("(u)"), DBusCallFlags.NONE, 10000);
    var manager = Manager.get_default();
    yield manager.load();
    assert(manager.available);
    var account = manager.get_account("microsoft");
    assert(account != null);
    var imap = yield account.get_credentials(Capability.MAIL);
    var files = yield account.get_credentials(Capability.FILES);
    var graph = yield account.get_graph_mail_credentials();
    assert(imap.secret == "microsoft|mail:1");
    assert(files.secret == "microsoft|files:1");
    assert(graph.secret == "microsoft|mail-graph:1");
    assert(graph.username == "microsoft@example.test" && graph.is_token);
    var cached_graph = yield account.get_graph_mail_credentials();
    var cached_imap = yield account.get_credentials(Capability.MAIL);
    var cached_files = yield account.get_credentials(Capability.FILES);
    assert(cached_graph.secret == graph.secret && cached_imap.secret == imap.secret && cached_files.secret == files.secret);
    var refreshed = yield account.get_graph_mail_credentials(true);
    assert(refreshed.secret == "microsoft|mail-graph:2:refresh");
    cached_imap = yield account.get_credentials(Capability.MAIL);
    cached_files = yield account.get_credentials(Capability.FILES);
    assert(cached_imap.secret == imap.secret && cached_files.secret == files.secret);
    assert(service.calls["microsoft|mail"] == 1 && service.calls["microsoft|files"] == 1 && service.calls["microsoft|mail-graph"] == 2);
    service.reject_refresh = true;
    bool refused = false;
    try {
        yield account.get_graph_mail_credentials(true);
    } catch (DBusError.ACCESS_DENIED e) {
        refused = true;
    }
    assert(refused);
    refreshed = yield account.get_graph_mail_credentials();
    assert(refreshed.secret == "microsoft|mail-graph:4");
    cached_imap = yield account.get_credentials(Capability.MAIL);
    assert(cached_imap.secret == imap.secret && service.calls["microsoft|mail"] == 1);
    foreach (string id in new string[] { "disabled", "google", "password" }) {
        bool rejected = false;
        try {
            yield manager.get_account(id).get_graph_mail_credentials();
        } catch (AccountsError.INVALID e) {
            rejected = true;
        }
        assert(rejected && !service.calls.has_key(id + "|mail-graph"));
    }
    yield check_disabled_credentials(manager, service);
    yield check_removed_credentials(manager, service);
    connection.unregister_object(registration);
}

void test_token_routes() {
    var loop = new MainLoop();
    check_token_routes.begin((obj, res) => {
        try {
            check_token_routes.end(res);
        } catch (Error e) {
            stderr.printf("FAILED: %s\n", e.message);
            assert_not_reached();
        }
        loop.quit();
    });
    loop.run();
}

int main(string[] args) {
    Test.init(ref args);
    try {
        string dir = DirUtils.make_tmp("at-XXXXXX");
        string config = Path.build_filename(dir, "bus.conf");
        string socket = Path.build_filename(dir, "bus");
        FileUtils.set_contents(config, "<busconfig><type>session</type><listen>unix:path=" + socket + "</listen><auth>EXTERNAL</auth><policy context=\"default\"><allow send_destination=\"*\"/><allow receive_sender=\"*\"/><allow own=\"*\"/></policy></busconfig>");
        Environment.set_variable("DBUS_SESSION_BUS_ADDRESS", "unix:path=" + socket, true);
        var daemon = new Subprocess(SubprocessFlags.STDOUT_PIPE, "dbus-daemon", "--nofork", "--config-file=" + config, "--print-address=1");
        var output = new DataInputStream(daemon.get_stdout_pipe());
        string? address = output.read_line();
        assert(address != null && address.has_prefix("unix:path=" + socket));
        Test.add_func("/accounts/graph-mail-token-routes", test_token_routes);
        int result = Test.run();
        daemon.force_exit();
        daemon.wait();
        FileUtils.unlink(socket);
        FileUtils.unlink(config);
        DirUtils.remove(dir);
        return result;
    } catch (Error e) {
        stderr.printf("FAILED: %s\n", e.message);
        return 1;
    }
}
