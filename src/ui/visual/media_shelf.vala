using Gtk;

namespace Singularity.Widgets {

    public class MediaArt : Box {
        private Stack _stack;
        private Image _icon;
        private Picture _picture;
        private ProgressBar? _progress = null;
        private Overlay _overlay;

        public MediaArt(int size, string icon_name, bool round = false, int height = -1) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("media-art");
            if (round) add_css_class("round");
            overflow = Overflow.HIDDEN;
            int h = height > 0 ? height : size;
            set_size_request(size, h);
            halign = Align.START;
            valign = Align.START;
            _overlay = new Overlay();
            _overlay.vexpand = true;
            append(_overlay);
            _stack = new Stack();
            _overlay.child = _stack;
            _icon = new Image.from_icon_name(icon_name);
            _icon.pixel_size = int.max(32, int.min(size, h) / 2);
            _stack.add_named(_icon, "icon");
            _picture = new Picture();
            _picture.content_fit = ContentFit.COVER;
            _picture.can_shrink = true;
            _stack.add_named(_picture, "art");
            _stack.visible_child_name = "icon";
        }

        public Image icon {
            get { return _icon; }
        }

        public void set_bare(bool bare) {
            if (bare) add_css_class("bare");
            else remove_css_class("bare");
            int w, h;
            get_size_request(out w, out h);
            int side = int.min(w, h);
            _icon.pixel_size = bare ? side * 3 / 4 : int.max(32, side / 2);
        }

        public Gdk.Paintable? paintable {
            get { return _picture.paintable; }
            set {
                _picture.paintable = value;
                _stack.visible_child_name = value != null ? "art" : "icon";
            }
        }

