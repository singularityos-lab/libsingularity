namespace Singularity.MediaSources {

    public class SourceRegistry : Object {
        private Gee.ArrayList<MediaSource> _sources = new Gee.ArrayList<MediaSource>();
        private Gee.HashSet<MediaSource> _builtin = new Gee.HashSet<MediaSource>();

        public MediaHost host { get; construct; }
        public AppPluginHost? plugins { get; construct; }

        public signal void source_added(MediaSource source);
        public signal void source_removed(MediaSource source);

        public SourceRegistry(MediaHost host, AppPluginHost? plugins) {
            Object(host: host, plugins: plugins);
        }

        construct {
            if (plugins != null) {
                plugins.extension_added.connect((info, ext) => {
                    var source = ext as MediaSource;
                    if (source != null) attach(source);
                });
                plugins.extension_removed.connect((info, ext) => {
                    var source = ext as MediaSource;
                    if (source != null) detach(source);
                });
                plugins.add_extension_type(typeof(MediaSource));
            }
        }

        public void add_builtin(MediaSource source) {
            _builtin.add(source);
            attach(source);
        }

        public void remove_builtin(MediaSource source) {
            _builtin.remove(source);
            detach(source);
        }

        public bool is_builtin(MediaSource source) {
            return _builtin.contains(source);
        }

        private void attach(MediaSource source) {
            if (_sources.contains(source) || find(source.id) != null) return;
            if ((source.kinds & host.kinds) == 0) return;
            _sources.add(source);
            source.activate(host);
            source_added(source);
        }

        private void detach(MediaSource source) {
            if (!_sources.contains(source)) return;
            _sources.remove(source);
            source.deactivate();
            source_removed(source);
        }

        public Gee.List<MediaSource> sources {
            owned get {
                var copy = new Gee.ArrayList<MediaSource>();
                copy.add_all(_sources);
                return copy;
            }
        }

        public MediaSource? find(string id) {
            foreach (var s in _sources) if (s.id == id) return s;
            return null;
        }

        public Gee.List<Scrobbler> scrobblers() {
            var result = new Gee.ArrayList<Scrobbler>();
            foreach (var s in _sources) {
                var sc = s as Scrobbler;
                if (sc != null) result.add(sc);
            }
            return result;
        }

        public Gee.List<MetadataProvider> metadata_providers() {
            var result = new Gee.ArrayList<MetadataProvider>();
            foreach (var s in _sources) {
                var m = s as MetadataProvider;
                if (m != null) result.add(m);
            }
            return result;
        }

        public void shutdown() {
            foreach (var s in sources) detach(s);
        }
    }
}
