using Gtk;

namespace Singularity.Widgets {

    public enum ToolbarStyle {
        COMPACT,
        EXPANDED,
        TEXT_ONLY;

        public string to_key () {
            switch (this) {
                case EXPANDED: return "expanded";
                case TEXT_ONLY: return "text";
                default: return "compact";
            }
        }

        public static ToolbarStyle from_key (string? key) {
            switch (key) {
                case "expanded": return EXPANDED;
                case "text": return TEXT_ONLY;
                default: return COMPACT;
            }
        }
    }

    public class ToolbarSettings : Object {
        public const string SCHEMA_ID = "dev.sinty.toolbar";
        public const string REGISTRY_SCHEMA_ID = "dev.sinty.toolbars";

        public static string path_for (string app_id) {
            return "/dev/sinty/toolbar/%s/".printf (app_id.replace (".", "-"));
        }

        public static GLib.Settings? for_app (string? app_id) {
            if (app_id == null || app_id == "") return null;
            var src = GLib.SettingsSchemaSource.get_default ();
            if (src == null) return null;
            var schema = src.lookup (SCHEMA_ID, true);
            if (schema == null) return null;
            return new GLib.Settings.full (schema, null, path_for (app_id));
        }

        public static void register (string app_id) {
            var registry = Singularity.Core.safe_settings (REGISTRY_SCHEMA_ID);
            if (registry == null) return;
            string[] apps = registry.get_strv ("apps");
            foreach (unowned string a in apps) if (a == app_id) return;
            apps += app_id;
            registry.set_strv ("apps", apps);
        }

        public static bool is_registered (string app_id) {
            var registry = Singularity.Core.safe_settings (REGISTRY_SCHEMA_ID);
            if (registry == null) return false;
            foreach (unowned string a in registry.get_strv ("apps")) if (a == app_id) return true;
            return false;
        }
    }

    public delegate void RibbonMenuBuilder (ContextMenu menu);

    public abstract class RibbonItem : Object {
        public string id { get; construct; }
        public string? label { get; set; }
        public string? icon_name { get; set; }
        public string? tooltip { get; set; }
        public string? shortcut { get; set; }
        public bool label_in_compact { get; set; default = false; }
        public Widget widget { get; protected set; }

        protected ToolbarStyle style = ToolbarStyle.COMPACT;
        protected Image? face_icon = null;
        protected Label? face_label = null;
        protected Box? face_box = null;
        protected Widget? custom_face = null;

        public signal void activated ();

        construct {
            notify["label"].connect (() => refresh ());
            notify["icon-name"].connect (() => refresh ());
            notify["tooltip"].connect (() => refresh ());
            notify["shortcut"].connect (() => refresh ());
            notify["label-in-compact"].connect (() => refresh ());
        }

        internal void set_style (ToolbarStyle s) {
            style = s;
            refresh ();
        }

        protected Box build_face () {
            var box = new Box (Orientation.HORIZONTAL, 6);
            face_icon = new Image ();
            face_label = new Label (null);
            box.append (face_icon);
            box.append (face_label);
            face_box = box;
            return box;
        }

        protected bool has_icon () {
            return custom_face != null || (icon_name != null && icon_name != "");
        }

        protected bool shows_icon () {
            if (!has_icon ()) return false;
            if (style == ToolbarStyle.TEXT_ONLY) return label == null || label == "";
            return true;
        }

        protected bool shows_label () {
            if (label == null || label == "") return false;
            switch (style) {
                case ToolbarStyle.COMPACT: return label_in_compact || !has_icon ();
                default: return true;
            }
        }

        internal virtual void refresh () {
            bool icon_shown = shows_icon ();
            if (face_icon != null) {
                face_icon.icon_name = icon_name;
                face_icon.visible = icon_shown;
            }
            if (custom_face != null) custom_face.visible = icon_shown;
            if (face_label != null) {
                face_label.label = label ?? "";
                face_label.visible = shows_label ();
            }
            if (widget != null) widget.tooltip_text = tooltip_text ();
            if (widget is Button && face_box != null && face_label != null && ((Button) widget).child == face_box) {
                bool only_icon = icon_shown && !face_label.visible;
                bool only_text = face_label.visible && !icon_shown;
                if (only_icon) widget.add_css_class ("image-button");
                else widget.remove_css_class ("image-button");
                if (only_text) widget.add_css_class ("text-button");
                else widget.remove_css_class ("text-button");
            }
        }

