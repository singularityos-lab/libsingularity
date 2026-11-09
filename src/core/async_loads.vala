namespace Singularity.Async {

    [CCode (cname = "singularity_async_load", finish_name = "singularity_async_load_finish", cheader_filename = "core/async_engine.h")]
    private extern async Bytes file_load(File file, int qos, Cancellable? cancellable) throws Error;

    [CCode (cname = "singularity_async_native_io", cheader_filename = "core/async_engine.h")]
    private extern bool native_io();

    /**
     * Whether local files are read through io_uring on the SIT engine.
     */
    public bool accelerated_io() {
        return native_io();
    }

    /**
     * Reads a whole file off the main thread. Background reads use the idle
     * disk class.
     */
    public async Bytes load_bytes(File file, Qos qos = Qos.USER, Cancellable? cancellable = null) throws Error {
        return yield file_load(file, (int) qos, cancellable);
    }

    /**
     * Reads and decodes an image at full size off the main thread.
     */
    public async Gdk.Texture load_texture(File file, Qos qos = Qos.USER, Cancellable? cancellable = null) throws Error {
        var bytes = yield load_bytes(file, qos, cancellable);
        return yield run<Gdk.Texture>((c) => Gdk.Texture.from_bytes(bytes), qos, cancellable);
    }

    /**
     * Reads and decodes an image off the main thread, scaled down so its
     * longer side is at most `pixels`. Smaller images keep their size, and
     * the orientation stored in the file is applied.
     */
    public async Gdk.Texture load_image(File file, int pixels, Qos qos = Qos.USER, Cancellable? cancellable = null) throws Error {
        var bytes = yield load_bytes(file, qos, cancellable);
        return yield run<Gdk.Texture>((c) => texture_of(decode(bytes, pixels, c)), qos, cancellable);
    }

    internal Gdk.Pixbuf decode(Bytes bytes, int pixels, Cancellable? cancellable) throws Error {
        var loader = new Gdk.PixbufLoader();
        loader.size_prepared.connect((width, height) => {
            int longest = int.max(width, height);
            if (pixels <= 0 || longest <= pixels) return;
            double factor = (double) pixels / longest;
            loader.set_size(int.max(1, (int) Math.round(width * factor)), int.max(1, (int) Math.round(height * factor)));
        });
        try {
            loader.write_bytes(bytes);
            loader.close();
        } catch (Error e) {
            try {
                loader.close();
            } catch (Error ignored) {
            }
            throw e;
        }
        if (cancellable != null) cancellable.set_error_if_cancelled();
        var pixbuf = loader.get_pixbuf();
        if (pixbuf == null) throw new IOError.INVALID_DATA("The image could not be decoded");
        return pixbuf.apply_embedded_orientation() ?? pixbuf;
    }

    internal Gdk.Texture texture_of(Gdk.Pixbuf pixbuf) {
        var format = pixbuf.has_alpha ? Gdk.MemoryFormat.R8G8B8A8 : Gdk.MemoryFormat.R8G8B8;
        return new Gdk.MemoryTexture(pixbuf.width, pixbuf.height, format, pixbuf.read_pixel_bytes(), pixbuf.rowstride);
    }

    /**
     * Thumbnails of images and videos, made off the main thread.
     *
     * Thumbnails come from the freedesktop.org cache when it holds a valid
     * one, and are made and written back to it otherwise; the write runs at
     * background priority after the thumbnail is returned. Requests for the
     * same file and size share one piece of work, and finished thumbnails
     * stay in memory up to `max_items`.
     */
    public class Thumbnails : Object {

        private class Entry {
            public Gdk.Texture? texture;
            public uint64 used;
        }

        private class Made {
            public Gdk.Texture? texture;
            public Gdk.Pixbuf? to_save;
            public string uri;
            public int64 mtime;
            public string? mime;
            public FileSystem.ThumbnailCache.Size size;
        }

        private class Pending : Object {
            public Cancellable cancellable = new Cancellable();
            public int waiters;
            public bool finished;
            public Gdk.Texture? texture;
            public Error? error;

            public signal void done();
        }

        private static Thumbnails? instance;

        private HashTable<string, Entry> entries = new HashTable<string, Entry>(str_hash, str_equal);
        private HashTable<string, Pending> pending = new HashTable<string, Pending>(str_hash, str_equal);
        private uint64 clock;

        /** The name failures are recorded under in the thumbnail cache. */
        public string failure_app { get; construct; }

        /** How many thumbnails stay in memory. */
        public int max_items { get; set; default = 512; }

        /** How many thumbnails are being made right now. */
        public int in_flight {
            get {
                return (int) pending.size();
            }
        }

        /** Thumbnails written to the cache since this object was made. */
        public int saved { get; private set; default = 0; }

        public Thumbnails(string failure_app = "singularity") {
            Object(failure_app: failure_app);
        }

        /** The thumbnails shared by the whole application. */
        public static unowned Thumbnails shared() {
            if (instance == null) instance = new Thumbnails();
            return instance;
        }

        private static string key_for(File file, int pixels) {
            return "%s\n%d".printf(file.get_uri(), (int) FileSystem.ThumbnailCache.Size.for_pixels(pixels));
        }

        /**
         * The thumbnail already in memory, without starting any work.
         */
        public Gdk.Texture? peek(File file, int pixels) {
            var entry = entries[key_for(file, pixels)];
            if (entry == null) return null;
            entry.used = ++clock;
            return entry.texture;
        }

        /**
         * Drops the thumbnails of `file` from memory, for example after it
         * changed.
         */
        public void forget(File file) {
            string prefix = file.get_uri() + "\n";
            entries.foreach_remove((key, entry) => key.has_prefix(prefix));
        }

        /**
         * Returns a thumbnail of `file` whose longer side is the smallest
         * cache size holding `pixels`, or the image size when the image is
         * smaller, or null when the file has no thumbnail.
         */
        public async Gdk.Texture? load(File file, int pixels, Qos qos = Qos.UTILITY, Cancellable? cancellable = null) throws Error {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            string key = key_for(file, pixels);
            var entry = entries[key];
            if (entry != null) {
                entry.used = ++clock;
                return entry.texture;
            }

            var job = pending[key];
            if (job == null) {
                job = new Pending();
                pending[key] = job;
                make.begin(job, key, file, pixels, qos);
            }
            job.waiters++;

            bool resumed = false;
            SourceFunc resume = load.callback;
            ulong done_id = job.done.connect(() => {
                if (resumed) return;
                resumed = true;
                Idle.add((owned) resume);
            });
            ulong cancel_id = 0;
            if (cancellable != null) {
                cancel_id = cancellable.connect(() => {
                    Idle.add(() => {
                        if (!resumed) {
                            resumed = true;
                            load.callback();
                        }
                        return Source.REMOVE;
                    });
                });
            }
            yield;

            job.disconnect(done_id);
            if (cancellable != null) cancellable.disconnect(cancel_id);
            job.waiters--;
            if (!job.finished) {
                if (job.waiters == 0) job.cancellable.cancel();
                throw new IOError.CANCELLED("Operation was cancelled");
            }
            if (job.error != null) throw job.error;
            return job.texture;
        }

        private async void make(Pending job, string key, File file, int pixels, Qos qos) {
            string app = failure_app;
            Made? made = null;
            try {
                made = yield run<Made>((c) => produce(file, pixels, app, c), qos, job.cancellable);
                job.texture = made.texture;
            } catch (Error e) {
                job.error = e;
            }
            job.finished = true;
            pending.remove(key);
            if (job.error == null) remember(key, job.texture);
            job.done();
            if (made != null && made.to_save != null) save.begin(made);
        }

        private async void save(Made made) {
            try {
                bool ok = yield run<bool>((c) => {
                    FileSystem.ThumbnailCache.Size[] sizes = { FileSystem.ThumbnailCache.Size.NORMAL, FileSystem.ThumbnailCache.Size.LARGE };
                    if (made.size >= FileSystem.ThumbnailCache.Size.X_LARGE) sizes += FileSystem.ThumbnailCache.Size.X_LARGE;
                    if (made.size >= FileSystem.ThumbnailCache.Size.XX_LARGE) sizes += FileSystem.ThumbnailCache.Size.XX_LARGE;
                    return FileSystem.ThumbnailCache.save(made.to_save, made.uri, made.mtime, made.mime, sizes);
                }, Qos.BACKGROUND);
                if (ok) saved++;
            } catch (Error e) {
            }
        }

        private void remember(string key, Gdk.Texture? texture) {
            var entry = new Entry();
            entry.texture = texture;
            entry.used = ++clock;
            entries[key] = entry;
            if (entries.size() <= max_items) return;
            string? oldest = null;
            uint64 oldest_used = uint64.MAX;
            entries.foreach((k, e) => {
                if (e.used < oldest_used) {
                    oldest_used = e.used;
                    oldest = k;
                }
            });
            if (oldest != null) entries.remove(oldest);
        }

        private static Made produce(File file, int pixels, string app, Cancellable? cancellable) throws Error {
            var made = new Made();
            var info = file.query_info(FileAttribute.STANDARD_CONTENT_TYPE + "," + FileAttribute.TIME_MODIFIED,
                                       FileQueryInfoFlags.NONE, cancellable);
            made.uri = file.get_uri();
            made.mtime = (int64) info.get_attribute_uint64(FileAttribute.TIME_MODIFIED);
            string? type = info.get_content_type();
            made.mime = type != null ? ContentType.get_mime_type(type) : null;
            made.size = FileSystem.ThumbnailCache.Size.for_pixels(pixels);

            var cached = FileSystem.ThumbnailCache.load(made.uri, made.mtime, pixels);
            if (cached != null) {
                made.texture = texture_of(FileSystem.ThumbnailCache.scale_to(cached, (int) made.size));
                return made;
            }
            if (made.mime == null) return made;

            if (made.mime.has_prefix("video/")) {
                var frame = FileSystem.VideoThumbnailer.thumbnail(made.uri, made.mtime, pixels, made.mime);
                if (frame != null) made.texture = texture_of(FileSystem.ThumbnailCache.scale_to(frame, (int) made.size));
                return made;
            }

            string? path = file.get_path();
            if (!made.mime.has_prefix("image/")) return made;
            if (path != null && path.has_prefix(FileSystem.ThumbnailCache.root() + "/")) return made;
            if (FileSystem.ThumbnailCache.has_failed(app, made.uri, made.mtime)) return made;

            Gdk.Pixbuf image;
            try {
                image = decode(file.load_bytes(cancellable, null), (int) made.size, cancellable);
            } catch (Error e) {
                if (e is IOError.CANCELLED) throw e;
                FileSystem.ThumbnailCache.save_failure(app, made.uri, made.mtime);
                return made;
            }
            made.to_save = image;
            made.texture = texture_of(FileSystem.ThumbnailCache.scale_to(image, (int) made.size));
            return made;
        }
    }
}
