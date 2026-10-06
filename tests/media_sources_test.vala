using Singularity.MediaSources;

class TestHost : Object, MediaHost {
    public HashTable<string, string> values = new HashTable<string, string>(str_hash, str_equal);
    public Gee.ArrayList<string> messages = new Gee.ArrayList<string>();
    private Soup.Session _session = new Soup.Session();

    public string app_id { owned get { return "dev.sinty.music"; } }
    public MediaKind kinds { get { return MediaKind.AUDIO; } }
    public string user_agent { owned get { return "Singularity-Music-Test/1"; } }
    public Soup.Session session { get { return _session; } }
    public bool network_available { get { return true; } }
    public bool window_visible { get { return true; } }

    public string cache_dir(string source_id) {
        return Path.build_filename(Environment.get_tmp_dir(), "media-sources-test", source_id);
    }

    public string? get_value(string source_id, string key) {
        return values.lookup(source_id + "/" + key);
    }

    public void set_value(string source_id, string key, string? value) {
        if (value == null) values.remove(source_id + "/" + key);
        else values.insert(source_id + "/" + key, value);
    }

    public Gee.List<Singularity.Accounts.Account> accounts(Singularity.Accounts.Capability capability) {
        return new Gee.ArrayList<Singularity.Accounts.Account>();
    }

    public void show_message(string source_id, string message) {
        messages.add(message);
    }

    public void open_external(string uri) {
    }
}

MainLoop loop;

void run_async(owned SourceFunc start) {
    loop = new MainLoop();
    Idle.add((owned) start);
    loop.run();
}

void done() {
    loop.quit();
}

async void exercise(SourceRegistry registry, TestHost host) {
    var source = registry.find("fake");
    assert(source != null);
    assert(host.get_value("fake", "activated") == "yes");
    var browsable = source as Browsable;
    var searchable = source as Searchable;
    var resolver = source as PlaybackResolver;
    assert(browsable != null && searchable != null && resolver != null);
    assert((source.features & SourceFeatures.BROWSE) != 0);

    var root = yield browsable.browse(null, null, null);
    assert(root.items.size == 3);
    assert(root.items[0].browsable && !root.items[0].playable);

    var ids = new Gee.ArrayList<string>();
    string? token = null;
    int pages = 0;
    do {
        var page = yield browsable.browse("all", token, null);
        pages++;
        assert(page.total == 10);
        foreach (var it in page.items) ids.add(it.id);
        token = page.next_token;
    } while (token != null);
    assert(pages == 3);
    assert(ids.size == 10);
    assert(ids[0] == "item-1" && ids[9] == "item-10");

    try {
        yield browsable.browse("error", null, null);
        assert_not_reached();
    } catch (MediaError.NETWORK e) {
    } catch (Error e) {
        assert_not_reached();
    }

    var cancel = new Cancellable();
    Timeout.add(100, () => {
        cancel.cancel();
        return Source.REMOVE;
    });
    int64 started = get_monotonic_time();
    try {
        yield browsable.browse("slow", null, cancel);
        assert_not_reached();
    } catch (IOError.CANCELLED e) {
    } catch (Error e) {
        assert_not_reached();
    }
    assert(get_monotonic_time() - started < 1500000);

    var found = yield searchable.search("odd", MediaKind.AUDIO, null, null);
    assert(found.total == 5);
    assert(found.items.size == 4);
    assert(found.has_more);
    var rest = yield searchable.search("odd", MediaKind.AUDIO, found.next_token, null);
    assert(rest.items.size == 1 && !rest.has_more);
    try {
        yield searchable.search("fail", MediaKind.AUDIO, null, null);
        assert_not_reached();
    } catch (MediaError.NETWORK e) {
    } catch (Error e) {
        assert_not_reached();
    }

    var all = yield browsable.browse("all", null, null);
    var kinds = new Gee.HashSet<int>();
    for (int i = 0; i < 4; i++) {
        var pb = yield resolver.resolve(all.items[i], null);
        kinds.add((int) pb.kind);
        switch (pb.kind) {
            case PlaybackKind.STREAM:
                assert(pb.uri != "");
                assert(pb.get_header("User-Agent") == host.user_agent);
                break;
            case PlaybackKind.EMBED:
                assert(pb.embed != null);
                bool ended = false;
                pb.embed.ended.connect(() => ended = true);
                pb.embed.load(all.items[i], 0);
                pb.embed.play();
                assert(pb.embed.state == PlaybackState.PLAYING);
                pb.embed.seek(pb.embed.duration_ms);
                assert(ended);
                break;
            case PlaybackKind.REMOTE:
                assert(pb.remote != null);
                int changes = 0;
                pb.remote.state_changed.connect(() => changes++);
                var devices = yield pb.remote.devices(null);
                assert(devices.size == 1);
                yield pb.remote.play_item(all.items[i], null);
                assert(pb.remote.state == PlaybackState.PLAYING);
                assert(pb.remote.current.id == all.items[i].id);
                yield pb.remote.pause();
                assert(pb.remote.state == PlaybackState.PAUSED);
                assert(changes == 2);
                break;
            case PlaybackKind.EXTERNAL:
                assert(pb.uri.has_prefix("https://"));
                break;
        }
    }
    assert(kinds.size == 4);

    assert(registry.scrobblers().size == 1);
    var sc = registry.scrobblers()[0];
    yield sc.listened(all.items[0], 5000, new DateTime.now_utc(), null);
    assert(registry.metadata_providers().size == 1);
    var lyrics = yield registry.metadata_providers()[0].lyrics(all.items[0], null);
    assert(lyrics != null && lyrics.synced && lyrics.lines.size == 3);
    assert(lyrics.index_at(0) == -1);
    assert(lyrics.index_at(1600) == 1);
}

