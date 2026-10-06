using GLib;

namespace Singularity {

    public class MicrophoneClient : CameraClient {
    }

    public class MicrophoneClients : Object {
        private static MicrophoneClients? instance = null;

        public signal void changed();

        public bool in_use { get; private set; default = false; }

        private HashTable<string, string> users = new HashTable<string, string>(str_hash, str_equal);
        private GenericArray<string> order = new GenericArray<string>();

        public static MicrophoneClients get_default() {
            if (instance == null) instance = new MicrophoneClients();
            return instance;
        }

        public void acquire(string id, string label) {
            if (!users.contains(id)) order.add(id);
            users[id] = label;
            update();
        }

        public void release(string id) {
            if (!users.contains(id)) return;
            users.remove(id);
            uint index;
            if (order.find_with_equal_func(id, str_equal, out index)) order.remove_index(index);
            update();
        }

        public string[] labels() {
            string[] result = {};
            foreach (var id in order.data) result += users[id];
            return result;
        }

        public MicrophoneClient[] local_clients() {
            MicrophoneClient[] result = {};
            foreach (var id in order.data) {
                var client = new MicrophoneClient();
                client.name = users[id];
                result += client;
            }
            return result;
        }

        private void update() {
            bool now = users.size() > 0;
            if (now != in_use) in_use = now;
            changed();
        }

        public static async MicrophoneClient[] query(Cancellable? cancellable = null) {
            MicrophoneClient[] graph = {};
            try {
                var process = new Subprocess(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE, "pw-dump");
                string? output = null;
                yield process.communicate_utf8_async(null, cancellable, out output, null);
                if (output != null) graph = parse_dump(output);
            } catch (Error e) {
            }
            var local = get_default();
            return merge(local.local_clients(), local.order.data, graph);
        }

        public static MicrophoneClient[] merge(MicrophoneClient[] local, string[] local_ids, MicrophoneClient[] graph) {
            MicrophoneClient[] result = local;
            foreach (var client in graph) {
                bool duplicate = false;
                for (int i = 0; i < local.length && !duplicate; i++) {
                    string id = i < local_ids.length ? local_ids[i] : "";
                    duplicate = client.name == local[i].name || client.name.down() == id.down();
                }
                if (!duplicate) result += client;
            }
            return result;
        }

        public static MicrophoneClient[] parse_dump(string json) {
            MicrophoneClient[] result = {};
            var parser = new Json.Parser();
            try {
                parser.load_from_data(json);
            } catch (Error e) {
                return result;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return result;
            var nodes = new HashTable<int64?, Json.Object>(int64_hash, int64_equal);
            var clients = new HashTable<int64?, Json.Object>(int64_hash, int64_equal);
            var sources = new GenericSet<int64?>(int64_hash, int64_equal);
            var links = new GenericArray<Json.Object>();
            foreach (var element in root.get_array().get_elements()) {
                if (element.get_node_type() != Json.NodeType.OBJECT) continue;
                var obj = element.get_object();
                if (!obj.has_member("id") || !obj.has_member("type")) continue;
                int64 id = obj.get_int_member("id");
                string type = obj.get_string_member("type");
                var info = obj.has_member("info") && obj.get_member("info").get_node_type() == Json.NodeType.OBJECT
                    ? obj.get_object_member("info") : null;
                if (info == null) continue;
                if (type == "PipeWire:Interface:Node") {
                    var props = props_of(info);
                    if (props == null) continue;
                    nodes[id] = info;
                    if (text(props, "media.class") == "Audio/Source") sources.add(id);
                } else if (type == "PipeWire:Interface:Client") {
                    if (props_of(info) != null) clients[id] = info;
                } else if (type == "PipeWire:Interface:Link") {
                    links.add(info);
                }
            }
            var seen = new GenericSet<int64?>(int64_hash, int64_equal);
            foreach (var link in links.data) {
                if (!link.has_member("output-node-id") || !link.has_member("input-node-id")) continue;
                int64 output = link.get_int_member("output-node-id");
                int64 input = link.get_int_member("input-node-id");
                if (!sources.contains(output) || seen.contains(input)) continue;
                var stream = nodes[input];
                if (stream == null) continue;
                var props = props_of(stream);
                if (!text(props, "media.class").has_prefix("Stream/Input/Audio")) continue;
                if (text(props, "stream.monitor") == "true") continue;
                seen.add(input);
                Json.Object? client_props = null;
                string client_id = text(props, "client.id");
                int64 cid = 0;
                if (client_id != "" && int64.try_parse(client_id, out cid) && clients.contains(cid))
                    client_props = props_of(clients[cid]);
                var client = new MicrophoneClient();
                client.name = first(props, client_props, "application.name");
                if (client.name == "") client.name = first(props, client_props, "node.name");
                string app_id = first(props, client_props, "pipewire.access.portal.app_id");
                client.app_id = app_id != "" ? app_id : null;
                string binary = first(props, client_props, "application.process.binary");
                client.binary = binary != "" ? binary : null;
                int64 pid = 0;
                if (int64.try_parse(first(props, client_props, "application.process.id"), out pid)) client.pid = (int) pid;
                result += client;
            }
            return result;
        }

        private static Json.Object? props_of(Json.Object info) {
            if (!info.has_member("props") || info.get_member("props").get_node_type() != Json.NodeType.OBJECT) return null;
            return info.get_object_member("props");
        }

        private static string first(Json.Object? a, Json.Object? b, string key) {
            string value = a != null ? text(a, key) : "";
            if (value == "" && b != null) value = text(b, key);
            return value;
        }

        private static string text(Json.Object? props, string key) {
            if (props == null || !props.has_member(key)) return "";
            var node = props.get_member(key);
            if (node.get_node_type() != Json.NodeType.VALUE) return "";
            var type = node.get_value_type();
            if (type == typeof(string)) return node.get_string();
            if (type == typeof(int64)) return node.get_int().to_string();
            if (type == typeof(bool)) return node.get_boolean() ? "true" : "false";
            return "";
        }
    }
}
