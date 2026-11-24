using Singularity.Accounts;

[DBus (name = "dev.sinty.Accounts")]
class OrgService : Object {
    [DBus (visible = false)]
    public string cloud_url = "";
    [DBus (visible = false)]
    public string token = "";

    public signal void account_removed(string id);

    public async HashTable<string, Variant>[] list_accounts() throws DBusError, IOError {
        var data = new HashTable<string, Variant>(str_hash, str_equal);
        data.insert("id", "org");
        data.insert("provider", "sinty");
        data.insert("identity", "alice@example.test");
        data.insert("auth", "oauth2");
        data.insert("capabilities", new Variant.strv({ "files" }));
        data.insert("enabled", new Variant.strv({ "files" }));
        var ep = new VariantBuilder(new VariantType("a{ss}"));
        ep.add("{ss}", "files-api", "sinty-cloud");
        ep.add("{ss}", "sinty-cloud", cloud_url);
        data.insert("endpoints", ep.end());
        return { data };
    }

    public async void get_access_token(string id, string capability, bool refresh, out string token, out int expires_in) throws DBusError, IOError {
        token = this.token;
        expires_in = 3600;
    }

    [DBus (visible = false)]
    public string problem = "";

    public async void report_problem(string id, string capability, string reason) throws DBusError, IOError {
        problem = capability + ":" + reason;
    }

    public async void get_credentials(string id, string capability, out string username, out string secret, out string mechanism) throws DBusError, IOError {
        username = "alice@example.test";
        secret = token;
        mechanism = "oauth2";
    }
}

class FakeCloud : Object {
    public Soup.Server server = new Soup.Server(null);
    public Gee.HashMap<string, Bytes> files = new Gee.HashMap<string, Bytes>();
    public Gee.HashSet<string> folders = new Gee.HashSet<string>();
    public Gee.HashMap<string, int> versions = new Gee.HashMap<string, int>();
    public string token = "tok-alice";

    public FakeCloud() {
        folders.add("");
        server.add_handler("/api/v1", handle);
    }

    private string tag(string p) {
        return "\"v%d-%d\"".printf(versions[p], (int) files[p].get_size());
    }

    private Json.Object entry(string p) {
        var o = new Json.Object();
        o.set_string_member("name", p.contains("/") ? p.substring(p.last_index_of("/") + 1) : p);
        o.set_boolean_member("dir", folders.contains(p));
        o.set_int_member("size", folders.contains(p) ? 4096 : files[p].get_size());
        o.set_string_member("modified", "2026-11-24T21:00:00Z");
        o.set_string_member("etag", folders.contains(p) ? "" : tag(p));
        return o;
    }

    private void reply(Soup.ServerMessage msg, uint status, Json.Object? o) {
        msg.set_status(status, null);
        if (o == null) return;
        var node = new Json.Node(Json.NodeType.OBJECT);
        node.set_object(o);
        var gen = new Json.Generator();
        gen.set_root(node);
        msg.set_response("application/json", Soup.MemoryUse.COPY, gen.to_data(null).data);
    }

    private void fail(Soup.ServerMessage msg, uint status, string code) {
        var o = new Json.Object();
        o.set_string_member("error", code);
        reply(msg, status, o);
    }