void test_registry_and_routes() {
    var settings = new GLib.Settings("dev.sinty.test.plugins");
    var plugins = new Singularity.AppPluginHost("dev.sinty.music", "music", settings);
    var host = new TestHost();
    var registry = new SourceRegistry(host, plugins);
    int added = 0;
    int removed = 0;
    registry.source_added.connect(() => added++);
    registry.source_removed.connect(() => removed++);
    plugins.load();
    assert(plugins.plugins().size == 1);
    assert(added == 1);
    run_async(() => {
        exercise.begin(registry, host, (o, r) => {
            exercise.end(r);
            done();
        });
        return Source.REMOVE;
    });

    var info = plugins.plugins()[0];
    assert(Singularity.AppPluginHost.is_hosted_by(info, "dev.sinty.videos"));
    assert(!Singularity.AppPluginHost.is_hosted_by(info, "dev.sinty.photos"));
    settings.set_strv("disabled-plugins", { info.get_module_name() });
    assert(removed == 1);
    assert(registry.find("fake") == null);
    assert(!plugins.is_active(info.get_module_name()));
    plugins.set_enabled(info, true);
    assert(settings.get_strv("disabled-plugins").length == 0);
    assert(added == 2);
    assert(registry.find("fake") != null);
    registry.shutdown();
    assert(removed == 2);
}

void test_video_host_filters() {
    var plugins = new Singularity.AppPluginHost("dev.sinty.photos", "music", null);
    plugins.load();
    assert(plugins.plugins().size == 0);
}

void test_catalog() {
    var list = Singularity.AppPluginHost.catalog();
    bool seen = false;
    foreach (var info in list) if (info.get_module_name() == "media-fake-source") seen = true;
    assert(seen);
    foreach (var info in list) assert(Singularity.AppPluginHost.is_app_plugin(info));
}

void test_lrc() {
    var l = Lyrics.parse_lrc("[ti:Song]\n[offset:500]\n[00:01.00][00:03.00]Chorus\n[00:02.25]Verse\nnot a line");
    assert(l.synced);
    assert(l.lines.size == 3);
    assert(l.lines[0].time_ms == 500 && l.lines[0].text == "Chorus");
    assert(l.lines[1].time_ms == 1750 && l.lines[1].text == "Verse");
    assert(l.lines[2].time_ms == 2500);
    assert(l.index_at(1800) == 1);
    var p = Lyrics.from_plain("a\nb");
    assert(!p.synced && p.lines.size == 2 && p.index_at(5000) == -1);
}

