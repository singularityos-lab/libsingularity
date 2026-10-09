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

class StorageFixture : Object {
    public Soup.Server server = new Soup.Server("server-header", "storage-test");
    public string url;
    public int requests;
    public bool bad_page;
    public bool repeated_page;

    public StorageFixture() throws Error {
        server.add_handler(null, respond);
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
        url = server.get_uris().data.to_string();
    }

    private void respond(Soup.Server server, Soup.ServerMessage message, string path, HashTable<string, string>? query) {
        requests++;
        assert(message.get_request_headers().get_one("Authorization").has_prefix("Bearer "));
        string body = "{}";
        string method = message.get_method();
        if (path == "/google/drives") {
            body = query.contains("pageToken") ? "{\"drives\":[{\"id\":\"team-two\",\"name\":\"Team Two\"}]}"
                : "{\"drives\":[{\"id\":\"team\",\"name\":\"Team\"}],\"nextPageToken\":\"next\"}";
        } else if (path == "/google/files" && method == "GET") {
            assert(query["supportsAllDrives"] == "true" && query["includeItemsFromAllDrives"] == "true");
            string filter = query["q"];
            if (filter.contains("sharedWithMe")) {
                body = "{\"files\":[{\"id\":\"shared-folder\",\"name\":\"Shared Folder\",\"mimeType\":\"application/vnd.google-apps.folder\"}]}";
            } else if (filter.contains("'team'")) {
                assert(query["corpora"] == "drive" && query["driveId"] == "team");
                body = "{\"files\":[{\"id\":\"team-file\",\"name\":\"notes.txt\",\"mimeType\":\"text/plain\",\"driveId\":\"team\"}]}";
            } else if (filter.contains("'cycle'")) {
                body = "{\"files\":[],\"nextPageToken\":\"same\"}";
            } else body = "{\"files\":[]}";
        } else if (path == "/google/files/root") {
            body = "{\"id\":\"my-google-root\",\"name\":\"My Drive\",\"mimeType\":\"application/vnd.google-apps.folder\"}";
        } else if (path == "/google/files" || path == "/google/files/team-file") {
            assert(query["supportsAllDrives"] == "true");
            if (query["alt"] == "media") body = "content";
            else body = "{\"id\":\"team-file\",\"name\":\"notes.txt\",\"mimeType\":\"text/plain\"}";
        } else if (path == "/graph/me/drive/root/children" || path == "/graph/drives/personal/items/my-root/children") {
            body = "{\"value\":[{\"id\":\"alias\",\"remoteItem\":{\"id\":\"folder\",\"name\":\"Shortcut\",\"folder\":{},\"parentReference\":{\"driveId\":\"remote\"}}}]}";
        } else if (path == "/graph/me/drive/sharedWithMe") {
            body = query.contains("page") ? "{\"value\":[{\"id\":\"alias-two\",\"remoteItem\":{\"id\":\"folder\",\"name\":\"Other Share\",\"folder\":{},\"parentReference\":{\"driveId\":\"other\"}}}]}"
                : "{\"value\":[{\"id\":\"alias\",\"remoteItem\":{\"id\":\"folder\",\"name\":\"Shared Folder\",\"folder\":{},\"parentReference\":{\"driveId\":\"remote\"}}}],\"@odata.nextLink\":\"" + url + "graph/me/drive/sharedWithMe?page=2\"}";
        } else if (path == "/graph/me/memberOf") {
            body = query.contains("page") ? "{\"value\":[{\"id\":\"forbidden\",\"displayName\":null,\"@odata.type\":\"#microsoft.graph.group\"}]}"
                : "{\"value\":[{\"id\":\"company\",\"displayName\":\"Company\",\"@odata.type\":\"#microsoft.graph.group\"}],\"@odata.nextLink\":\"" + url + "graph/me/memberOf?page=2\"}";
        } else if (path == "/graph/groups/company/drives") {
            body = query != null && query.contains("page") ? "{\"value\":[{\"id\":\"other\",\"name\":\"Archive\"}]}"
                : "{\"value\":[{\"id\":\"remote\",\"name\":\"Documents\"}],\"@odata.nextLink\":\"" + url + "graph/groups/company/drives?page=2\"}";
        } else if (path == "/graph/groups/forbidden/drives") {
            message.set_status(403, null);
            return;
        } else if (path == "/graph/me/followedSites") {
            body = "{\"value\":[{\"id\":\"site\",\"displayName\":\"Intranet\"}]}";
        } else if (path == "/graph/sites/site/drives") {
            body = "{\"value\":[{\"id\":\"remote\",\"name\":\"Documents\"},{\"id\":\"site-drive\",\"name\":\"Resources\"}]}";
        } else if (path == "/graph/me/drive/root") {
            body = "{\"id\":\"my-root\",\"name\":\"My Drive\",\"folder\":{},\"parentReference\":{\"driveId\":\"personal\"}}";
        } else if (path.has_suffix("/root")) {
            body = "{\"id\":\"folder\",\"name\":\"Root\",\"folder\":{}}";
        } else if (path == "/graph/drives/remote/items/folder/children" && method == "GET") {
            if (bad_page || repeated_page) body = "{\"value\":[],\"@odata.nextLink\":\"" + (bad_page ? "http://127.0.0.1:1/foreign" : url + "graph/drives/remote/items/folder/children?$top=200") + "\"}";
            else body = "{\"value\":[{\"id\":\"file\",\"name\":\"notes.txt\",\"file\":{\"mimeType\":\"text/plain\"},\"size\":7}]}";
        } else if (path == "/graph/drives/remote/items/file/content") {
            body = method == "GET" ? "content" : "{\"id\":\"file\",\"name\":\"notes.txt\",\"size\":7}";
        } else if (path == "/graph/drives/remote/items/file") {
            body = "{\"id\":\"file\",\"name\":\"renamed.txt\",\"size\":7}";
        } else if (path == "/graph/drives/remote/items/folder/children" && method == "POST") {
            body = "{\"id\":\"new-folder\",\"name\":\"New Folder\",\"folder\":{}}";
        } else {
            stderr.printf("Unexpected fixture request: %s %s\n", method, path);
            assert_not_reached();
        }
        message.set_status(200, null);
        message.set_response("application/json", Soup.MemoryUse.COPY, body.data);
    }
}