    private void handle(Soup.Server srv, Soup.ServerMessage msg, string path, HashTable<string, string>? query) {
        if (msg.get_request_headers().get_one("Authorization") != "Bearer " + token) {
            fail(msg, 401, "sign_in");
            return;
        }
        string method = msg.get_method();
        string rest = Uri.unescape_string(path.substring("/api/v1/".length)) ?? "";
        if (rest == "me") {
            var o = new Json.Object();
            int64 used = 0;
            foreach (var b in files.values) used += b.get_size();
            o.set_int_member("used", used);
            o.set_int_member("quota", 1000);
            reply(msg, 200, o);
            return;
        }
        if (rest == "move" && method == "POST") {
            var parser = new Json.Parser();
            try {
                parser.load_from_data((string) msg.get_request_body().flatten().get_data());
            } catch (Error e) {
                fail(msg, 400, "invalid_request");
                return;
            }
            string from = parser.get_root().get_object().get_string_member("from").substring(1);
            string to = parser.get_root().get_object().get_string_member("to").substring(1);
            if (!files.has_key(from) && !folders.contains(from)) {
                fail(msg, 404, "not_found");
                return;
            }
            if (files.has_key(from)) {
                files[to] = files[from];
                versions[to] = versions[from];
                files.unset(from);
            } else {
                folders.remove(from);
                folders.add(to);
            }
            msg.set_status(204, null);
            return;
        }
        int slash = rest.index_of("/");
        string api = slash < 0 ? rest : rest.substring(0, slash);
        string p = slash < 0 ? "" : rest.substring(slash + 1);
        while (p.has_suffix("/")) p = p.substring(0, p.length - 1);
        if (api == "info" && method == "GET") {
            if (!files.has_key(p) && !folders.contains(p)) {
                fail(msg, 404, "not_found");
                return;
            }
            reply(msg, 200, entry(p));
            return;
        }
        if (api == "folders" && method == "POST") {
            folders.add(p);
            msg.set_status(204, null);
            return;
        }
        if (api != "files") {
            fail(msg, 404, "not_found");
            return;
        }
        switch (method) {
            case "GET":
                if (folders.contains(p)) {
                    var arr = new Json.Array();
                    foreach (string k in files.keys) if ((p == "" && !k.contains("/")) || k.has_prefix(p + "/") && !k.substring(p.length + 1).contains("/")) arr.add_object_element(entry(k));
                    foreach (string k in folders) if (k != p && ((p == "" && k != "" && !k.contains("/")) || k.has_prefix(p + "/") && !k.substring(p.length + 1).contains("/"))) arr.add_object_element(entry(k));
                    var o = new Json.Object();
                    o.set_array_member("entries", arr);
                    reply(msg, 200, o);
                } else if (files.has_key(p)) {
                    msg.set_status(200, null);
                    msg.get_response_headers().replace("ETag", tag(p));
                    msg.set_response("application/octet-stream", Soup.MemoryUse.COPY, files[p].get_data());
                } else {
                    fail(msg, 404, "not_found");
                }
                return;
            case "PUT":
                string? match = msg.get_request_headers().get_one("If-Match");
                if (match != null && (!files.has_key(p) || tag(p) != match)) {
                    fail(msg, 412, "changed");
                    return;
                }
                files[p] = msg.get_request_body().flatten();
                versions[p] = versions[p] + 1;
                reply(msg, 200, entry(p));
                return;
            case "DELETE":
                files.unset(p);
                folders.remove(p);
                msg.set_status(204, null);
                return;
        }
        fail(msg, 405, "method");
    }
}

async string read_all(CloudDrive drive, CloudEntry entry) throws Error {
    var output = new MemoryOutputStream.resizable();
    yield drive.download_to(entry, output);
    output.write({ 0 });
    output.close();
    return (string) output.get_data();
}

File local_file(string text) throws Error {
    FileIOStream io;
    var f = File.new_tmp("sinty-cloud-XXXXXX", out io);
    io.close();
    FileUtils.set_contents(f.get_path(), text);
    return f;
}

