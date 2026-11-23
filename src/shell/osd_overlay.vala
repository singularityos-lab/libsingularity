using Gtk;
using GLib;
using GtkLayerShell;

namespace Singularity.Shell {

    /**
     * Top-centre pill OSD overlay for transient system feedback.
     *
     * Used for volume, brightness, keyboard backlight, and caps/num-lock notifications.
     * Positions itself at the top-centre of the primary monitor via GTK Layer Shell
     * and auto-hides after a short timeout.
     *
     * Obtain the shared instance via `get_default()`.
     */
    public class OsdOverlay : Gtk.Window {
        private static OsdOverlay? _instance = null;
        private Image icon_widget;
        private ProgressBar bar;
        private Label label_widget;
        private Box _message;
        private Box _level;
        private Image _level_icon;
        private Label _level_title;
        private Label _level_value;
        private Label _level_note;
        private ProgressBar _level_bar;
        private Box _media;
        private Singularity.Widgets.MediaArtwork _artwork;
        private Label _media_title;
        private Label _media_artist;
        private Image _media_state;
        private Box _pill;
        private uint hide_timeout = 0;
        private Singularity.Animation.MotionBin motion_bin;
        private bool leaving = false;
        private bool entering = false;

        private const uint OSD_HIDE_DELAY_MS = 1500;
        private const uint MEDIA_HIDE_DELAY_MS = 2500;

        public static OsdOverlay get_default() {
            if (_instance == null) {
                _instance = new OsdOverlay();
                var app = GLib.Application.get_default() as Gtk.Application;
                if (app != null) _instance.set_application(app);
            }
            return _instance;
        }

        public OsdOverlay() {
            Object(
                decorated: false,
                resizable: false,
                deletable: false,
                can_focus: false,
                focusable: false,
                focus_on_click: false
            );
            add_css_class("panel-window");

            var pill = new Box(Orientation.HORIZONTAL, 0);
            pill.add_css_class("osd-pill");
            _pill = pill;
            Singularity.Style.BackgroundEffect.track(this, () => { return new Gtk.Widget[] { pill }; });
            pill.valign = Align.START;
            pill.halign = Align.CENTER;

            _message = new Box(Orientation.HORIZONTAL, 12);
            icon_widget = new Image();
            icon_widget.pixel_size = 24;
            icon_widget.valign = Align.CENTER;
            _message.append(icon_widget);
            var vbox = new Box(Orientation.VERTICAL, 4);
            vbox.valign = Align.CENTER;
            vbox.hexpand = true;
            label_widget = new Label("");
            label_widget.halign = Align.START;
            label_widget.add_css_class("caption");
            vbox.append(label_widget);
            bar = new ProgressBar();
            bar.hexpand = true;
            bar.valign = Align.CENTER;
            vbox.append(bar);
            _message.append(vbox);
            pill.append(_message);

            _level = new Box(Orientation.HORIZONTAL, 14);
            _level.add_css_class("osd-level");
            _level_icon = new Image();
            _level_icon.pixel_size = 40;
            _level_icon.valign = Align.CENTER;
            _level.append(_level_icon);
            var level_text = new Box(Orientation.VERTICAL, 6);
            level_text.valign = Align.CENTER;
            level_text.hexpand = true;
            var level_head = new Box(Orientation.HORIZONTAL, 12);
            _level_title = new Label("");
            _level_title.add_css_class("osd-title");
            _level_title.xalign = 0;
            _level_title.hexpand = true;
            _level_title.ellipsize = Pango.EllipsizeMode.END;
            level_head.append(_level_title);
            _level_value = new Label("");
            _level_value.add_css_class("osd-value");
            _level_value.add_css_class("numeric");
            level_head.append(_level_value);
            level_text.append(level_head);
            _level_bar = new ProgressBar();
            _level_bar.add_css_class("osd-level-bar");
            _level_bar.hexpand = true;
            level_text.append(_level_bar);
            _level_note = new Label("");
            _level_note.add_css_class("caption");
            _level_note.add_css_class("dim-label");
            _level_note.xalign = 0;
            _level_note.wrap = true;
            _level_note.max_width_chars = 32;
            level_text.append(_level_note);
            _level.append(level_text);
            pill.append(_level);

            _media = new Box(Orientation.HORIZONTAL, 14);
            _media.add_css_class("osd-media");
            _artwork = new Singularity.Widgets.MediaArtwork(48, 20);
            _artwork.valign = Align.CENTER;
            _media.append(_artwork);
            var media_text = new Box(Orientation.VERTICAL, 2);
            media_text.valign = Align.CENTER;
            media_text.hexpand = true;
            _media_title = new Label("");
            _media_title.add_css_class("osd-title");
            _media_title.xalign = 0;
            _media_title.ellipsize = Pango.EllipsizeMode.END;
            _media_title.max_width_chars = 26;
            media_text.append(_media_title);
            _media_artist = new Label("");
            _media_artist.add_css_class("dim-label");
            _media_artist.xalign = 0;
            _media_artist.ellipsize = Pango.EllipsizeMode.END;
            _media_artist.max_width_chars = 26;
            media_text.append(_media_artist);
            _media.append(media_text);
            _media_state = new Image();
            _media_state.pixel_size = 20;
            _media_state.valign = Align.CENTER;
            _media_state.add_css_class("osd-media-state");
            _media.append(_media_state);
            pill.append(_media);

            motion_bin = new Singularity.Animation.MotionBin(pill);
            motion_bin.valign = Align.START;
            motion_bin.margin_bottom = (int) Singularity.Motion.SLIDE_DISTANCE;
            set_child(motion_bin);

            map.connect(() => {
                var surface = get_surface();
                if (surface != null) surface.set_input_region(new Cairo.Region());
            });

            try_setup_layer_shell();
        }

