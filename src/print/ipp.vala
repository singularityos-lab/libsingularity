namespace Singularity.Print {

    [CCode (cname = "singularity_ipp_transport_request", cheader_filename = "print/ipp_transport.h")]
    private extern Variant? ipp_transport_request(string? uri, int operation, string? resource,
                                                   Variant? attributes, string? document_path) throws Error;

    [CCode (cname = "singularity_ipp_transport_server", cheader_filename = "print/ipp_transport.h")]
    private extern string ipp_transport_server();

    /**
     * IPP operation codes used by the print stack. The CUPS extension
     * operations are part of the dialect libcups speaks on the CUPS
     * socket, which other spoolers such as Torchio also answer.
     */
    public enum IppOperation {
        PRINT_JOB = 0x0002,
        VALIDATE_JOB = 0x0004,
        CREATE_JOB = 0x0005,
        SEND_DOCUMENT = 0x0006,
        CANCEL_JOB = 0x0008,
        GET_JOB_ATTRIBUTES = 0x0009,
        GET_JOBS = 0x000A,
        GET_PRINTER_ATTRIBUTES = 0x000B,
        HOLD_JOB = 0x000C,
        RELEASE_JOB = 0x000D,
        RESTART_JOB = 0x000E,
        PAUSE_PRINTER = 0x0010,
        RESUME_PRINTER = 0x0011,
        PURGE_JOBS = 0x0012,
        CUPS_GET_DEFAULT = 0x4001,
        CUPS_GET_PRINTERS = 0x4002,
        CUPS_ADD_MODIFY_PRINTER = 0x4003,
        CUPS_DELETE_PRINTER = 0x4004,
        CUPS_ACCEPT_JOBS = 0x4008,
        CUPS_REJECT_JOBS = 0x4009,
        CUPS_SET_DEFAULT = 0x400A,
        CUPS_GET_DEVICES = 0x400B
    }

    public errordomain PrintError {
        FAILED,
        NOT_AUTHORIZED,
        NOT_FOUND,
        UNSUPPORTED,
        UNREACHABLE,
        CANCELLED,
        INVALID
    }

    /**
     * One IPP request. Attributes are added in order; `send()` runs the
     * request on a worker thread against the local spooler socket, or
     * against `uri` when the request targets a device directly.
     */
    public class IppRequest : Object {
        public IppOperation operation;
        public string? uri { get; set; }
        public string resource { get; set; default = "/"; }
        public string? document_path { get; set; }
        private VariantBuilder attrs = new VariantBuilder(new VariantType("a(sssv)"));

        public IppRequest(IppOperation operation) {
            this.operation = operation;
        }

        public IppRequest add(string group, string tag, string name, Variant value) {
            attrs.add("(sssv)", group, tag, name, value);
            return this;
        }

        public IppRequest operation_attr(string tag, string name, Variant value) {
            return add("operation", tag, name, value);
        }

        public IppRequest job_attr(string tag, string name, Variant value) {
            return add("job", tag, name, value);
        }

        public IppRequest printer_attr(string tag, string name, Variant value) {
            return add("printer", tag, name, value);
        }

        public IppRequest printer_uri(string value) {
            return operation_attr("uri", "printer-uri", value);
        }

        public IppRequest requested(string[] names) {
            return operation_attr("keyword", "requested-attributes", names);
        }

        public IppRequest user() {
            return operation_attr("name", "requesting-user-name", Environment.get_user_name());
        }

        public IppResponse send_sync() throws Error {
            var reply = ipp_transport_request(uri, (int) operation, uri != null ? null : resource,
                                              attrs.end(), document_path);
            if (reply == null) throw new PrintError.UNREACHABLE(_("The print service did not answer"));
            return new IppResponse(reply);
        }

        public async IppResponse send(Cancellable? cancellable = null) throws Error {
            IppResponse? result = null;
            Error? failure = null;
            var thread = new Thread<bool>("ipp-request", () => {
                try {
                    result = send_sync();
                } catch (Error e) {
                    failure = e;
                }
                Idle.add(send.callback);
                return true;
            });
            yield;
            thread.join();
            if (cancellable != null && cancellable.is_cancelled())
                throw new PrintError.CANCELLED(_("Cancelled"));
            if (failure != null) {
                if (failure is PrintError) throw failure;
                throw new PrintError.UNREACHABLE(failure.message);
            }
            return result;
        }

        public static string server() {
            return ipp_transport_server();
        }
    }

    /**
     * An IPP response: status code, status message and the attribute
     * groups in the order the server returned them.
     */
    public class IppResponse : Object {
        public int status { get; private set; }
        public string message { get; private set; }
        public Gee.ArrayList<IppGroup> groups { get; private set; default = new Gee.ArrayList<IppGroup>(); }

        public bool ok {
            get { return status < 0x0400; }
        }

        internal IppResponse(Variant reply) {
            int code = 0;
            string text = "";
            Variant list;
            reply.get("(is@aa{sv})", out code, out text, out list);
            status = code;
            message = text;
            var iter = list.iterator();
            Variant? group;
            while ((group = iter.next_value()) != null)
                groups.add(new IppGroup(group));
        }

        public Gee.List<IppGroup> groups_of(string name) {
            var list = new Gee.ArrayList<IppGroup>();
            foreach (var g in groups) if (g.name == name) list.add(g);
            return list;
        }

        public IppGroup? first(string name) {
            foreach (var g in groups) if (g.name == name) return g;
            return null;
        }

        public void check() throws PrintError {
            if (ok) return;
            if (status == 0x0401 || status == 0x0403 || status == 0x0402)
                throw new PrintError.NOT_AUTHORIZED(message != "" ? message : _("Not allowed"));
            if (status == 0x0406)
                throw new PrintError.NOT_FOUND(message != "" ? message : _("Not found"));
            if (status == 0x0501 || status == 0x0508)
                throw new PrintError.UNSUPPORTED(message != "" ? message : _("Not supported by this print service"));
            throw new PrintError.FAILED(message != "" ? message : _("The print service reported an error"));
        }
    }

    /**
     * One attribute group with typed accessors that accept both single
     * and multiple values.
     */
    public class IppGroup : Object {
        public string name { get; private set; default = ""; }
        private VariantDict dict;
        private Variant source;

        internal IppGroup(Variant value) {
            source = value;
            dict = new VariantDict(value);
            var g = dict.lookup_value("@group", VariantType.STRING);
            if (g != null) name = g.get_string();
        }

        public IppGroup.from_dict(Variant value) {
            this(value);
        }

        public bool has(string key) {
            return dict.contains(key);
        }

        public Variant? raw(string key) {
            return dict.lookup_value(key, null);
        }

        public string? str(string key) {
            var v = dict.lookup_value(key, null);
            if (v == null) return null;
            if (v.is_of_type(VariantType.STRING)) return v.get_string();
            if (v.is_of_type(VariantType.STRING_ARRAY) && v.n_children() > 0)
                return v.get_child_value(0).get_string();
            if (v.is_of_type(VariantType.INT32)) return v.get_int32().to_string();
            return null;
        }

        public string[] strs(string key) {
            var v = dict.lookup_value(key, null);
            string[] list = {};
            if (v == null) return list;
            if (v.is_of_type(VariantType.STRING)) {
                list += v.get_string();
            } else if (v.is_of_type(VariantType.STRING_ARRAY)) {
                foreach (var s in v.get_strv()) list += s;
            } else if (v.is_of_type(VariantType.INT32)) {
                list += v.get_int32().to_string();
            } else if (v.is_of_type(new VariantType("ai"))) {
                for (size_t i = 0; i < v.n_children(); i++)
                    list += v.get_child_value(i).get_int32().to_string();
            }
            return list;
        }

        public int integer(string key, int fallback = 0) {
            var v = dict.lookup_value(key, null);
            if (v == null) return fallback;
            if (v.is_of_type(VariantType.INT32)) return v.get_int32();
            if (v.is_of_type(new VariantType("ai")) && v.n_children() > 0)
                return v.get_child_value(0).get_int32();
            if (v.is_of_type(VariantType.BOOLEAN)) return v.get_boolean() ? 1 : 0;
            return fallback;
        }

        public int[] ints(string key) {
            var v = dict.lookup_value(key, null);
            int[] list = {};
            if (v == null) return list;
            if (v.is_of_type(VariantType.INT32)) {
                list += v.get_int32();
            } else if (v.is_of_type(new VariantType("ai"))) {
                for (size_t i = 0; i < v.n_children(); i++)
                    list += v.get_child_value(i).get_int32();
            }
            return list;
        }

        public bool boolean(string key, bool fallback = false) {
            var v = dict.lookup_value(key, null);
            if (v == null) return fallback;
            if (v.is_of_type(VariantType.BOOLEAN)) return v.get_boolean();
            if (v.is_of_type(VariantType.INT32)) return v.get_int32() != 0;
            return fallback;
        }

        public int64 time(string key) {
            var v = dict.lookup_value(key, null);
            if (v == null) return 0;
            if (v.is_of_type(VariantType.INT64)) return v.get_int64();
            if (v.is_of_type(VariantType.INT32)) return v.get_int32();
            return 0;
        }

        public Gee.List<IppGroup> collections(string key) {
            var list = new Gee.ArrayList<IppGroup>();
            var v = dict.lookup_value(key, null);
            if (v == null) return list;
            if (v.is_of_type(VariantType.VARDICT)) {
                list.add(new IppGroup(v));
            } else if (v.is_of_type(new VariantType("aa{sv}"))) {
                for (size_t i = 0; i < v.n_children(); i++)
                    list.add(new IppGroup(v.get_child_value(i)));
            } else if (v.is_of_type(new VariantType("av"))) {
                for (size_t i = 0; i < v.n_children(); i++) {
                    var inner = v.get_child_value(i).get_variant();
                    if (inner.is_of_type(VariantType.VARDICT)) list.add(new IppGroup(inner));
                }
            }
            return list;
        }

        public string[] keys() {
            string[] list = {};
            var iter = source.iterator();
            string key;
            Variant val;
            while (iter.next("{sv}", out key, out val)) if (key != "@group") list += key;
            return list;
        }
    }
}
