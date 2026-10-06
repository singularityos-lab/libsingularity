using Singularity.MediaSources;

namespace FakeMedia {

    public class FakeRemote : Object, RemotePlayer {
        private PlaybackState _state = PlaybackState.STOPPED;
        private MediaItem? _current = null;
        private int64 _position = 0;
        private double _volume = 0.5;
        private RemoteDevice _device = new RemoteDevice("speaker", "Kitchen Speaker");

        public PlaybackState state { get { return _state; } }
        public MediaItem? current { owned get { return _current; } }
        public int64 position_ms { get { return _position; } }
        public int64 duration_ms { get { return _current != null ? _current.duration_ms : 0; } }
        public double volume { get { return _volume; } }
        public RemoteDevice? device { owned get { return _device; } }

        public async Gee.List<RemoteDevice> devices(Cancellable? cancellable) throws Error {
            var list = new Gee.ArrayList<RemoteDevice>();
            _device.active = true;
            list.add(_device);
            return list;
        }

        public async void transfer(string device_id, bool play) throws Error {
            if (device_id != _device.id) throw new MediaError.NOT_FOUND("No device %s", device_id);
            if (play) _state = PlaybackState.PLAYING;
            state_changed();
        }

        public async void play_item(MediaItem item, MediaItem? context) throws Error {
            _current = item;
            _position = 0;
            _state = PlaybackState.PLAYING;
            state_changed();
        }

        public async void resume() throws Error {
            _state = PlaybackState.PLAYING;
            state_changed();
        }

        public async void pause() throws Error {
            _state = PlaybackState.PAUSED;
            state_changed();
        }

        public async void next() throws Error {
            state_changed();
        }

        public async void previous() throws Error {
            state_changed();
        }

        public async void seek(int64 position_ms) throws Error {
            _position = position_ms;
            state_changed();
        }

        public async void set_volume(double volume) throws Error {
            _volume = volume.clamp(0, 1);
            state_changed();
        }

        public void set_active(bool active) {
        }
    }

    public class FakeEmbed : Object, EmbeddedPlayer {
        private Gtk.Widget? _widget = null;
        private PlaybackState _state = PlaybackState.STOPPED;
        private int64 _position = 0;
        private int64 _duration = 0;
        private double _volume = 1;

        public Gtk.Widget widget {
            get {
                if (_widget == null) _widget = new Gtk.Label("Embedded player");
                return _widget;
            }
        }
        public int min_width { get { return 200; } }
        public int min_height { get { return 200; } }
        public PlaybackState state { get { return _state; } }
        public int64 position_ms { get { return _position; } }
        public int64 duration_ms { get { return _duration; } }
        public double volume { get { return _volume; } }

        public void load(MediaItem item, int64 start_ms) {
            _duration = item.duration_ms;
            _position = start_ms;
            _state = PlaybackState.PAUSED;
            state_changed();
        }

        public void play() {
            _state = PlaybackState.PLAYING;
            state_changed();
        }

        public void pause() {
            _state = PlaybackState.PAUSED;
            state_changed();
        }

        public void seek(int64 position_ms) {
            _position = position_ms;
            if (_duration > 0 && _position >= _duration) {
                _state = PlaybackState.STOPPED;
                state_changed();
                ended();
            }
        }

        public void set_volume(double volume) {
            _volume = volume;
        }

        public void stop() {
            _state = PlaybackState.STOPPED;
            state_changed();
        }
    }

    public class FakeSource : Object, MediaSource, Browsable, Searchable, PlaybackResolver, Scrobbler, MetadataProvider {
        public const int PAGE = 4;
        private MediaHost? host = null;
        private FakeRemote remote = new FakeRemote();
        public int now_playing_count = 0;
        public int listened_count = 0;

        public string id { owned get { return "fake"; } }
        public string title { owned get { return "Test Source"; } }
        public string icon_name { owned get { return "folder-music-symbolic"; } }
        public MediaKind kinds { get { return MediaKind.AUDIO | MediaKind.VIDEO; } }
        public SourceFeatures features {
            get { return SourceFeatures.BROWSE | SourceFeatures.SEARCH | SourceFeatures.PLAY | SourceFeatures.REMOTE | SourceFeatures.EMBED | SourceFeatures.SCROBBLE | SourceFeatures.LYRICS; }
        }
        public string? account_capability { owned get { return null; } }
        public bool enabled { get { return host != null; } }

        public void activate(MediaHost host) {
            this.host = host;
            host.set_value(id, "activated", "yes");
        }

        public void deactivate() {
            host = null;
        }