        internal string? tooltip_text () {
            string? text = tooltip ?? label;
            if (text == null) return null;
            string? keys = shortcut ?? accel_label ();
            if (keys == null || keys == "" || text.contains ("(" + keys + ")")) return text;
            return "%s (%s)".printf (text, keys);
        }

        internal virtual string? accel_label () {
            return null;
        }

        internal string menu_label () {
            if (label != null && label != "") return label;
            return tooltip ?? id;
        }

        internal abstract void fill_overflow (ContextMenu menu);

        protected static string? accel_for_action (Widget w, string? action_name, Variant? target) {
            if (action_name == null) return null;
            var app = GLib.Application.get_default () as Gtk.Application;
            if (app == null) return null;
            string detailed = target != null ? GLib.Action.print_detailed_name (action_name, target) : action_name;
            string[] accels = app.get_accels_for_action (detailed);
            if (accels.length == 0) return null;
            uint key;
            Gdk.ModifierType mods;
            if (!Gtk.accelerator_parse (accels[0], out key, out mods)) return null;
            return Gtk.accelerator_get_label (key, mods);
        }
    }

    public class RibbonButton : RibbonItem {
        public string? action_name { get; construct; }
        public Variant? action_target { get; construct; }
        public Button button { get; private set; }

        public RibbonButton (string id, string? icon_name, string? label, string? tooltip = null, string? action_name = null, Variant? action_target = null) {
            Object (id: id, icon_name: icon_name, label: label, tooltip: tooltip, action_name: action_name, action_target: action_target);
        }

        construct {
            button = new Button ();
            button.add_css_class ("flat");
            button.add_css_class ("context-ribbon-item");
            button.focus_on_click = false;
            button.child = build_face ();
            if (action_name != null) {
                button.action_name = action_name;
                if (action_target != null) button.action_target = action_target;
            }
            button.clicked.connect (() => activated ());
            widget = button;
            refresh ();
        }

        internal override string? accel_label () {
            return accel_for_action (button, action_name, action_target);
        }

        internal override void fill_overflow (ContextMenu menu) {
            if (!button.sensitive) return;
            menu.add_item (menu_label (), icon_name, () => button.activate ());
        }
    }

    public class RibbonToggle : RibbonItem {
        public string? action_name { get; construct; }
        public Variant? action_target { get; construct; }
        public ToggleButton button { get; private set; }

        public bool active {
            get { return button.active; }
            set { if (button.active != value) button.active = value; }
        }

        public signal void toggled (bool active);

        public RibbonToggle (string id, string? icon_name, string? label, string? tooltip = null, string? action_name = null, Variant? action_target = null) {
            Object (id: id, icon_name: icon_name, label: label, tooltip: tooltip, action_name: action_name, action_target: action_target);
        }

        construct {
            button = new ToggleButton ();
            button.add_css_class ("flat");
            button.add_css_class ("context-ribbon-item");
            button.focus_on_click = false;
            button.child = build_face ();
            if (action_name != null) {
                button.action_name = action_name;
                if (action_target != null) button.action_target = action_target;
            }
            button.toggled.connect (() => {
                notify_property ("active");
                toggled (button.active);
                activated ();
            });
            widget = button;
            refresh ();
        }

        internal override string? accel_label () {
            return accel_for_action (button, action_name, action_target);
        }

        internal override void fill_overflow (ContextMenu menu) {
            if (!button.sensitive) return;
            menu.add_item (menu_label (), button.active ? "object-select-symbolic" : icon_name,
                () => button.active = !button.active, button.active ? "checked" : null);
        }
    }

    public class RibbonSelector : RibbonItem {
        private class Entry {
            public string? id;
            public string label;
            public bool separator;
            public RibbonMenuBuilder? extra;
        }

        public int width_chars { get; construct; }
        public Button button { get; private set; }
        private Label value_label;
        private Gee.ArrayList<Entry> entries = new Gee.ArrayList<Entry> ();
        private string? _selected = null;

        public string? selected {
            get { return _selected; }
            set {
                _selected = value;
                string? text = option_label (value);
                if (text != null) this.text = text;
            }
        }

        public string text {
            get { return value_label.label; }
            set { value_label.label = value; }
        }

        public signal void changed (string id);

        public RibbonSelector (string id, string? tooltip, int width_chars = 8, string? icon_name = null) {
            Object (id: id, tooltip: tooltip, width_chars: width_chars, icon_name: icon_name);
        }

