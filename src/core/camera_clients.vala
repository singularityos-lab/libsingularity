using GLib;

namespace Singularity {

    /** An app that is receiving pictures from a camera. */
    public class CameraClient : Object {
        /** Name the app gave to its stream, such as "Firefox". */
        public string name { get; set; default = ""; }
        /** Flatpak or portal app id when the app came through a portal, else null. */
        public string? app_id { get; set; default = null; }
        /** Process id of the app, or 0 when unknown. */
        public int pid { get; set; default = 0; }
        /** Executable name of the app, or null. */
        public string? binary { get; set; default = null; }
    }

    /**
     * Finds the apps using a camera through PipeWire, which is how apps
     * reach a camera through the camera portal. With PipeWire the device
     * file is held by PipeWire itself, so the camera indicator names the
     * app from the stream properties instead of from open files.
     */
    public class CameraClients : Object {
        /**
         * Reads the running PipeWire graph with `pw-dump` and returns the
         * streams linked to a camera source.
         */
        public static async CameraClient[] query(Cancellable? cancellable = null) {
            try {
                var process = new Subprocess(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE, "pw-dump");
                string? output = null;
                yield process.communicate_utf8_async(null, cancellable, out output, null);
                if (output == null) return {};
                return parse_dump(output);
            } catch (Error e) {
                return {};
            }
        }

        /**
         * Returns the streams in a `pw-dump` document that a link connects
         * to a camera source: a `Video/Source` node from the v4l2 or
         * libcamera backend. Names and ids come from the stream node,
         * completed by its client.
         */
        public static CameraClient[] parse_dump(string json) {
            CameraClient[] result = {};
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
            var cameras = new GenericSet<int64?>(int64_hash, int64_equal);
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
                    if (text(props, "media.class") == "Video/Source" && is_camera(props)) cameras.add(id);
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
                if (!cameras.contains(output) || seen.contains(input)) continue;
                var stream = nodes[input];
                if (stream == null) continue;
                var props = props_of(stream);
                if (!text(props, "media.class").has_prefix("Stream/Input/Video")) continue;
                seen.add(input);
                Json.Object? client_props = null;
                string client_id = text(props, "client.id");
                int64 cid = 0;
                if (client_id != "" && int64.try_parse(client_id, out cid) && clients.contains(cid))
                    client_props = props_of(clients[cid]);
                var client = new CameraClient();
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

        private static bool is_camera(Json.Object props) {
            string api = text(props, "device.api");
            if (api == "v4l2" || api == "libcamera") return true;
            return props.has_member("api.v4l2.path") || props.has_member("api.libcamera.location")
                || text(props, "factory.name").has_prefix("api.v4l2") || text(props, "factory.name").has_prefix("api.libcamera");
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
            return "";
        }
    }
}
