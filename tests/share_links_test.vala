using Singularity.Accounts;

Soup.Session raw_session;
MainLoop loop;

class Raw : Object {
    public uint status;
    public string body = "";
}

async Raw raw(string method, string url, string? auth = null, HashTable<string, string>? headers = null) {
    var r = new Raw();
    var msg = new Soup.Message(method, url);
    if (auth != null) msg.request_headers.replace("Authorization", auth);
    if (headers != null) headers.foreach((k, v) => msg.request_headers.replace(k, v));
    try {
        var bytes = yield raw_session.send_and_read_async(msg, Priority.DEFAULT, null);
        r.body = HttpResponse.bytes_to_string(bytes);
    } catch (Error e) {
        r.body = e.message;
    }
    r.status = msg.status_code;
    return r;
}

async string google_token() {
    var r = yield raw("GET", "http://127.0.0.1:18081/_control/mint?provider=google&aud=google");
    try {
        var p = new Json.Parser();
        p.load_from_data(r.body);
        return "Bearer " + p.get_root().get_object().get_string_member("access_token");
    } catch (Error e) {
        return "";
    }
}

Account? find(string provider) {
    foreach (var a in Manager.get_default().get_accounts()) if (a.provider == provider) return a;
    return null;
}

File sample(string name, string text) throws Error {
    var dir = Path.build_filename(Environment.get_tmp_dir(), "share-links-test");
    DirUtils.create_with_parents(dir, 0700);
    var file = File.new_for_path(Path.build_filename(dir, name));
    FileUtils.set_contents(file.get_path(), text);
    return file;
}

void test_path_of() {
    var account = (Account) Object.new(typeof(Account), "id", "x");
    var ocs = new OcsLinks(account, new HttpClient(account, Capability.FILES), "http://h/", "http://h/remote.php/dav/files/alice/");
    assert(ocs.path_of("/remote.php/dav/files/alice/Documents/Report.odt") == "/Documents/Report.odt");
    assert(ocs.path_of("/remote.php/dav/files/alice/Photos/") == "/Photos");
    assert(ocs.path_of("/remote.php/dav/files/alice/a b/c.txt") == "/a b/c.txt");
}

void test_access_ids() {
    assert(LinkAccess.from_id("edit") == LinkAccess.EDIT);
    assert(LinkAccess.from_id("view") == LinkAccess.VIEW);
    assert(LinkAccess.from_id("other") == LinkAccess.VIEW);
    assert(LinkAccess.EDIT.to_id() == "edit");
}

void test_qr() {
    try {
        var code = Singularity.QrCode.encode_text("https://example.com/s/abc", Singularity.QrEcLevel.MEDIUM);
        assert(code.version >= 1 && code.size == 17 + 4 * code.version);
        assert(code.get_module(0, 0) && code.get_module(6, 6) && !code.get_module(7, 7));
        var png = code.to_png(4);
        assert(png.length > 8 && png[1] == 'P' && png[2] == 'N' && png[3] == 'G');
    } catch (Error e) {
        error("%s", e.message);
    }
}

async void provider_round(string provider, string? error_out) {
    var account = find(provider);
    if (account == null) {
        print("SKIP %s: no account\n", provider);
        return;
    }
    var links = LinkSharing.for_account(account);
    assert(links != null);
    try {
        string stamp = "%s-%lld".printf(provider, get_real_time());
        var file = sample("share-%s.txt".printf(stamp), "shared from the test " + stamp);

        var shared = yield CloudShare.share_file(file, account, LinkAccess.VIEW, null, null);
        assert(shared.uploaded != null);
        assert(shared.link.url.has_prefix("http"));
        print("  %s view link %s\n", provider, shared.link.url);
        yield check_link(provider, account, shared, true, "reader");

        var second = yield CloudShare.upload(account, file, null);
        assert(second.name != shared.uploaded.name);
        print("  %s second upload kept both: %s, %s\n", provider, shared.uploaded.name, second.name);
        var drive = CloudDrive.for_account(account);
        yield drive.delete(second, null);

        yield CloudShare.unshare(shared, null);
        yield check_link(provider, account, shared, false, "");
        print("  %s undo removed link and uploaded copy\n", provider);

        var entry = yield CloudShare.upload(account, file, null);
        var expiry = new DateTime.now_local().add_days(7);
        var edit = yield links.create_link(entry, LinkAccess.EDIT, links.supports_expiry ? expiry : null, null);
        var edit_shared = new SharedFile(edit, entry, file);
        yield check_link(provider, account, edit_shared, true, "writer");
        if (links.supports_expiry) {
            assert(edit.expires != null);
            assert(edit.expires.format("%Y-%m-%d") == expiry.format("%Y-%m-%d"));
            print("  %s edit link with expiry %s\n", provider, edit.expires.format("%Y-%m-%d"));
        } else {
            assert(edit.expires == null);
            print("  %s edit link (no expiry support)\n", provider);
        }
        yield CloudShare.unshare(edit_shared, null);
        print("OK %s\n", provider);
    } catch (Error e) {
        error("%s: %s", provider, e.message);
    }
}

async void check_link(string provider, Account account, SharedFile shared, bool present, string role) {
    switch (provider) {
        case "google": {
            string auth = yield google_token();
            var r = yield raw("GET", "http://127.0.0.1:18081/drive/v3/files/%s/permissions".printf(shared.link.entry_id), auth);
            if (present) {
                assert(r.status == 200);
                assert(r.body.contains("\"anyoneWithLink\""));
                assert(r.body.contains("\"%s\"".printf(role)));
            } else {
                assert(r.status == 404 || !r.body.contains("anyoneWithLink"));
            }
            break;
        }
        case "microsoft": {
            var r = yield raw("GET", shared.link.url);
            if (present) {
                assert(r.status == 200);
                assert(r.body.has_prefix("shared from the test"));
            } else {
                assert(r.status == 404);
            }
            break;
        }
        default: {
            var r = yield raw("GET", shared.link.url);
            if (present) {
                assert(r.status == 200);
                assert(r.body.has_prefix("shared from the test"));
                var h = new HashTable<string, string>(str_hash, str_equal);
                h.insert("OCS-APIRequest", "true");
                var s = yield raw("GET", "http://127.0.0.1:18080/ocs/v2.php/apps/files_sharing/api/v1/shares/%s?format=json".printf(shared.link.share_id),
                    "Basic " + Base64.encode("alice:alicepass".data), h);
                assert(s.body.contains("\"permissions\": %s".printf(role == "writer" ? "3" : "1")));
            } else {
                assert(r.status == 404);
            }
            break;
        }
    }
}

async void run_fakes() {
    raw_session = new Soup.Session();
    var manager = Manager.get_default();
    yield manager.load();
    foreach (string p in new string[] { "nextcloud", "google", "microsoft" }) yield provider_round(p, null);
    loop.quit();
}

void test_against_fakes() {
    if (Environment.get_variable("SINGULARITY_SHARE_FAKES") == null) {
        Test.skip("set SINGULARITY_SHARE_FAKES=1 inside the accounts harness to run against the fake servers");
        return;
    }
    loop = new MainLoop();
    run_fakes.begin();
    loop.run();
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/share/ocs-path", test_path_of);
    Test.add_func("/share/access-ids", test_access_ids);
    Test.add_func("/share/qr", test_qr);
    Test.add_func("/share/fakes", test_against_fakes);
    return Test.run();
}
