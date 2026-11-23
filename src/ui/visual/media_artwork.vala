using Gtk;

namespace Singularity.Widgets {

    public class MediaArtwork : Widget {
        private Image _cover;
        private Image _badge;
        private int _size = 48;
        private int _badge_size = 20;

        public int size {
            get { return _size; }
            set {
                _size = value;
                _cover.pixel_size = value;
                _cover.set_size_request(value, value);
            }
        }

        public int badge_size {
            get { return _badge_size; }
            set {
                _badge_size = value;
                _badge.pixel_size = value;
            }
        }

        public Gdk.Paintable? cover {
            set {
                if (value != null) {
                    _cover.paintable = value;
                    _cover.remove_css_class("placeholder");
                } else {
                    _cover.icon_name = "audio-x-generic";
                    _cover.add_css_class("placeholder");
                }
            }
        }

        public GLib.Icon? app_icon {
            set {
                _badge.visible = value != null;
                if (value != null) _badge.gicon = value;
            }
        }

        static construct {
            set_layout_manager_type(typeof(BinLayout));
            set_css_name("media-artwork");
        }

        public MediaArtwork(int size = 48, int badge_size = 20) {
            _cover = new Image();
            _cover.add_css_class("media-artwork-cover");
            _cover.overflow = Overflow.HIDDEN;
            _cover.halign = Align.CENTER;
            _cover.valign = Align.CENTER;
            _cover.set_parent(this);
            _badge = new Image();
            _badge.add_css_class("media-artwork-badge");
            _badge.halign = Align.END;
            _badge.valign = Align.END;
            _badge.can_target = false;
            _badge.visible = false;
            _badge.set_parent(this);
            this.size = size;
            this.badge_size = badge_size;
            cover = null;
        }

        public void set_app(string app_id) {
            string id = app_id.has_suffix(".desktop") ? app_id : app_id + ".desktop";
            var info = app_id != "" ? new GLib.DesktopAppInfo(id) : null;
            app_icon = info != null ? info.get_icon() : null;
        }

        public override void dispose() {
            if (_cover != null) {
                _cover.unparent();
                _cover = null;
            }
            if (_badge != null) {
                _badge.unparent();
                _badge = null;
            }
            base.dispose();
        }
    }
}