        construct {
            button = new Button ();
            button.add_css_class ("flat");
            button.add_css_class ("context-ribbon-item");
            button.add_css_class ("context-ribbon-selector");
            button.focus_on_click = false;
            var box = new Box (Orientation.HORIZONTAL, 4);
            face_icon = new Image ();
            box.append (face_icon);
            value_label = new Label ("");
            value_label.width_chars = width_chars;
            value_label.max_width_chars = width_chars;
            value_label.xalign = 0;
            value_label.ellipsize = Pango.EllipsizeMode.END;
            box.append (value_label);
            var arrow = new Image.from_icon_name ("pan-down-symbolic");
            arrow.pixel_size = 12;
            box.append (arrow);
            button.child = box;
            button.clicked.connect (() => {
                activated ();
                var menu = new ContextMenu (button);
                menu.add_css_class ("context-ribbon-menu");
                fill (menu);
                popup_below (button, menu);
            });
            widget = button;
            refresh ();
        }

        internal override void refresh () {
            if (face_icon != null) {
                face_icon.icon_name = icon_name;
                face_icon.visible = icon_name != null && icon_name != "" && style != ToolbarStyle.TEXT_ONLY;
            }
            if (widget != null) widget.tooltip_text = tooltip_text ();
        }

        public void add_option (string id, string label) {
            var e = new Entry ();
            e.id = id;
            e.label = label;
            entries.add (e);
            if (_selected == id) text = label;
        }

        public void add_separator () {
            var e = new Entry ();
            e.separator = true;
            e.label = "";
            entries.add (e);
        }

        public void add_extra (owned RibbonMenuBuilder build) {
            var e = new Entry ();
            e.label = "";
            e.extra = (owned) build;
            entries.add (e);
        }

        public void clear_options () {
            entries.clear ();
        }

        private string? option_label (string? id) {
            if (id == null) return null;
            foreach (var e in entries) if (e.id == id) return e.label;
            return null;
        }

        private void fill (ContextMenu menu) {
            foreach (var e in entries) {
                if (e.separator) {
                    menu.add_separator ();
                } else if (e.extra != null) {
                    e.extra (menu);
                } else {
                    string oid = e.id;
                    menu.add_item (e.label, null, () => {
                        selected = oid;
                        changed (oid);
                    }, oid == _selected ? "checked" : null);
                }
            }
        }

        internal override void fill_overflow (ContextMenu menu) {
            if (!button.sensitive) return;
            fill (menu.add_submenu (menu_label (), icon_name));
        }
    }

    public class RibbonMenu : RibbonItem {
        public Button button { get; private set; }
        private RibbonMenuBuilder? builder = null;
        private MenuModel? model = null;

        public RibbonMenu (string id, string? icon_name, string? label, string? tooltip = null) {
            Object (id: id, icon_name: icon_name, label: label, tooltip: tooltip);
        }

        construct {
            button = new Button ();
            button.add_css_class ("flat");
            button.add_css_class ("context-ribbon-item");
            button.add_css_class ("context-ribbon-menu-button");
            button.focus_on_click = false;
            var box = new Box (Orientation.HORIZONTAL, 4);
            box.append (build_face ());
            var arrow = new Image.from_icon_name ("pan-down-symbolic");
            arrow.pixel_size = 12;
            box.append (arrow);
            button.child = box;
            button.clicked.connect (() => {
                activated ();
                popup ();
            });
            widget = button;
            refresh ();
        }

        public void set_builder (owned RibbonMenuBuilder build) {
            builder = (owned) build;
            model = null;
        }

        public void set_menu_model (MenuModel menu_model) {
            model = menu_model;
            builder = null;
        }

        public void set_face (Widget face) {
            if (face_icon != null) {
                face_box.remove (face_icon);
                face_icon = null;
            } else if (custom_face != null) {
                face_box.remove (custom_face);
            }
            custom_face = face;
            face_box.prepend (face);
            refresh ();
        }

        public void popup () {
            if (builder != null) {
                var menu = new ContextMenu (button);
                menu.add_css_class ("context-ribbon-menu");
                builder (menu);
                popup_below (button, menu);
            } else if (model != null) {
                var pop = new PopoverMenu.from_model (model);
                pop.add_css_class ("singularity-app-menu");
                pop.has_arrow = false;
                pop.set_parent (button);
                pop.closed.connect (() => Idle.add (() => {
                    if (pop.get_parent () != null) pop.unparent ();
                    return Source.REMOVE;
                }));
                pop.popup ();
            }
        }