        public double progress {
            get { return _progress != null && _progress.visible ? _progress.fraction : -1; }
            set {
                if (value < 0) {
                    if (_progress != null) _progress.visible = false;
                    return;
                }
                if (_progress == null) {
                    _progress = new ProgressBar();
                    _progress.add_css_class("media-art-progress");
                    _progress.valign = Align.END;
                    _progress.margin_start = 10;
                    _progress.margin_end = 10;
                    _progress.margin_bottom = 8;
                    _progress.can_target = false;
                    _overlay.add_overlay(_progress);
                }
                _progress.fraction = value.clamp(0, 1);
                _progress.visible = true;
            }
        }
    }

    public class MediaShelf : Box {
        public signal void item_activated(uint index);

        private Label _title;
        private Box _row;
        private ScrolledWindow _scroll;
        private uint _count = 0;
        private int _tile_size;
        private bool _round;

        public int tile_height { get; set; default = -1; }
        public bool bare { get; set; default = false; }

        public MediaShelf(string title, int tile_size = 148, bool round = false) {
            Object(orientation: Orientation.VERTICAL, spacing: 8);
            add_css_class("media-shelf");
            _tile_size = tile_size;
            _round = round;
            _title = new Label(title);
            _title.xalign = 0;
            _title.add_css_class("media-shelf-title");
            append(_title);
            _row = new Box(Orientation.HORIZONTAL, 16);
            _row.add_css_class("media-shelf-row");
            _scroll = new ScrolledWindow();
            _scroll.hscrollbar_policy = PolicyType.EXTERNAL;
            _scroll.vscrollbar_policy = PolicyType.NEVER;
            _scroll.propagate_natural_height = true;
            _scroll.hexpand = true;
            _scroll.set_child(_row);
            append(_scroll);
            var wheel = new EventControllerScroll(EventControllerScrollFlags.VERTICAL | EventControllerScrollFlags.HORIZONTAL);
            wheel.scroll.connect((dx, dy) => {
                if (dx == 0) return false;
                var adj = _scroll.hadjustment;
                adj.value = (adj.value + dx * 40).clamp(adj.lower, adj.upper - adj.page_size);
                return true;
            });
            _scroll.add_controller(wheel);
        }

        public string title {
            get { return _title.label; }
            set { _title.label = value; }
        }

        public uint count { get { return _count; } }

        public MediaArt append_tile(string icon_name, string title, string? subtitle) {
            uint index = _count++;
            var button = new Button();
            button.add_css_class("media-shelf-tile");
            button.add_css_class("flat");
            button.hexpand = false;
            button.tooltip_text = subtitle != null && subtitle != "" ? "%s\n%s".printf(title, subtitle) : title;
            var box = new Box(Orientation.VERTICAL, 4);
            box.width_request = _tile_size;
            var art = new MediaArt(_tile_size, icon_name, _round, tile_height);
            if (bare) art.set_bare(true);
            box.append(art);
            bool center = _round || bare;
            var name = new Label(title);
            name.xalign = center ? 0.5f : 0;
            name.ellipsize = Pango.EllipsizeMode.END;
            name.max_width_chars = 1;
            name.hexpand = true;
            name.margin_top = 4;
            name.add_css_class("media-shelf-name");
            box.append(name);
            if (subtitle != null && subtitle != "") {
                var sub = new Label(subtitle);
                sub.xalign = center ? 0.5f : 0;
                sub.ellipsize = Pango.EllipsizeMode.END;
                sub.max_width_chars = 1;
                sub.add_css_class("dim-label");
                sub.add_css_class("caption");
                box.append(sub);
            }
            button.set_child(box);
            button.set_data<Widget>(Singularity.Animation.FocusRing.TARGET_KEY, art);
            button.clicked.connect(() => item_activated(index));
            _row.append(button);
            return art;
        }

        public void clear() {
            Widget? w;
            while ((w = _row.get_first_child()) != null) _row.remove(w);
            _count = 0;
            _scroll.hadjustment.value = 0;
        }
    }

    public class MediaHero : Box {
        public signal void primary_clicked();
        public signal void secondary_clicked();

        private MediaArt _art;
        private Label _eyebrow;
        private Label _title;
        private Label _subtitle;
        private Button _primary;
        private Button _secondary;

        public MediaHero(string icon_name, int art_size = 168, int art_height = -1) {
            Object(orientation: Orientation.HORIZONTAL, spacing: 28);
            add_css_class("media-hero");
            _art = new MediaArt(art_size, icon_name, false, art_height);
            _art.valign = Align.CENTER;
            append(_art);
            var text = new Box(Orientation.VERTICAL, 6);
            text.valign = Align.CENTER;
            text.hexpand = true;
            _eyebrow = new Label("");
            _eyebrow.xalign = 0;
            _eyebrow.add_css_class("media-hero-eyebrow");
            _eyebrow.visible = false;
            text.append(_eyebrow);
            _title = new Label("");
            _title.xalign = 0;
            _title.wrap = true;
            _title.lines = 2;
            _title.ellipsize = Pango.EllipsizeMode.END;
            _title.add_css_class("media-hero-title");
            text.append(_title);
            _subtitle = new Label("");
            _subtitle.xalign = 0;
            _subtitle.ellipsize = Pango.EllipsizeMode.END;
            _subtitle.add_css_class("dim-label");
            _subtitle.add_css_class("media-hero-subtitle");
            text.append(_subtitle);
            var actions = new Box(Orientation.HORIZONTAL, 10);
            actions.margin_top = 14;
            _primary = new Button.with_label("");
            _primary.add_css_class("suggested-action");
            _primary.add_css_class("pill");
            _primary.clicked.connect(() => primary_clicked());
            actions.append(_primary);
            _secondary = new Button.with_label("");
            _secondary.add_css_class("pill");
            _secondary.clicked.connect(() => secondary_clicked());
            _secondary.visible = false;
            actions.append(_secondary);
            text.append(actions);
            append(text);
        }

        public MediaArt art { get { return _art; } }

        public string eyebrow {
            get { return _eyebrow.label; }
            set { _eyebrow.label = value; _eyebrow.visible = value != ""; }
        }

        public string title {
            get { return _title.label; }
            set { _title.label = value; }
        }

        public string subtitle {
            get { return _subtitle.label; }
            set { _subtitle.label = value; _subtitle.visible = value != ""; }
        }

        public string primary_label {
            get { return _primary.label; }
            set { _primary.label = value; }
        }

        public string? secondary_label {
            get { return _secondary.label; }
            set { _secondary.label = value ?? ""; _secondary.visible = value != null && value != ""; }
        }

        public void focus_primary() {
            _primary.grab_focus();
        }
    }
}
