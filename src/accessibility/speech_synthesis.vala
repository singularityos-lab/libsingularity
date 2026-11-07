using GLib;

namespace Singularity {

    public class SpeechVoiceInfo : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public string language { get; construct; }
        public string engine { get; construct; }

        public SpeechVoiceInfo(string id, string name, string language, string engine) {
            Object(id: id, name: name, language: language, engine: engine);
        }
    }

    private class SpeechWaiter {
        public SourceFunc callback;

        public SpeechWaiter(owned SourceFunc callback) {
            this.callback = (owned) callback;
        }
    }

    public class Speech : Object {
        public const string BUS_NAME = "dev.sinty.Speech1";
        public const string OBJECT_PATH = "/dev/sinty/Speech1";
        public const string INTERFACE = "dev.sinty.Speech1";

        private static Speech? instance = null;
        private DBusProxy? proxy = null;
        private HashTable<uint, SpeechWaiter> waiting = new HashTable<uint, SpeechWaiter>(direct_hash, direct_equal);
        private HashTable<uint, bool> results = new HashTable<uint, bool>(direct_hash, direct_equal);
        private HashTable<uint, bool> mine = new HashTable<uint, bool>(direct_hash, direct_equal);

        public bool speaking { get; private set; default = false; }
        public bool paused { get; private set; default = false; }

        public signal void started(uint job);
        public signal void sentence(uint job, int offset, int length);
        public signal void word(uint job, int offset, int length);
        public signal void finished(uint job, bool completed);

        public static Speech get_default() {
            if (instance == null) instance = new Speech();
            return instance;
        }

        public static Speech for_proxy(DBusProxy proxy) {
            var speech = new Speech();
            speech.attach(proxy);
            return speech;
        }

        private void attach(DBusProxy p) {
            proxy = p;
            proxy.g_signal.connect(on_signal);
            proxy.g_properties_changed.connect(() => sync());
            sync();
        }

        private async DBusProxy get_proxy() throws Error {
            if (proxy == null) {
                var p = yield new DBusProxy.for_bus(BusType.SESSION, DBusProxyFlags.NONE,
                    null, BUS_NAME, OBJECT_PATH, INTERFACE, null);
                if (proxy == null) attach(p);
            }
            return proxy;
        }

        private void sync() {
            speaking = cached_bool("Speaking");
            paused = cached_bool("Paused");
        }

        private bool cached_bool(string name) {
            var v = proxy != null ? proxy.get_cached_property(name) : null;
            return v != null && v.is_of_type(VariantType.BOOLEAN) && v.get_boolean();
        }

        private void on_signal(string? sender, string name, Variant args) {
            switch (name) {
            case "Started":
                uint job;
                args.get("(u)", out job);
                if (mine.contains(job)) started(job);
                break;
            case "Sentence":
            case "Word":
                uint job;
                int offset, length;
                args.get("(uii)", out job, out offset, out length);
                if (!mine.contains(job)) break;
                if (name == "Word") word(job, offset, length);
                else sentence(job, offset, length);
                break;
            case "Finished":
                uint job;
                bool completed;
                args.get("(ub)", out job, out completed);
                if (results.size() > 64) results.remove_all();
                results.set(job, completed);
                if (mine.contains(job)) {
                    mine.remove(job);
                    finished(job, completed);
                }
                SpeechWaiter? resume = waiting.get(job);
                if (resume != null) {
                    waiting.remove(job);
                    Idle.add((owned) resume.callback);
                }
                break;
            }
        }

        public async uint speak(string text, string voice = "", double rate = 0, double pitch = 0) throws Error {
            var p = yield get_proxy();
            var reply = yield p.call("Speak", new Variant("(ssdd)", text, voice, rate, pitch), DBusCallFlags.NONE, -1, null);
            uint job;
            reply.get("(u)", out job);
            if (!results.contains(job)) mine.set(job, true);
            return job;
        }

        public bool has_finished(uint job) {
            return results.contains(job) && !mine.contains(job);
        }

        public async bool say(string text, string voice = "", double rate = 0, double pitch = 0) throws Error {
            uint job = yield speak(text, voice, rate, pitch);
            if (!results.contains(job)) {
                waiting.set(job, new SpeechWaiter(say.callback));
                yield;
            }
            bool completed = results.contains(job) && results.get(job);
            results.remove(job);
            return completed;
        }

        public async uint announce(string text) throws Error {
            var p = yield get_proxy();
            var reply = yield p.call("Announce", new Variant("(s)", text), DBusCallFlags.NONE, -1, null);
            uint job;
            reply.get("(u)", out job);
            mine.set(job, true);
            return job;
        }

        public async void preview(string voice) throws Error {
            var p = yield get_proxy();
            var reply = yield p.call("Preview", new Variant("(s)", voice), DBusCallFlags.NONE, -1, null);
            uint job;
            reply.get("(u)", out job);
            mine.set(job, true);
        }

        private async void simple(string method) {
            try {
                var p = yield get_proxy();
                yield p.call(method, null, DBusCallFlags.NONE, -1, null);
            } catch (Error e) {
                debug("Speech.%s: %s", method, e.message);
            }
        }

        public void stop() {
            simple.begin("Stop");
        }

        public void pause() {
            simple.begin("Pause");
        }

        public void resume() {
            simple.begin("Resume");
        }

        public async SpeechVoiceInfo[] voices() throws Error {
            var p = yield get_proxy();
            var reply = yield p.call("ListVoices", null, DBusCallFlags.NONE, -1, null);
            SpeechVoiceInfo[] out_list = {};
            var list = reply.get_child_value(0);
            for (size_t i = 0; i < list.n_children(); i++) {
                var row = list.get_child_value(i);
                if (row.n_children() < 4) continue;
                out_list += new SpeechVoiceInfo(
                    row.get_child_value(0).get_string(),
                    row.get_child_value(1).get_string(),
                    row.get_child_value(2).get_string(),
                    row.get_child_value(3).get_string());
            }
            return out_list;
        }
    }
}