        internal override void fill_overflow (ContextMenu menu) {
            if (!button.sensitive) return;
            if (builder != null) {
                builder (menu.add_submenu (menu_label (), icon_name));
            } else if (model != null) {
                menu.add_item (menu_label (), icon_name, () => popup ());
            }
        }
    }

    public class RibbonSeparator : RibbonItem {
        public RibbonSeparator (string id) {
            Object (id: id);
        }

        construct {
            var s = new Separator (Orientation.VERTICAL);
            s.add_css_class ("context-ribbon-separator");
            s.margin_start = 6;
            s.margin_end = 6;
            widget = s;
        }

        internal override void fill_overflow (ContextMenu menu) {
        }
    }

    public class RibbonWidget : RibbonItem {
        public Widget child { get; construct; }

        public RibbonWidget (string id, Widget child, string? label = null, string? icon_name = null) {
            Object (id: id, child: child, label: label, icon_name: icon_name);
        }

        construct {
            widget = child;
        }

        internal override void refresh () {
        }

        internal override void fill_overflow (ContextMenu menu) {
            if (label == null || !(child is Button) || !child.sensitive) return;
            menu.add_item (label, icon_name, () => child.activate ());
        }
    }

    private void popup_below (Widget anchor, ContextMenu menu) {
        Gdk.Rectangle rect = { anchor.get_width () / 2, anchor.get_height (), 1, 1 };
        menu.set_pointing_to (rect);
        menu.closed.connect (() => Idle.add (() => {
            if (menu.get_parent () != null) menu.unparent ();
            return Source.REMOVE;
        }));
        menu.popup ();
    }

    public class RibbonContext : Object {
        public string id { get; construct; }
        public string title { get; construct; }
        public string? icon_name { get; construct; }
        private bool _shown = true;
        public bool shown {
            get { return _shown; }
            set {
                if (_shown == value) return;
                _shown = value;
                if (ribbon != null) ribbon.context_shown_changed (this);
            }
        }
        internal RibbonStrip strip;
        internal Gee.ArrayList<RibbonItem> items = new Gee.ArrayList<RibbonItem> ();
        internal weak ContextRibbon? ribbon = null;
        private int counter = 0;

        public RibbonContext (string id, string title, string? icon_name = null) {
            Object (id: id, title: title, icon_name: icon_name);
        }

        construct {
            strip = new RibbonStrip (this);
        }

        public T add<T> (RibbonItem item) {
            items.add (item);
            if (ribbon != null) item.set_style (ribbon.toolbar_style);
            strip.add_item (item);
            return (T) item;
        }

        private string auto_id (string kind) {
            return "%s-%s-%d".printf (id, kind, counter++);
        }

        public RibbonButton add_button (string? icon_name, string? label, string? tooltip = null, string? action_name = null, Variant? action_target = null) {
            return add<RibbonButton> (new RibbonButton (auto_id ("button"), icon_name, label, tooltip, action_name, action_target));
        }

        public RibbonToggle add_toggle (string? icon_name, string? label, string? tooltip = null, string? action_name = null, Variant? action_target = null) {
            return add<RibbonToggle> (new RibbonToggle (auto_id ("toggle"), icon_name, label, tooltip, action_name, action_target));
        }

        public RibbonSelector add_selector (string? tooltip, int width_chars = 8, string? icon_name = null) {
            return add<RibbonSelector> (new RibbonSelector (auto_id ("selector"), tooltip, width_chars, icon_name));
        }

        public RibbonMenu add_menu (string? icon_name, string? label, string? tooltip = null) {
            return add<RibbonMenu> (new RibbonMenu (auto_id ("menu"), icon_name, label, tooltip));
        }

        public RibbonSeparator add_separator () {
            return add<RibbonSeparator> (new RibbonSeparator (auto_id ("separator")));
        }

        public RibbonWidget add_widget (Widget widget, string? label = null, string? icon_name = null) {
            return add<RibbonWidget> (new RibbonWidget (auto_id ("widget"), widget, label, icon_name));
        }
    }

    internal class RibbonStrip : Widget {
        private const int SPACING = 2;
        private weak RibbonContext context;
        private Button more;
        private Gee.ArrayList<RibbonItem> hidden = new Gee.ArrayList<RibbonItem> ();