async void check_shared_storage(Manager manager) throws Error {
    var fixture = new StorageFixture();
    var google_account = manager.get_account("google");
    var microsoft_account = manager.get_account("microsoft");
    var google = new GoogleDrive(google_account, new HttpClient(google_account, Capability.FILES), fixture.url + "google/", fixture.url + "upload/");
    var microsoft = new OneDrive(microsoft_account, new HttpClient(microsoft_account, Capability.FILES), fixture.url + "graph/");
    var destination = new MemoryOutputStream.resizable();
    string source_path = Path.build_filename(Environment.get_tmp_dir(), "storage-source.txt");
    FileUtils.set_contents(source_path, "content");
    try {
        var root = yield google.list("root");
        assert(root.size == 2 && root[0].id == "singularity:shared" && root[1].id == "singularity:drives");
        assert((yield google.list((yield google.stat("root")).id)).size == 2);
        var shared = yield google.list(root[0].id);
        assert(shared.size == 1 && shared[0].is_folder);
        var drives = yield google.list(root[1].id);
        assert(drives.size == 2);
        var files = yield google.list(drives[0].id);
        assert(files.size == 1 && files[0].id == "team-file");
        yield google.download_to(files[0], destination);
        assert(destination.get_data_size() == 7);
        yield google.rename(files[0], "renamed.txt");
        yield google.create_folder(drives[0].id, "New Folder");
        bool rejected = false;
        try { yield google.list("cycle"); } catch (AccountsError.PROTOCOL e) { rejected = true; }
        assert(rejected);
        root = yield microsoft.list("root");
        assert(root.size == 3 && root[0].id == "drive:remote/folder" && root[0].is_folder);
        assert((yield microsoft.list((yield microsoft.stat("root")).id)).size == 3);
        shared = yield microsoft.list("singularity:shared");
        assert(shared.size == 2 && shared[0].id != shared[1].id);
        files = yield microsoft.list(shared[0].id);
        assert(files.size == 1 && files[0].id == "drive:remote/file" && files[0].parent_id == shared[0].id);
        destination = new MemoryOutputStream.resizable();
        yield microsoft.download_to(files[0], destination);
        assert(destination.get_data_size() == 7);
        assert((yield microsoft.stat(files[0].id)).id == files[0].id);
        assert((yield microsoft.rename(files[0], "renamed.txt")).id == files[0].id);
        assert((yield microsoft.replace(files[0], File.new_for_path(source_path))).id == files[0].id);
        assert((yield microsoft.create_folder(shared[0].id, "New Folder")).id == "drive:remote/new-folder");
        drives = yield microsoft.list("singularity:libraries");
        assert(drives.size == 3 && drives[0].name == "Company - Documents" && drives[2].name == "Intranet - Resources");
        int before = fixture.requests;
        foreach (CloudDrive drive in new CloudDrive[] { google, microsoft }) {
            var group = yield drive.stat("singularity:shared");
            rejected = false;
            try { yield drive.delete(group); } catch (IOError.PERMISSION_DENIED e) { rejected = true; }
            assert(rejected);
            rejected = false;
            try { yield drive.create_folder(group.id, "Bad"); } catch (IOError.PERMISSION_DENIED e) { rejected = true; }
            assert(rejected);
        }
        foreach (string id in new string[] { "drive:../file", "drive:remote/%2Ffile", "drive:remote/%", "drive:remote/file/extra" }) {
            rejected = false;
            try { yield microsoft.stat(id); } catch (AccountsError.INVALID e) { rejected = true; }
            assert(rejected);
        }
        rejected = false;
        try { yield microsoft.move(files[0], "drive:other/folder"); } catch (IOError.NOT_SUPPORTED e) { rejected = true; }
        assert(rejected && fixture.requests == before);
        fixture.bad_page = true;
        rejected = false;
        try { yield microsoft.list(shared[0].id); } catch (AccountsError.PROTOCOL e) { rejected = true; }
        assert(rejected);
        fixture.bad_page = false;
        fixture.repeated_page = true;
        rejected = false;
        try { yield microsoft.list(shared[0].id); } catch (AccountsError.PROTOCOL e) { rejected = true; }
        assert(rejected);
    } finally {
        fixture.server.disconnect();
        FileUtils.unlink(source_path);
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
    yield check_shared_storage(manager);
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
