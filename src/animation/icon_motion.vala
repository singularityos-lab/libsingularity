namespace Singularity.Animation {

    public class IconMotion : Object {
        public const uint DOCK_LIMIT = 500;

        private const string PLAYING = "singularity-icon-motion";
        private const string ANIMATED_KEY = "animated-icons";
        internal const string SOURCE = "singularity-icon-source";

        public static void set_source(Gtk.Image image, GLib.File? file) {
            image.set_data<GLib.File?>(SOURCE, file);
        }

        public static bool play(Gtk.Image image, uint limit_ms = 0, double detail = 1.0, uint delay_ms = 0) {
#if IRIDE
            if (image.get_data<IconPlayback>(PLAYING) != null) return true;
            if (!image.get_mapped() || !allowed()) return false;
            var playback = IconPlayback.open(image, limit_ms, detail);
            if (playback == null) return false;
            image.set_data<IconPlayback>(PLAYING, playback);
            playback.delay = delay_ms;
            playback.done.connect(forget);
            playback.start();
            return true;
#else
            return false;
#endif
        }

        public static bool animated(Gtk.Image image) {
#if IRIDE
            if (!animated_icons_enabled()) return false;
            int size = image.pixel_size > 0 ? image.pixel_size : int.min(image.get_width(), image.get_height());
            return size > 0 && IconPlayback.sibling_of(image, size, image.get_scale_factor()) != null;
#else
            return false;
#endif
        }

        public static void stop(Gtk.Image image) {
#if IRIDE
            var playback = image.get_data<IconPlayback>(PLAYING);
            if (playback != null) playback.skip();
#endif
        }

        public static void play_when_shown(Gtk.Image image) {
#if IRIDE
            image.map.connect(on_shown);
            image.unmap.connect(on_hidden);
            if (image.get_mapped()) on_shown(image);
#endif
        }

#if IRIDE
        private static void on_shown(Gtk.Widget widget) {
            widget.add_tick_callback((shown, clock) => {
                if (shown.get_mapped()) play((Gtk.Image) shown);
                return Source.REMOVE;
            });
        }

        private static void on_hidden(Gtk.Widget widget) {
            stop((Gtk.Image) widget);
        }

        private static void forget(Playable playable) {
            var playback = (IconPlayback) playable;
            playback.image.set_data<IconPlayback?>(PLAYING, null);
        }

        private static bool allowed() {
            if (Singularity.Motion.reduced()) return false;
            if (!animated_icons_enabled()) return false;
            return !GLib.PowerProfileMonitor.dup_default().power_saver_enabled;
        }
#endif

        private static GLib.Settings? _animated_settings = null;

        public static bool animated_icons_enabled() {
            if (_animated_settings == null) {
                var source = GLib.SettingsSchemaSource.get_default();
                string schema_id = Singularity.Runtime.desktop_settings_schema;
                var schema = source != null ? source.lookup(schema_id, true) : null;
                if (schema != null && schema.has_key(ANIMATED_KEY)) {
                    _animated_settings = new GLib.Settings(schema_id);
                }
            }
            return _animated_settings == null || _animated_settings.get_boolean(ANIMATED_KEY);
        }
    }

#if IRIDE
    private class IconFrame : Object, Gdk.Paintable {
        private Gdk.Texture? texture;
        private int side;

        public IconFrame(int side) {
            this.side = side;
        }

        public void show(Gdk.Texture texture) {
            this.texture = texture;
            invalidate_contents();
        }

        public int get_intrinsic_width() {
            return side;
        }

        public int get_intrinsic_height() {
            return side;
        }

        public double get_intrinsic_aspect_ratio() {
            return 1.0;
        }

        public void snapshot(Gdk.Snapshot snapshot, double width, double height) {
            if (texture != null) texture.snapshot(snapshot, width, height);
        }
    }

    private class IconPlayback : Animation {
        private const uint32 LARGEST = 256;

        public Gtk.Image image { get { return (Gtk.Image) widget; } }

        private Bytes file;
        private Bytes? white;
        private uint8[] work;
        private uint8[]? white_work;
        private uint8[] pixels;
        private uint8[]? white_pixels;
        private uint32 accent;
        private uint32 wanted;
        private uint32 side;
        private double speed = 1.0;
        private IconFrame shown;
        private string? icon_name;
        private GLib.Icon? gicon;
        private Gdk.Paintable? paintable;

        private IconPlayback(Gtk.Image image) {
            base(image);
        }

        public static IconPlayback? open(Gtk.Image image, uint limit_ms, double detail) {
            int size = image.pixel_size > 0 ? image.pixel_size : int.min(image.get_width(), image.get_height());
            if (size <= 0) return null;
            int scale = image.get_scale_factor();
            uint32 device = (uint32) (size * scale);
            if (device > LARGEST) return null;
            string? path = sibling_of(image, size, scale);
            if (path == null) return null;

            Bytes file;
            try {
                file = new MappedFile(path, false).get_bytes();
            } catch (FileError e) {
                return null;
            }
            if (file.get_size() == 0) return null;

            var self = new IconPlayback(image);
            self.accent = global::Iride.NO_ACCENT;
            bool dark = false;
            string? hex = null;
            var gs = image.get_settings();
            if (gs.get_class().find_property("gtk-icon-accent") != null) {
                gs.get("gtk-icon-dark", out dark, "gtk-icon-accent", out hex);
                var color = Gdk.RGBA();
                if (hex != null && hex != "" && color.parse(hex)) {
                    self.accent = ((uint32) Math.round(color.red * 255) << 16)
                        | ((uint32) Math.round(color.green * 255) << 8)
                        | (uint32) Math.round(color.blue * 255);
                }
            }
            unowned uint8[] black;
            unowned uint8[]? white;
            if (global::Iride.look(file.get_data(), dark ? global::Iride.Scheme.DARK : global::Iride.Scheme.LIGHT,
                    self.accent != global::Iride.NO_ACCENT, out black, out white) != 0) return null;
            size_t start = (size_t) ((uint8*) black - (uint8*) file.get_data());
            self.file = new Bytes.from_bytes(file, start, black.length);
            if (white != null) {
                self.white = new Bytes.from_bytes(file, (size_t) ((uint8*) white - (uint8*) file.get_data()), white.length);
            }
            self.wanted = uint32.min((uint32) Math.ceil(device * detail), LARGEST);
            uint32 duration;
            size_t room;
            if (global::Iride.motion(self.file.get_data(), self.wanted, out duration, out self.side, out room) != 0) return null;
            self.work = new uint8[room];
            if (global::Iride.prepare(self.file.get_data(), self.wanted, self.work) != 0) return null;
            self.pixels = new uint8[self.side * self.side * 4];
            if (self.white != null) {
                uint32 white_duration, white_side;
                size_t white_room;
                if (global::Iride.motion(self.white.get_data(), self.wanted, out white_duration, out white_side, out white_room) != 0
                        || white_side != self.side) return null;
                self.white_work = new uint8[white_room];
                if (global::Iride.prepare(self.white.get_data(), self.wanted, self.white_work) != 0) return null;
                self.white_pixels = new uint8[self.pixels.length];
            }
            if (limit_ms > 0 && duration > limit_ms) self.speed = (double) duration / limit_ms;
            self.shown = new IconFrame(size);
            if (!self.draw(0)) return null;
            return self;
        }

        internal static string? sibling_of(Gtk.Image image, int size, int scale) {
            var theme = Gtk.IconTheme.get_for_display(image.get_display());
            var direction = image.get_direction();
            Gtk.IconPaintable? found = null;
            switch (image.storage_type) {
                case Gtk.ImageType.ICON_NAME:
                    if (image.icon_name == null) return null;
                    found = theme.lookup_icon(image.icon_name, null, size, scale, direction, 0);
                    break;
                case Gtk.ImageType.GICON:
                    if (image.gicon == null) return null;
                    found = theme.lookup_by_gicon(image.gicon, size, scale, direction, 0);
                    break;
                case Gtk.ImageType.PAINTABLE:
                    found = image.paintable as Gtk.IconPaintable;
                    break;
                default:
                    return null;
            }
            var file = found != null ? found.get_file() : image.get_data<GLib.File>(IconMotion.SOURCE);
            string? path = file != null ? file.get_path() : null;
            if (path == null || !path.has_suffix(".svg") || path.has_suffix("-symbolic.svg")) return null;
            string sibling = path.substring(0, path.length - ".svg".length) + ".iride";
            return FileUtils.test(sibling, FileTest.IS_REGULAR) ? sibling : null;
        }

        private bool draw(double msec) {
            if (global::Iride.frame(file.get_data(), wanted, msec, work, pixels) != 0) return false;
            if (white != null) {
                if (global::Iride.frame(white.get_data(), wanted, msec, white_work, white_pixels) != 0) return false;
                if (global::Iride.tint(pixels, white_pixels, accent, pixels) != 0) return false;
            }
            shown.show(new Gdk.MemoryTexture((int) side, (int) side, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED,
                new Bytes(pixels), side * 4));
            return true;
        }

        public void start() {
            switch (image.storage_type) {
                case Gtk.ImageType.ICON_NAME:
                    icon_name = image.icon_name;
                    break;
                case Gtk.ImageType.GICON:
                    gicon = image.gicon;
                    break;
                default:
                    paintable = image.paintable;
                    break;
            }
            image.set_from_paintable(shown);
            play();
        }

        private void restore() {
            if (image.paintable != shown) return;
            if (icon_name != null) image.icon_name = icon_name;
            else if (gicon != null) image.set_from_gicon(gicon);
            else image.set_from_paintable(paintable);
        }

        protected override bool on_update(double elapsed_ms) {
            if (image.paintable == shown && draw(elapsed_ms * speed)) return true;
            restore();
            return false;
        }

        protected override void on_finish() {
            restore();
        }
    }
#endif
}