        public RibbonStrip (RibbonContext context) {
            this.context = context;
            add_css_class ("context-ribbon-strip");
            overflow = Overflow.HIDDEN;
            more = new Button.from_icon_name ("view-more-symbolic");
            more.add_css_class ("flat");
            more.add_css_class ("context-ribbon-more");
            more.tooltip_text = _("More");
            more.focus_on_click = false;
            more.set_parent (this);
            more.clicked.connect (show_more);
        }

        public override void dispose () {
            Widget? c;
            while ((c = get_first_child ()) != null) c.unparent ();
            base.dispose ();
        }

        internal void add_item (RibbonItem item) {
            item.widget.insert_before (this, more);
            queue_resize ();
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            int mmin, mnat;
            more.measure (orientation, -1, out mmin, out mnat, null, null);
            if (orientation == Orientation.HORIZONTAL) {
                int total = 0;
                int n = 0;
                for (var c = get_first_child (); c != null; c = c.get_next_sibling ()) {
                    if (c == more || !c.visible) continue;
                    int cmin, cnat;
                    c.measure (orientation, -1, out cmin, out cnat, null, null);
                    total += cnat;
                    n++;
                }
                if (n > 1) total += SPACING * (n - 1);
                minimum = mnat;
                natural = int.max (total, mnat);
            } else {
                int high_min = mmin;
                int high_nat = mnat;
                for (var c = get_first_child (); c != null; c = c.get_next_sibling ()) {
                    if (!c.visible) continue;
                    int cmin, cnat;
                    c.measure (orientation, -1, out cmin, out cnat, null, null);
                    high_min = int.max (high_min, cmin);
                    high_nat = int.max (high_nat, cnat);
                }
                minimum = high_min;
                natural = high_nat;
            }
        }

        public override void size_allocate (int width, int height, int baseline) {
            var widgets = new Gee.ArrayList<Widget> ();
            var widths = new Gee.ArrayList<int> ();
            int total = 0;
            for (var c = get_first_child (); c != null; c = c.get_next_sibling ()) {
                if (c == more || !c.visible) continue;
                int cmin, cnat;
                c.measure (Orientation.HORIZONTAL, -1, out cmin, out cnat, null, null);
                widgets.add (c);
                widths.add (cnat);
                total += cnat;
            }
            if (widgets.size > 1) total += SPACING * (widgets.size - 1);

            hidden.clear ();
            int mmin, mnat;
            more.measure (Orientation.HORIZONTAL, -1, out mmin, out mnat, null, null);
            int limit = total <= width ? width : width - mnat - SPACING;
            int fit = 0;
            int x = 0;
            for (int i = 0; i < widgets.size; i++) {
                int end = x + widths[i];
                if (end > limit) break;
                x = end + SPACING;
                fit = i + 1;
            }
            while (fit > 0 && item_of (widgets[fit - 1]) is RibbonSeparator) fit--;

            x = 0;
            for (int i = 0; i < widgets.size; i++) {
                var w = widgets[i];
                if (i < fit) {
                    w.set_child_visible (true);
                    w.allocate (widths[i], height, -1, new Gsk.Transform ().translate (Graphene.Point ().init (x, 0)));
                    x += widths[i] + SPACING;
                } else {
                    w.set_child_visible (false);
                    var item = item_of (w);
                    if (item != null) hidden.add (item);
                }
            }
            bool overflowing = fit < widgets.size;
            more.set_child_visible (overflowing);
            if (overflowing) {
                more.allocate (mnat, height, -1, new Gsk.Transform ().translate (Graphene.Point ().init (width - mnat, 0)));
            }
        }

        private RibbonItem? item_of (Widget w) {
            foreach (var item in context.items) if (item.widget == w) return item;
            return null;
        }

        private void show_more () {
            var menu = new ContextMenu (more);
            menu.add_css_class ("context-ribbon-menu");
            bool pending_separator = false;
            bool any = false;
            foreach (var item in hidden) {
                if (item is RibbonSeparator) {
                    pending_separator = any;
                    continue;
                }
                if (pending_separator) {
                    menu.add_separator ();
                    pending_separator = false;
                }
                item.fill_overflow (menu);
                any = true;
            }
            popup_below (more, menu);
        }
    }

    public class ContextRibbon : Box {
        public Stack stack { get; private set; }
        public BubbleSwitcher tabs { get; private set; }
        public string? app_id { get; construct set; }
        private Gee.ArrayList<RibbonContext> contexts = new Gee.ArrayList<RibbonContext> ();
        private GLib.Settings? settings = null;
        private ToolbarStyle _style = ToolbarStyle.COMPACT;
        private string? restore_context = null;
        private Box tab_row;
        private weak Widget? tabs_home = null;
        private weak Widget? tabs_home_prev = null;
        private bool _tabs_in_ribbon = false;