async void check_drive(string url, string token) throws Error {
    var connection = yield Bus.get(BusType.SESSION);
    var service = new OrgService();
    service.cloud_url = url;
    service.token = token;
    uint registration = connection.register_object(Manager.OBJECT_PATH, service);
    yield connection.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        new Variant("(su)", Manager.BUS_NAME, 0u), new VariantType("(u)"), DBusCallFlags.NONE, 10000);
    var manager = Manager.get_default();
    yield manager.load();
    var account = manager.get_account("org");
    assert(account != null);
    var drive = CloudDrive.for_account(account);
    assert(drive is SintyCloudDrive);
    assert(drive.root_id == "/");

    var folder = yield drive.create_folder("/", "Projects");
    assert(folder.is_folder && folder.id == "/Projects" && folder.parent_id == "/");
    var source = local_file("first draft");
    var uploaded = yield drive.upload("/Projects", "plan è.txt", source);
    assert(uploaded.id == "/Projects/plan è.txt" && uploaded.name == "plan è.txt" && uploaded.size == 11 && uploaded.etag.has_prefix("\""));
    assert(uploaded.content_type == "text/plain");
    var listed = yield drive.list("/Projects");
    assert(listed.size == 1 && listed[0].id == uploaded.id && listed[0].etag == uploaded.etag && listed[0].modified != null);
    var top = yield drive.list("/");
    bool saw_folder = false;
    foreach (var e in top) if (e.id == "/Projects" && e.is_folder) saw_folder = true;
    assert(saw_folder);
    assert((yield read_all(drive, uploaded)) == "first draft");

    FileUtils.set_contents(source.get_path(), "second draft!");
    var second = yield drive.replace_if_match(uploaded, source, uploaded.etag);
    assert(second.etag != uploaded.etag && second.size == 13);
    FileUtils.set_contents(source.get_path(), "lost update");
    bool refused = false;
    try {
        yield drive.replace_if_match(uploaded, source, uploaded.etag);
    } catch (AccountsError.CONFLICT e) {
        refused = true;
    }
    assert(refused);
    assert((yield read_all(drive, yield drive.stat(uploaded.id))) == "second draft!");

    var renamed = yield drive.rename(second, "plan.txt");
    assert(renamed.id == "/Projects/plan.txt" && renamed.size == 13);
    var archive = yield drive.create_folder("/", "Archive");
    var moved = yield drive.move(renamed, archive.id);
    assert(moved.id == "/Archive/plan.txt" && moved.parent_id == "/Archive");
    bool gone = false;
    try {
        yield drive.stat("/Projects/plan.txt");
    } catch (AccountsError.NOT_FOUND e) {
        gone = true;
    }
    assert(gone);

    bool escaped = false;
    try {
        yield drive.stat("/Archive/../../etc/passwd");
    } catch (AccountsError.INVALID e) {
        escaped = true;
    }
    assert(escaped);

    var q = yield drive.quota();
    assert(q != null && q.used >= 13 && q.total > 0);
    yield drive.delete(moved);
    assert((yield drive.list("/Archive")).size == 0);
    source.delete();
    connection.unregister_object(registration);
}

void test_drive() {
    string? url = Environment.get_variable("SINTY_CLOUD_URL");
    string token = Environment.get_variable("SINTY_CLOUD_TOKEN") ?? "";
    FakeCloud? fake = null;
    if (url == null) {
        fake = new FakeCloud();
        try {
            fake.server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
        } catch (Error e) {
            assert_not_reached();
        }
        url = fake.server.get_uris().data.to_string();
        if (url.has_suffix("/")) url = url.substring(0, url.length - 1);
        token = fake.token;
    }
    var loop = new MainLoop();
    check_drive.begin(url, token, (obj, res) => {
        try {
            check_drive.end(res);
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
        string dir = DirUtils.make_tmp("scd-XXXXXX");
        string config = Path.build_filename(dir, "bus.conf");
        string socket = Path.build_filename(dir, "bus");
        FileUtils.set_contents(config, "<busconfig><type>session</type><listen>unix:path=" + socket + "</listen><auth>EXTERNAL</auth><policy context=\"default\"><allow send_destination=\"*\"/><allow receive_sender=\"*\"/><allow own=\"*\"/></policy></busconfig>");
        Environment.set_variable("DBUS_SESSION_BUS_ADDRESS", "unix:path=" + socket, true);
        var daemon = new Subprocess(SubprocessFlags.STDOUT_PIPE, "dbus-daemon", "--nofork", "--config-file=" + config, "--print-address=1");
        var output = new DataInputStream(daemon.get_stdout_pipe());
        string? address = output.read_line();
        assert(address != null);
        Test.add_func("/accounts/sinty-cloud-drive", test_drive);
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
