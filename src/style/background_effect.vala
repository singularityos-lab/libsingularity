namespace Singularity.Style {

    public enum BackgroundEffectMode {
        DISABLED,
        GLASS,
        BLUR;

        public static BackgroundEffectMode from_token(string token) {
            switch (token) {
                case "glass": return GLASS;
                case "blur": return BLUR;
                default: return DISABLED;
            }
        }

        public string to_token() {
            switch (this) {
                case GLASS: return "glass";
                case BLUR: return "blur";
                default: return "disabled";
            }
        }
    }

    [CCode (cname = "singularity_surface_effect_set", cheader_filename = "wayland/surface_effect.h")]
    private extern void set_native_surface_effect(Gtk.Widget widget, uint32 mode,
                                                   int x, int y, int width, int height,
                                                   uint32 strength);

    public class BackgroundEffect : Object {

        private static GLib.Settings? cached_settings;

        public static BackgroundEffectMode read(GLib.Settings? settings) {
            if (settings == null || !settings.settings_schema.has_key("background-effect")) {
                return BackgroundEffectMode.DISABLED;
            }
            return BackgroundEffectMode.from_token(settings.get_string("background-effect"));
        }

        public static int read_strength(GLib.Settings? settings = null) {
            var source = settings;
            if (source == null) {
                if (cached_settings == null) {
                    cached_settings = Singularity.Core.safe_settings(
                        Singularity.Runtime.desktop_settings_schema);
                }
                source = cached_settings;
            }
            if (source == null || !source.settings_schema.has_key("blur-strength")) {
                return 60;
            }
            return source.get_int("blur-strength").clamp(0, 100);
        }

        public static void apply(Gtk.Widget widget, BackgroundEffectMode mode,
                                 int x = 0, int y = 0, int width = 0, int height = 0) {
            if (mode != BackgroundEffectMode.GLASS) widget.remove_css_class("singularity-glass");
            if (mode != BackgroundEffectMode.BLUR) widget.remove_css_class("singularity-blur");
            if (mode == BackgroundEffectMode.GLASS) {
                widget.add_css_class("singularity-glass");
            } else if (mode == BackgroundEffectMode.BLUR) {
                widget.add_css_class("singularity-blur");
            }
            if (widget.get_mapped()) {
                set_native_surface_effect(widget, (uint32) mode,
                    x, y, width, height, (uint32) read_strength());
            }
        }
    }
}