        public bool tabs_in_ribbon {
            get { return _tabs_in_ribbon; }
            set {
                if (_tabs_in_ribbon == value) return;
                _tabs_in_ribbon = value;
                move_tabs ();
            }
        }

        public ToolbarStyle toolbar_style {
            get { return _style; }
            set {
                if (_style == value) return;
                _style = value;
                foreach (var c in contexts) foreach (var item in c.items) item.set_style (value);
                remove_css_class ("compact");
                remove_css_class ("expanded");
                remove_css_class ("text-only");
                add_css_class (value == ToolbarStyle.EXPANDED ? "expanded" : value == ToolbarStyle.TEXT_ONLY ? "text-only" : "compact");
            }
        }

        public string? active_context {
            get { return stack.visible_child_name; }
            set { if (value != null && stack.get_child_by_name (value) != null) stack.visible_child_name = value; }
        }

        public signal void context_changed (string id);

        public ContextRibbon (string? app_id = null) {
            Object (orientation: Orientation.VERTICAL, spacing: 0, app_id: app_id);
        }

        construct {
            add_css_class ("context-ribbon");
            add_css_class ("compact");
            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.transition_duration = Singularity.Motion.Duration.SMALL;
            stack.hhomogeneous = false;
            stack.vhomogeneous = true;
            tab_row = new Box (Orientation.HORIZONTAL, 0);
            tab_row.add_css_class ("context-ribbon-tab-row");
            tab_row.visible = false;
            append (tab_row);
            append (stack);
            tabs = new BubbleSwitcher ();
            tabs.add_css_class ("context-ribbon-tabs");
            tabs.notify["visible"].connect (sync_tab_row);
            tabs.selected.connect ((name) => {
                if (stack.get_child_by_name (name) != null) stack.visible_child_name = name;
            });
            if (app_id == null) {
                var app = GLib.Application.get_default ();
                if (app != null) app_id = app.application_id;
            }
            settings = ToolbarSettings.for_app (app_id);
            if (settings != null) {
                ToolbarSettings.register (app_id);
                toolbar_style = ToolbarStyle.from_key (settings.get_string ("toolbar-style"));
                settings.changed["toolbar-style"].connect (() => {
                    toolbar_style = ToolbarStyle.from_key (settings.get_string ("toolbar-style"));
                });
                restore_context = settings.get_string ("last-context");
            }
            stack.notify["visible-child-name"].connect (() => {
                string? name = stack.visible_child_name;
                if (name == null) return;
                tabs.set_active (name);
                if (settings != null && restore_context == null && settings.get_string ("last-context") != name)
                    settings.set_string ("last-context", name);
                context_changed (name);
            });
        }

        public RibbonContext add_context (string id, string title, string? icon_name = null) {
            var context = new RibbonContext (id, title, icon_name);
            context.ribbon = this;
            contexts.add (context);
            stack.add_titled (context.strip, id, title);
            tabs.add_option (id, title);
            if (restore_context != null && restore_context == id) {
                stack.visible_child_name = id;
            }
            return context;
        }

        internal void context_shown_changed (RibbonContext context) {
            tabs.set_option_visible (context.id, context.shown);
        }

        public RibbonContext? get_context (string id) {
            foreach (var c in contexts) if (c.id == id) return c;
            return null;
        }

        public override void map () {
            restore_context = null;
            base.map ();
        }

        public void attach (Window window) {
            window.add_bubble_widget (tabs);
        }

        private void move_tabs () {
            var parent = tabs.get_parent ();
            if (_tabs_in_ribbon) {
                if (parent == tab_row) return;
                if (parent != null) {
                    tabs_home = parent;
                    tabs_home_prev = tabs.get_prev_sibling ();
                    if (parent is Box) ((Box) parent).remove (tabs);
                    else tabs.unparent ();
                }
                tab_row.append (tabs);
            } else if (parent == tab_row) {
                tab_row.remove (tabs);
                var home = tabs_home as Box;
                if (home != null) {
                    var prev = tabs_home_prev;
                    if (prev != null && prev.get_parent () == home) home.insert_child_after (tabs, prev);
                    else home.prepend (tabs);
                }
            }
            sync_tab_row ();
        }

        private void sync_tab_row () {
            tab_row.visible = tabs.get_parent () == tab_row && tabs.visible;
        }
    }
}
