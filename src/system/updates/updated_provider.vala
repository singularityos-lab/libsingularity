using GLib;

namespace Singularity.Updates {

    public class UpdatedProvider : Provider {
        public const string SOCKET = "/run/updated.sock";

        private string socket_path;
        private string consent_token = "";
        private uint poll_id = 0;

        public string live_class { get; private set; default = ""; }

        public override string kind {
            get { return "image"; }
        }

        public UpdatedProvider(string socket_path = SOCKET) {
            this.socket_path = socket_path;
        }

        ~UpdatedProvider() {
            if (poll_id != 0) Source.remove(poll_id);
        }

        public override async bool probe() {
            if (!FileUtils.test(socket_path, FileTest.EXISTS)) return false;
            try {
                apply(yield request("GET", "/status", 5));
            } catch (Error e) {
                debug("Updates: %s does not answer: %s", socket_path, e.message);
                return false;
            }
            can_download = true;
            can_schedule = false;
            can_unschedule = false;
            has_history = true;
            description = _("Updated as a whole system image. Your files and apps stay as they are.");
            return true;
        }

        internal async Json.Object request(string method, string path, uint timeout) throws Error {
            var cancellable = new Cancellable();
            uint timeout_id = Timeout.add_seconds(timeout, () => {
                cancellable.cancel();
                return Source.REMOVE;
            });
            try {
                var client = new SocketClient();
                var conn = yield client.connect_async(new UnixSocketAddress(socket_path), cancellable);
                var req = method + " " + path + " HTTP/1.0\r\nHost: localhost\r\n\r\n";
                size_t written;
                yield conn.output_stream.write_all_async(req.data, Priority.DEFAULT, cancellable, out written);
                var input = new DataInputStream(conn.input_stream);
                var body = new StringBuilder();
                int code = 0;
                bool in_body = false;
                string? line;
                while ((line = yield input.read_line_async(Priority.DEFAULT, cancellable)) != null) {
                    if (code == 0) {
                        string[] parts = line.chomp().split(" ");
                        if (parts.length < 2 || !int.try_parse(parts[1], out code) || code == 0) {
                            throw new IOError.INVALID_DATA(_("The update service sent an invalid answer"));
                        }
                    } else if (in_body) {
                        if (body.len + line.length > 65536) {
                            throw new IOError.INVALID_DATA(_("The update service sent an invalid answer"));
                        }
                        body.append(line);
                    } else if (line.chomp() == "") {
                        in_body = true;
                    }
                }
                Json.Object? object = null;
                if (body.len > 0) {
                    var parser = new Json.Parser();
                    try {
                        parser.load_from_data(body.str);
                        var root = parser.get_root();
                        if (root != null && root.get_node_type() == Json.NodeType.OBJECT) object = root.get_object();
                    } catch (Error e) {
                        object = null;
                    }
                }
                if (code < 200 || code >= 300) {
                    string message = object != null ? object.get_string_member_with_default("error", "") : "";
                    throw new IOError.FAILED(message != "" ? message : _("The update service refused the request"));
                }
                return object ?? new Json.Object();
            } catch (IOError.CANCELLED e) {
                throw new IOError.TIMED_OUT(_("The update service did not answer in time"));
            } finally {
                if (!cancellable.is_cancelled()) Source.remove(timeout_id);
            }
        }

        internal void apply(Json.Object status) {
            string value = status.get_string_member_with_default("state", "idle");
            string latest = status.get_string_member_with_default("latest", "");
            string build = status.get_string_member_with_default("product_build", "");
            string product = status.get_string_member_with_default("product_name", "");
            string product_version = status.get_string_member_with_default("product_version", "");
            string token = status.get_string_member_with_default("consent_token", "");
            consent_token = valid_token(token) ? token : "";
            live_class = value == "ready" ? live_class_of(status) : "";
            name = HardwareInfo.os_name();
            current_version = HardwareInfo.os_name();
            last_error = "";
            progress = -1;
            switch (value) {
                case "available":
                    state = State.AVAILABLE;
                    break;
                case "downloading":
                    state = State.DOWNLOADING;
                    progress = ((int) status.get_int_member_with_default("percent", 0)).clamp(0, 100) / 100.0;
                    break;
                case "ready":
                    state = State.SCHEDULED;
                    break;
                case "error":
                    state = State.ERROR;
                    last_error = status.get_string_member_with_default("error", "");
                    break;
                default:
                    state = State.UP_TO_DATE;
                    break;
            }
            if (state == State.AVAILABLE || state == State.DOWNLOADING || state == State.SCHEDULED) {
                string label = product != "" ? product : latest;
                if (product != "" && product_version != "") label = product + " " + product_version;
                if (build != "") label = "%s (%s)".printf(label, build);
                available_version = label;
            } else {
                available_version = "";
            }
            last_check = get_real_time() / 1000000;
            changed();
            follow();
        }