        private static string media_dir() {
            return Environment.get_variable("SINGULARITY_FAKE_SOURCE_MEDIA") ?? "";
        }

        public MediaItem make(int i) {
            var item = new MediaItem(id, "item-%d".printf(i), ItemKind.TRACK, "Sample %d".printf(i));
            item.artist = i % 2 == 0 ? "Even Band" : "Odd Band";
            item.album = "Test Album";
            item.subtitle = item.artist;
            item.track_number = i;
            item.duration_ms = 3000 + i * 1000;
            item.attribution = "Test Source";
            item.external_url = "https://example.invalid/item/%d".printf(i);
            item.external_label = "Open on Example";
            string dir = media_dir();
            if (dir != "") {
                string path = Path.build_filename(dir, "sample-%d.wav".printf(i));
                if (FileUtils.test(path, FileTest.EXISTS)) item.stream_uri = File.new_for_path(path).get_uri();
            }
            if (dir != "") {
                string cover = Path.build_filename(dir, "cover.png");
                if (FileUtils.test(cover, FileTest.EXISTS)) item.image_url = File.new_for_path(cover).get_uri();
            }
            return item;
        }

        public async MediaPage browse(string? node, string? token, Cancellable? cancellable) throws Error {
            if (node == null || node == "") {
                var root = new MediaPage(title);
                var all = new MediaItem(id, "all", ItemKind.FOLDER, "All Items");
                all.subtitle = "10 items";
                root.add(all);
                var broken = new MediaItem(id, "error", ItemKind.FOLDER, "Broken Folder");
                root.add(broken);
                root.add(new MediaItem(id, "slow", ItemKind.FOLDER, "Slow Folder"));
                return root;
            }
            if (node == "error") throw new MediaError.NETWORK("The test server is not answering");
            if (node == "slow") {
                uint timer = Timeout.add(2000, browse.callback);
                ulong handler = 0;
                if (cancellable != null) handler = cancellable.connect(() => Idle.add(browse.callback));
                yield;
                Source.remove(timer);
                if (cancellable != null) cancellable.disconnect(handler);
                if (cancellable != null && cancellable.is_cancelled()) throw new IOError.CANCELLED("Cancelled");
                return new MediaPage("Slow Folder");
            }
            if (node != "all") throw new MediaError.NOT_FOUND("No folder %s", node);
            var page = new MediaPage("All Items");
            page.total = 10;
            int offset = Paging.offset_of(token);
            for (int i = offset; i < int.min(offset + PAGE, 10); i++) page.add(make(i + 1));
            page.next_token = Paging.next_of(offset, page.items.size, 10);
            return page;
        }

        public async MediaPage search(string query, MediaKind kinds, string? token, Cancellable? cancellable) throws Error {
            if (query == "fail") throw new MediaError.NETWORK("Search is down");
            var page = new MediaPage("Results");
            var matches = new Gee.ArrayList<MediaItem>();
            for (int i = 1; i <= 10; i++) {
                var it = make(i);
                if (it.title.down().contains(query.down()) || it.artist.down().contains(query.down())) matches.add(it);
            }
            page.total = matches.size;
            int offset = Paging.offset_of(token);
            for (int i = offset; i < int.min(offset + PAGE, matches.size); i++) page.add(matches[i]);
            page.next_token = Paging.next_of(offset, page.items.size, matches.size);
            return page;
        }

        public async Playback resolve(MediaItem item, Cancellable? cancellable) throws Error {
            int n = item.track_number;
            switch (n % 4) {
                case 1: {
                    var p = Playback.stream(item.stream_uri != "" ? item.stream_uri : "file:///nonexistent/sample.wav");
                    p.set_header("User-Agent", host != null ? host.user_agent : "test");
                    return p;
                }
                case 2: return Playback.embedded(new FakeEmbed());
                case 3: return Playback.remote_control(remote);
                default: return Playback.external(item.external_url);
            }
        }

        public async void now_playing(MediaItem item, Cancellable? cancellable) throws Error {
            now_playing_count++;
        }

        public async void listened(MediaItem item, int64 played_ms, DateTime started, Cancellable? cancellable) throws Error {
            listened_count++;
        }

        public async Lyrics? lyrics(MediaItem item, Cancellable? cancellable) throws Error {
            if (item.source_id != id) return null;
            var l = Lyrics.parse_lrc("[00:00.50]First line\n[00:01.50]Second line\n[00:02.50]Third line");
            l.attribution = "Test Source";
            return l;
        }

        public async MediaItem? enrich(MediaItem item, Cancellable? cancellable) throws Error {
            return null;
        }
    }
}

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.MediaSources.MediaSource), typeof(FakeMedia.FakeSource));
}
