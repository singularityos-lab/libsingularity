using Gtk;

namespace Singularity.Widgets {

    /**
     * Shows a MediaPlayback with compact bubble controls.
     *
     * Video streams fill the view. Audio streams show the embedded cover
     * art, or `fallback_icon` when there is none, with the title and the
     * artist below it. The control row holds play and pause, the elapsed
     * time, a scrubber, the duration and a mute toggle.
     *
     * Usage:
     * {{{
     *   var view = new Singularity.Widgets.MediaView();
     *   view.playback.muted = true;
     *   view.playback.open(file.get_uri());
     * }}}
     */
    public class MediaView : Box {
        /** The playback shown by the view. */
        public MediaPlayback playback { get; construct; }

        /** Icon drawn for audio without cover art. */
        public GLib.Icon? fallback_icon {
            get { return _fallback_icon; }
            set {
                _fallback_icon = value;
                update_audio();
            }
        }

        private GLib.Icon? _fallback_icon = null;
        private Stack stage;
        private Picture video_picture;
        private Image cover_picture;
        private Image cover_icon;
        private Label title_label;
        private Label artist_label;
        private Button play_button;
        private Button mute_button;
        private Scale scrubber;
        private Label elapsed_label;
        private Label duration_label;
        private bool scrubbing = false;

        private static bool css_installed = false;

        /**
         * @param playback The playback to show, or null to create one.
         */
        public MediaView(MediaPlayback? playback = null) {
            Object(orientation: Orientation.VERTICAL, spacing: 10,
                   playback: playback ?? new MediaPlayback());
        }

        construct {
            install_css();
            add_css_class("media-view");

            stage = new Stack();
            stage.hexpand = true;
            stage.vexpand = true;
            stage.transition_type = StackTransitionType.NONE;

            video_picture = new Picture();
            video_picture.paintable = playback.video;
            video_picture.content_fit = ContentFit.CONTAIN;
            video_picture.can_shrink = true;
            video_picture.add_css_class("media-view-video");
            stage.add_named(video_picture, "video");

            var audio = new Box(Orientation.VERTICAL, 12);
            audio.valign = Align.CENTER;
            audio.halign = Align.CENTER;
            cover_picture = new Image();
            cover_picture.pixel_size = 240;
            cover_picture.halign = Align.CENTER;
            cover_picture.overflow = Overflow.HIDDEN;
            cover_picture.add_css_class("media-view-cover");
            cover_icon = new Image();
            cover_icon.pixel_size = 128;
            title_label = new Label("");
            title_label.add_css_class("media-view-title");
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.max_width_chars = 36;
            artist_label = new Label("");
            artist_label.add_css_class("dim-label");
            artist_label.ellipsize = Pango.EllipsizeMode.END;
            artist_label.max_width_chars = 36;
            audio.append(cover_picture);
            audio.append(cover_icon);
            audio.append(title_label);
            audio.append(artist_label);
            stage.add_named(audio, "audio");
            append(stage);

            var controls = new Box(Orientation.HORIZONTAL, 8);
            controls.add_css_class("media-view-controls");
            play_button = new Button.from_icon_name("media-playback-start-symbolic");
            play_button.valign = Align.CENTER;
            play_button.clicked.connect(() => playback.toggle());
            elapsed_label = new Label("0:00");
            elapsed_label.add_css_class("media-view-time");
            scrubber = new Scale.with_range(Orientation.HORIZONTAL, 0.0, 1.0, 0.001);
            scrubber.draw_value = false;
            scrubber.hexpand = true;
            scrubber.valign = Align.CENTER;
            scrubber.change_value.connect((scroll, value) => {
                scrubbing = true;
                playback.seek_fraction(value);
                scrubbing = false;
                return false;
            });
            duration_label = new Label("0:00");
            duration_label.add_css_class("media-view-time");
            mute_button = new Button.from_icon_name("audio-volume-high-symbolic");
            mute_button.valign = Align.CENTER;
            mute_button.clicked.connect(() => playback.muted = !playback.muted);
            controls.append(play_button);
            controls.append(elapsed_label);
            controls.append(scrubber);
            controls.append(duration_label);
            controls.append(mute_button);
            append(controls);

            playback.notify["playing"].connect(update_buttons);
            playback.notify["muted"].connect(update_buttons);
            playback.notify["position"].connect(update_progress);
            playback.notify["duration"].connect(update_progress);
            playback.notify["has-video"].connect(update_stage);
            playback.notify["ready"].connect(update_stage);
            playback.notify["cover"].connect(update_audio);
            playback.notify["title"].connect(update_audio);
            playback.notify["artist"].connect(update_audio);
            playback.video.first_frame.connect(update_stage);
            update_buttons();
            update_progress();
            update_stage();
            update_audio();
        }

        private void update_buttons() {
            play_button.icon_name = playback.playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
            play_button.tooltip_text = playback.playing ? _("Pause") : _("Play");
            mute_button.icon_name = playback.muted ? "audio-volume-muted-symbolic" : "audio-volume-high-symbolic";
            mute_button.tooltip_text = playback.muted ? _("Unmute") : _("Mute");
        }

        private void update_progress() {
            elapsed_label.label = MediaPlayback.format_time(playback.position);
            duration_label.label = MediaPlayback.format_time(playback.duration);
            scrubber.sensitive = playback.duration > 0;
            if (scrubbing || playback.duration <= 0) return;
            scrubber.set_value((double) playback.position / playback.duration);
        }

        private void update_stage() {
            bool video = playback.has_video || playback.video.has_frame;
            if (!video && !playback.ready) return;
            stage.visible_child_name = video ? "video" : "audio";
        }

        private void update_audio() {
            cover_picture.paintable = playback.cover;
            cover_picture.visible = playback.cover != null;
            cover_icon.gicon = _fallback_icon ?? new ThemedIcon("audio-x-generic");
            cover_icon.visible = playback.cover == null;
            string? name = playback.title;
            if (name == null && playback.uri != null) {
                name = Filename.display_basename(File.new_for_uri(playback.uri).get_basename() ?? "");
            }
            title_label.label = name ?? "";
            title_label.visible = name != null && name != "";
            string artist = playback.artist ?? "";
            if (playback.album != null && playback.album != "") {
                artist = artist == "" ? playback.album : "%s, %s".printf(artist, playback.album);
            }
            artist_label.label = artist;
            artist_label.visible = artist != "";
        }

        private static void install_css() {
            if (css_installed) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            css_installed = true;
            var provider = new CssProvider();
            provider.load_from_string("""
                .media-view-controls { padding: 0 2px; }
                .media-view-time { font-size: 12px; font-feature-settings: "tnum"; opacity: 0.7; min-width: 34px; }
                .media-view-cover { border-radius: 12px; }
                .media-view-title { font-weight: 600; }
            """);
            StyleContext.add_provider_for_display(display, provider, STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }
}
