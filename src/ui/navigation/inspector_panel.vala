using Gtk;
namespace Singularity.Widgets {

    public class InspectorPanel : Widget {
        public Stack stack { get; private set; }
        public SidebarTabs switcher { get; private set; }
        public Box top { get; private set; }
        private Box box;
        private Stack header;
        private Label sub_title;
        private Button more;
        private int target;
        private string last_primary = "";
        private Gee.ArrayList<string> primary = new Gee.ArrayList<string> ();
        private Gee.ArrayList<string> secondary = new Gee.ArrayList<string> ();
        private Gee.HashMap<string, string> titles = new Gee.HashMap<string, string> ();
        private Gee.HashMap<string, string> icons = new Gee.HashMap<string, string> ();
        private bool syncing = false;

        public bool scroll_pages { get; set; default = false; }
        private bool _compact_tabs = false;

        public bool compact_tabs {
            get { return _compact_tabs; }
            set {
                _compact_tabs = value;
                switcher.homogeneous = !value;
            }
        }

        public signal void page_chosen (string name);

        public InspectorPanel (int width, bool inset_header = true) {
            target = width;
            add_css_class ("sx-inspector");
            hexpand = false;
            overflow = Overflow.HIDDEN;
            box = new Box (Orientation.VERTICAL, 0);
            box.add_css_class ("sx-inspector-body");
            box.set_parent (this);
            header = new Stack ();
            header.transition_type = StackTransitionType.CROSSFADE;
            header.add_css_class ("sx-inspector-header");
            header.vhomogeneous = true;
            if (inset_header) apply_bubble_inset (header);
            else apply_bubble_inset (box);
            var tabs = new Box (Orientation.HORIZONTAL, 6);
            switcher = new SidebarTabs ();
            switcher.margin_bottom = 0;
            switcher.selected.connect ((name) => {
                if (!syncing) page_chosen (name);
            });
            tabs.append (switcher);
            more = new Button.from_icon_name ("view-more-symbolic");
            more.tooltip_text = _("More Panels");
            more.valign = Align.CENTER;
            more.add_css_class ("sx-inspector-more");
            more.update_property (AccessibleProperty.LABEL, _("More Panels"), -1);
            more.visible = false;
            more.clicked.connect (() => show_more_at (more));
            tabs.append (more);
            header.add_named (tabs, "tabs");
            var sub = new Box (Orientation.HORIZONTAL, 8);
            var back = new Button.from_icon_name ("go-previous-symbolic");
            back.tooltip_text = _("Back");
            back.valign = Align.CENTER;
            back.add_css_class ("sx-inspector-more");
            back.clicked.connect (() => page_chosen (last_primary != "" ? last_primary : primary[0]));
            sub.append (back);
            sub_title = new Label ("");
            sub_title.add_css_class ("title-4");
            sub_title.xalign = 0;
            sub_title.hexpand = true;
            sub_title.ellipsize = Pango.EllipsizeMode.END;
            sub.append (sub_title);
            var more2 = new Button.from_icon_name ("view-more-symbolic");
            more2.tooltip_text = _("More Panels");
            more2.valign = Align.CENTER;
            more2.add_css_class ("sx-inspector-more");
            more2.clicked.connect (() => show_more_at (more2));
            sub.append (more2);
            header.add_named (sub, "sub");
            box.append (header);
            top = new Box (Orientation.VERTICAL, 0);
            box.append (top);
            stack = new Stack ();
            stack.vexpand = true;
            stack.vhomogeneous = false;
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.transition_duration = 150;
            box.append (stack);
        }

        public void add_page (string name, string title, string icon, Widget content, bool is_primary) {
            Widget page_widget = content;
            if (scroll_pages) {
                var scroll = new ScrolledWindow ();
                scroll.hscrollbar_policy = PolicyType.NEVER;
                scroll.vexpand = true;
                content.margin_start = 14;
                content.margin_end = 14;
                content.margin_bottom = 14;
                content.vexpand = true;
                scroll.child = content;
                page_widget = scroll;
            }
            stack.add_titled (page_widget, name, title);
            titles[name] = title;
            icons[name] = icon;
            if (is_primary) {
                primary.add (name);
                switcher.add_option (name, title);
                if (_compact_tabs && switcher.get_last_child () != null) switcher.get_last_child ().hexpand = true;
                if (last_primary == "") last_primary = name;
            } else {
                secondary.add (name);
                more.visible = true;
            }
        }

        public string page {
            owned get {
                return stack.visible_child_name;
            }
            set {
                stack.visible_child_name = value;
                bool prim = primary.contains (value);
                header.visible_child_name = prim ? "tabs" : "sub";
                if (prim) {
                    last_primary = value;
                    syncing = true;
                    switcher.set_active (value);
                    syncing = false;
                } else {
                    sub_title.label = titles[value] ?? "";
                }
            }
        }

        private void show_more_at (Widget anchor) {
            var menu = new ContextMenu (anchor);
            foreach (string n in secondary) {
                string name = n;
                menu.add_item (titles[name], icons[name], () => page_chosen (name));
            }
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        public static Widget empty_state (string icon, string title, string description) {
            var st = new StatusPage ();
            st.compact = true;
            st.icon_name = icon;
            st.title = title;
            st.description = description;
            st.vexpand = true;
            st.valign = Align.CENTER;
            return st;
        }

        public override void dispose () {
            if (box != null) box.unparent ();
            box = null;
            base.dispose ();
        }

        public override SizeRequestMode get_request_mode () {
            return SizeRequestMode.HEIGHT_FOR_WIDTH;
        }

        public override void measure (Orientation o, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            if (o == Orientation.HORIZONTAL) {
                minimum = natural = target;
                return;
            }
            box.measure (o, target, out minimum, out natural, null, null);
        }

        public override void size_allocate (int width, int height, int baseline) {
            box.allocate (int.max (width, 0), height, baseline, null);
        }
    }
}