void test_rules() {
    assert(!Scrobbler.counts_as_listen(20000, 20000));
    assert(Scrobbler.counts_as_listen(600000, 240000));
    assert(Scrobbler.counts_as_listen(200000, 100000));
    assert(!Scrobbler.counts_as_listen(200000, 99000));
    assert(MediaKind.parse("audio;video") == (MediaKind.AUDIO | MediaKind.VIDEO));
    ItemKind k;
    assert(ItemKind.try_parse("playlist", out k) && k == ItemKind.PLAYLIST);
    assert(!ItemKind.TRACK.is_container() && ItemKind.ALBUM.is_container());
    assert(Paging.offset_of(null) == 0 && Paging.offset_of("20") == 20);
    assert(Paging.next_of(0, 10, 25) == "10");
    assert(Paging.next_of(20, 5, 25) == null);
    assert(Paging.next_of(0, 10, -1) == "10");
    var item = new MediaItem("s", "1", ItemKind.TRACK, "T");
    item.duration_ms = 3725000;
    item.set_extra("isrc", "X");
    var c = item.copy();
    assert(c.get_extra("isrc") == "X" && c.display_duration() == "1:02:05" && c.key == "s:1");
}

void test_web() {
    var server = new Soup.Server("server-header", "test");
    server.add_handler(null, (srv, msg, path, query) => {
        if (path == "/limited") {
            msg.set_status(429, null);
            msg.get_response_headers().replace("Retry-After", "7");
            msg.set_response("application/json", Soup.MemoryUse.COPY, "{}".data);
        } else if (path == "/ok") {
            msg.set_status(200, null);
            msg.set_response("application/json", Soup.MemoryUse.COPY, "{\"name\":\"x\",\"n\":3,\"list\":[1,2]}".data);
        } else {
            msg.set_status(404, null);
        }
    });
    try {
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
    } catch (Error e) {
        assert_not_reached();
    }
    uint port = 0;
    foreach (var u in server.get_uris()) port = u.get_port();
    string base_url = "http://127.0.0.1:%u".printf(port);
    var session = new Soup.Session();
    run_async(() => {
        run_web.begin(session, base_url, (o, r) => {
            run_web.end(r);
            done();
        });
        return Source.REMOVE;
    });
}

async void run_web(Soup.Session session, string base_url) {
    try {
        var node = yield Web.get_json(session, base_url + "/ok", null, "Test", null);
        var o = node.get_object();
        assert(Web.str(o, "name") == "x" && Web.num(o, "n") == 3 && Web.arr(o, "list").get_length() == 2);
    } catch (Error e) {
        assert_not_reached();
    }
    try {
        yield Web.get_json(session, base_url + "/limited", null, "Test", null);
        assert_not_reached();
    } catch (MediaError.RATE_LIMITED e) {
        assert(e.message.contains("7"));
    } catch (Error e) {
        assert_not_reached();
    }
    try {
        yield Web.get_json(session, base_url + "/missing", null, "Test", null);
        assert_not_reached();
    } catch (MediaError.NOT_FOUND e) {
    } catch (Error e) {
        assert_not_reached();
    }
    var p = new HashTable<string, string>(str_hash, str_equal);
    p.insert("q", "a b&c");
    p.insert("limit", "10");
    assert(Web.query(p) == "limit=10&q=a%20b%26c");
    var whole = new Bytes("{\"a\":1}GARBAGE-AFTER".data);
    var reply = new WebReply(200, new Bytes.from_bytes(whole, 0, 7), new Soup.MessageHeaders(Soup.MessageHeadersType.RESPONSE));
    assert(reply.text() == "{\"a\":1}");
    try {
        assert(Web.num(reply.json().get_object(), "a") == 1);
    } catch (Error e) {
        assert_not_reached();
    }
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/media-sources/rules", test_rules);
    Test.add_func("/media-sources/lrc", test_lrc);
    Test.add_func("/media-sources/registry", test_registry_and_routes);
    Test.add_func("/media-sources/host-filter", test_video_host_filters);
    Test.add_func("/media-sources/catalog", test_catalog);
    Test.add_func("/media-sources/web", test_web);
    return Test.run();
}