        internal static string live_class_of(Json.Object status) {
            if (!status.has_member("live")) return "";
            var node = status.get_member("live");
            if (node.get_node_type() != Json.NodeType.OBJECT) return "";
            var live = node.get_object();
            if (!live.get_boolean_member_with_default("eligible", false)) return "";
            string klass = live.get_string_member_with_default("class", "");
            return klass == "silent" || klass == "reload" || klass == "relogin" ? klass : "";
        }

        internal static bool valid_token(string token) {
            if (token.length != 64) return false;
            for (int i = 0; i < token.length; i++) {
                if (!token[i].isxdigit()) return false;
            }
            return true;
        }

        private void follow() {
            if (state != State.DOWNLOADING) {
                if (poll_id != 0) {
                    Source.remove(poll_id);
                    poll_id = 0;
                }
                return;
            }
            if (poll_id != 0) return;
            poll_id = Timeout.add_seconds(1, () => {
                refresh.begin();
                return Source.CONTINUE;
            });
        }

        private async void refresh() {
            try {
                apply(yield request("GET", "/status", 5));
            } catch (Error e) {
                debug("Updates: refreshing %s failed: %s", socket_path, e.message);
            }
        }

        public override async void check() throws Error {
            state = State.CHECKING;
            last_error = "";
            changed();
            try {
                apply(yield request("GET", "/check", 120));
            } catch (Error e) {
                fail(e);
                throw e;
            }
        }

        public override async void download() throws Error {
            if (consent_token == "") yield refresh();
            if (consent_token == "") {
                var error = new IOError.FAILED(_("No update is ready to download"));
                fail(error);
                throw error;
            }
            state = State.DOWNLOADING;
            progress = 0;
            changed();
            try {
                apply(yield request("POST", "/download?token=" + consent_token, 30));
            } catch (Error e) {
                fail(e);
                throw e;
            }
        }

        public override async void schedule() throws Error {
            yield refresh();
        }

        public async void apply_live() throws Error {
            if (live_class == "") {
                var error = new IOError.FAILED(_("This update cannot be applied without a restart"));
                fail(error);
                throw error;
            }
            try {
                yield request("POST", "/apply-live", 300);
            } catch (Error e) {
                live_class = "";
                fail(e);
                throw e;
            }
            yield refresh();
        }

        public override async void unschedule() throws Error {
            throw new IOError.NOT_SUPPORTED(_("A downloaded system update cannot be put off"));
        }

        public override async Gee.List<HistoryEntry> history() throws Error {
            var list = new Gee.ArrayList<HistoryEntry>();
            Json.Object reply;
            try {
                reply = yield request("GET", "/history", 5);
            } catch (Error e) {
                debug("Updates: no history from %s: %s", socket_path, e.message);
                return list;
            }
            if (!reply.has_member("entries")) return list;
            reply.get_array_member("entries").foreach_element((array, index, node) => {
                var o = node.get_object();
                if (o == null) return;
                string version = o.has_member("version") ? o.get_string_member("version") : "";
                string build = o.has_member("build") ? o.get_string_member("build") : "";
                bool success = !o.has_member("success") || o.get_boolean_member("success");
                int64 time = o.has_member("time") ? o.get_int_member("time") : 0;
                string title = success ? _("Updated to %s").printf(version) : _("Update to %s Failed").printf(version);
                list.add(new HistoryEntry(title, build != "" ? _("Build %s").printf(build) : "", time, success));
            });
            list.sort((a, b) => a.time > b.time ? -1 : (a.time < b.time ? 1 : 0));
            return list;
        }
    }
}
