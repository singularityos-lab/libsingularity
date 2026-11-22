namespace Singularity {
    public class Compute : Object {
        public delegate uint8[] Producer();

        [CCode (has_target = false)]
        private delegate int RawFn(void* arg, void* out_buf, size_t out_len);
        [CCode (has_target = false)]
        private delegate void* CtxNewFn(size_t budget);
        [CCode (has_target = false)]
        private delegate void CtxFreeFn(void* ctx);
        [CCode (has_target = false)]
        private delegate void ReportFn(void* ctx, void* report);
        [CCode (has_target = false)]
        private delegate int CallFn(void* ctx, uint32 region, void* key, size_t key_len,
                                    void* inputs, size_t n_inputs, void* out_buf, size_t out_len,
                                    RawFn fn, void* arg);

        private class Pending {
            public unowned Producer producer;
            public uint8[]? bytes;
        }

        private static Module? library;
        private static bool probed;
        private static CtxNewFn? ctx_new;
        private static CtxFreeFn? ctx_free;
        private static CallFn? ctx_call;
        private static ReportFn? ctx_report;

        private static Compute? shared_instance;
        private static Mutex shared_lock = Mutex();

        private void* ctx;
        private uint flush_id;

        public Compute(size_t budget = 0) {
            if (load()) ctx = ctx_new(budget);
        }

        ~Compute() {
            if (flush_id != 0) Source.remove(flush_id);
            if (ctx != null) ctx_free(ctx);
        }

        public static Compute shared() {
            typeof(Compute).class_ref();
            shared_lock.lock();
            if (shared_instance == null) shared_instance = new Compute();
            shared_lock.unlock();
            return shared_instance;
        }

        public static Compute for_thread() {
            return shared();
        }

        public static Gdk.Pixbuf load_icon_scaled(string path, int size) throws Error {
            if (path.has_suffix(".svg")) {
                string compiled = path.substring(0, path.length - ".svg".length) + ".iride";
                if (FileUtils.test(compiled, FileTest.IS_REGULAR)) {
                    try {
                        return load_scaled(compiled, size, size, true);
                    } catch (Error e) {
                        debug("%s: %s", compiled, e.message);
                    }
                }
            }
            return load_scaled(path, size, size, true);
        }

        public static Gdk.Pixbuf load_scaled(string path, int width, int height, bool preserve_aspect) throws Error {
            var info = File.new_for_path(path).query_info("time::modified,time::modified-usec,standard::size",
                                                          FileQueryInfoFlags.NONE);
            var id = "%s\n%llu.%u\n%lld\n%dx%d\n%d".printf(path,
                info.get_attribute_uint64("time::modified"), info.get_attribute_uint32("time::modified-usec"),
                info.get_size(), width, height, preserve_aspect ? 1 : 0);
            string? failure = null;
            var packed = for_thread().call(5, key("pixbuf-scaled", id.data), () => {
                try {
                    return pack_pixbuf(new Gdk.Pixbuf.from_file_at_scale(path, width, height, preserve_aspect));
                } catch (Error e) {
                    failure = e.message;
                    return pack_pixbuf(null);
                }
            });
            var pixbuf = unpack_pixbuf(packed);
            if (pixbuf == null) throw new IOError.FAILED(failure ?? "cannot load %s".printf(path));
            return pixbuf;
        }

        public static uint8[] pack_pixbuf(Gdk.Pixbuf? pixbuf) {
            if (pixbuf == null) return new uint8[0];
            var pixels = pixbuf.read_pixel_bytes();
            unowned uint8[] data = pixels.get_data();
            uint32 header[4] = { pixbuf.width, pixbuf.height, pixbuf.rowstride, pixbuf.has_alpha ? 1 : 0 };
            var packed = new uint8[16 + data.length];
            Memory.copy(packed, header, 16);
            Memory.copy(&packed[16], data, data.length);
            return packed;
        }

        public static Gdk.Pixbuf? unpack_pixbuf(uint8[] packed) {
            if (packed.length <= 16) return null;
            uint32 header[4];
            Memory.copy(header, packed, 16);
            return new Gdk.Pixbuf.from_bytes(new Bytes(packed[16:packed.length]), Gdk.Colorspace.RGB,
                                             header[3] != 0, 8, (int) header[0], (int) header[1], (int) header[2]);
        }

        public static bool available() {
            return load();
        }

        private static bool load() {
            if (probed) return library != null;
            probed = true;
            var module = Module.open("libsintycompute.so.0", ModuleFlags.LAZY | ModuleFlags.LOCAL);
            if (module == null) return false;
            void* a = null;
            void* b = null;
            void* c = null;
            void* d = null;
            if (!module.symbol("sinty_compute_ctx_new", out a)
                    || !module.symbol("sinty_compute_ctx_free", out b)
                    || !module.symbol("sinty_compute_call", out c)
                    || !module.symbol("sinty_compute_ctx_report", out d))
                return false;
            ctx_new = (CtxNewFn) a;
            ctx_free = (CtxFreeFn) b;
            ctx_call = (CallFn) c;
            ctx_report = (ReportFn) d;
            library = (owned) module;
            return true;
        }

        public static uint8[] key(string kind, uint8[] data) {
            var sum = new Checksum(ChecksumType.SHA256);
            sum.update(kind.data, kind.length);
            sum.update({ 0 }, 1);
            sum.update(data, data.length);
            uint8[] digest = new uint8[32];
            size_t len = digest.length;
            sum.get_digest(digest, ref len);
            return digest;
        }

        private static int produce_size(void* arg, void* out_buf, size_t out_len) {
            unowned Pending p = (Pending) arg;
            p.bytes = p.producer();
            uint32 n = p.bytes.length;
            Memory.copy(out_buf, &n, sizeof(uint32));
            return 0;
        }

        private static int produce_bytes(void* arg, void* out_buf, size_t out_len) {
            unowned Pending p = (Pending) arg;
            if (p.bytes == null) p.bytes = p.producer();
            if (p.bytes.length != out_len) return -1;
            Memory.copy(out_buf, p.bytes, out_len);
            return 0;
        }

        private void schedule_flush() {
            if (flush_id != 0) return;
            flush_id = Timeout.add_seconds(1, () => {
                flush_id = 0;
                uint64 report[6];
                ctx_report(ctx, report);
                return Source.REMOVE;
            });
        }

        public uint8[] call(uint32 region, uint8[] key, Producer producer) {
            if (ctx == null) return producer();
            bool on_main = MainContext.default().is_owner();
            if (on_main) schedule_flush();
            var pending = new Pending();
            pending.producer = producer;
            uint32 size = 0;
            int r = ctx_call(ctx, region * 2, key, key.length, null, 0, &size, sizeof(uint32),
                             produce_size, pending);
            if (r != 0) return pending.bytes ?? producer();
            uint8[] result = new uint8[size];
            r = ctx_call(ctx, region * 2 + 1, key, key.length, null, 0, result, size,
                         produce_bytes, pending);
            if (r != 0) return pending.bytes ?? producer();
            if (!on_main) {
                uint64 report[6];
                ctx_report(ctx, report);
            }
            return result;
        }
    }
}