        private void show_page(Box page) {
            _message.visible = page == _message;
            _level.visible = page == _level;
            _media.visible = page == _media;
            _pill.remove_css_class("osd-message-pill");
            _pill.remove_css_class("osd-level-pill");
            _pill.remove_css_class("osd-media-pill");
            if (page == _message) _pill.add_css_class("osd-message-pill");
            else if (page == _level) _pill.add_css_class("osd-level-pill");
            else _pill.add_css_class("osd-media-pill");
        }

        protected override void dispose() {
            if (hide_timeout != 0) {
                Source.remove(hide_timeout);
                hide_timeout = 0;
            }
            base.dispose();
        }

        private void try_setup_layer_shell() {
            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, true);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, false);
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, false);
            GtkLayerShell.set_margin(this, GtkLayerShell.Edge.TOP, 16);
            GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
        }

        /**
         * Displays the OSD with the given icon and optional progress value.
         *
         * The overlay is presented immediately and auto-hides after ~1.5 seconds.
         *
         * @param icon_name Symbolic icon name (e.g. `"audio-volume-high-symbolic"`).
         * @param value     Progress value in the range 0-100 for a progress bar,
         *                  or a negative value to show only the icon and label.
         * @param text      Optional label shown below the progress bar.
         */
        public void show_osd(string icon_name, double value, string? text = null) {
            bool was_visible = visible && !leaving && _message.visible;
            show_page(_message);
            icon_widget.icon_name = icon_name;
            bar.visible = value >= 0;
            if (value >= 0) animate_fraction(bar, value / 100.0, was_visible);
            label_widget.label = text ?? "";
            label_widget.visible = text != null && text.length > 0;
            reveal(OSD_HIDE_DELAY_MS);
        }

        public void show_level(string icon_name, double value, string title, string? note = null,
                               bool muted = false, double max = 100.0) {
            bool was_visible = visible && !leaving && _level.visible;
            show_page(_level);
            bool changed_icon = _level_icon.icon_name != icon_name;
            _level_icon.icon_name = icon_name;
            _level_title.label = title;
            _level_value.label = muted ? _("Muted") : "%d%%".printf((int) Math.round(value));
            if (muted) _level.add_css_class("muted");
            else _level.remove_css_class("muted");
            animate_fraction(_level_bar, muted ? 0.0 : value / double.max(1.0, max), was_visible);
            _level_note.label = note ?? "";
            _level_note.visible = note != null && note != "";
            reveal(OSD_HIDE_DELAY_MS);
            if (!entering && (!was_visible || changed_icon)) play_icon();
        }

        private void play_icon() {
            Singularity.Animation.IconMotion.stop(_level_icon);
            Singularity.Animation.IconMotion.play(_level_icon);
        }

        public void show_media(Gdk.Paintable? cover, string app_id, string title, string artist, bool playing) {
            show_page(_media);
            _artwork.cover = cover;
            _artwork.set_app(app_id);
            _media_title.label = title != "" ? title : _("Unknown Title");
            _media_artist.label = artist;
            _media_artist.visible = artist != "";
            _media_state.icon_name = playing ? "media-playback-start-symbolic" : "media-playback-pause-symbolic";
            reveal(MEDIA_HIDE_DELAY_MS);
        }

        private static void animate_fraction(ProgressBar target, double fraction, bool smooth) {
            double f = fraction.clamp(0.0, 1.0);
            if (smooth) {
                Singularity.Motion.spring_to(target, "fraction", f, Singularity.Motion.Spring.SNAPPY);
            } else {
                Singularity.Motion.cancel(target, "fraction");
                target.fraction = f;
            }
        }

        private void reveal(uint delay) {
            bool appearing = !visible || leaving;
            leaving = false;
            present();
            if (appearing) enter();
            if (hide_timeout != 0) {
                Source.remove(hide_timeout);
                hide_timeout = 0;
            }
            hide_timeout = Timeout.add(delay, () => {
                hide_timeout = 0;
                leave();
                return Source.REMOVE;
            });
        }

        private void enter() {
            motion_bin.opacity = 0.0;
            motion_bin.translate_y = Singularity.Motion.reduced() ? 0.0 : Singularity.Motion.SLIDE_DISTANCE;
            Singularity.Motion.tween(motion_bin, "opacity", 1.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            entering = true;
            Singularity.Motion.tween(motion_bin, "translate-y", 0.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER).done.connect(() => {
                entering = false;
                if (_level.visible && !leaving) play_icon();
            });
        }

        private void leave() {
            leaving = true;
            Singularity.Motion.tween(motion_bin, "opacity", 0.0,
                Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.EXIT).done.connect(() => {
                if (!leaving) return;
                leaving = false;
                hide();
                motion_bin.reset_transform();
            });
        }

        ~OsdOverlay() {
        }
    }
}
