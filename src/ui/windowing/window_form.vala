using Gtk;

namespace Singularity.Widgets {

    internal class ScaleBin : Widget {
        private Widget? _child;
        private double _factor = 1.0;

        public double factor {
            get { return _factor; }
            set {
                if (value == _factor) return;
                _factor = value;
                queue_resize();
            }
        }

        public ScaleBin(Widget child) {
            _child = child;
            child.set_parent(this);
            hexpand = true;
            vexpand = true;
        }

        public override void dispose() {
            if (_child != null) {
                _child.unparent();
                _child = null;
            }
            base.dispose();
        }

        public override SizeRequestMode get_request_mode() {
            return _child != null ? _child.get_request_mode() : SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure(Orientation orientation, int for_size, out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            if (_child == null) {
                minimum = 0;
                natural = 0;
                return;
            }
            int inner = for_size < 0 ? -1 : (int) (for_size / _factor);
            int mb, nb;
            _child.measure(orientation, inner, out minimum, out natural, out mb, out nb);
            minimum = (int) Math.ceil(minimum * _factor);
            natural = (int) Math.ceil(natural * _factor);
        }

        public override void size_allocate(int width, int height, int baseline) {
            if (_child == null) return;
            if (_factor == 1.0) {
                _child.allocate(width, height, baseline, null);
                return;
            }
            var t = new Gsk.Transform().scale((float) _factor, (float) _factor);
            _child.allocate((int) (width / _factor), (int) (height / _factor), -1, t);
        }
    }

    internal class WindowForm : Object {
        public const string DESKTOP_KEY = "X-Sinty-FormFactors";
        private const int TV_LOGICAL_WIDTH = 960;
        private const int TV_MAX_TABS = 6;
        private const int POINTER_STEP = 24;
        private const int POINTER_STEP_MAX = 96;
        private const int POINTER_SIZE = 26;

        private unowned Window _win;
        private Gdk.Surface? _surface = null;
        private ulong _enter_id = 0;
        private ulong _leave_id = 0;
        private ulong _ff_id = 0;
        private ulong _outputs_id = 0;
        private ulong _visible_id = 0;
        private GenericArray<Gdk.Monitor> _entered = new GenericArray<Gdk.Monitor>();
        private Gdk.Monitor? _monitor = null;
        private bool _we_fullscreened = false;
        private Box? _head = null;
        private Box? _tabs = null;
        private EventControllerKey? _keys = null;
        private bool _user_moved = false;
        private Widget? _ok_target = null;
        private GenericArray<Widget> _origins = new GenericArray<Widget>();
        private bool _ok_long = false;
        private uint _ok_source = 0;
        private TvTextKeys _text_keys = new TvTextKeys();
        private int _start_tries = 0;
        private Fixed? _pointer_layer = null;
        private Box? _pointer = null;
        private int _px = 200;
        private int _py = 200;
        private int _step = POINTER_STEP;
        private int64 _last_press = 0;
        private uint _rebuild_source = 0;
        private bool _hinted = false;
        private bool _dark_held = false;
        private Button? _search_tab = null;
        private Gtk.SearchEntry? _search_entry = null;
        private SearchBubble? _search_target = null;

        public FormFactorKind kind { get; private set; default = FormFactorKind.DESKTOP; }
        public bool compat { get; private set; default = false; }

        public signal void changed(FormFactorKind previous);

        public WindowForm(Window win) {
            _win = win;
            var ff = FormFactor.get_default();
            _ff_id = ff.changed.connect(() => update());
            _outputs_id = ff.outputs_changed.connect(() => update());
            ((Widget) win).realize.connect_after(track_surface);
            ((Widget) win).map.connect_after(() => update());
            win.notify["application"].connect(() => update());
        }

        public void release() {
            var ff = FormFactor.get_default();
            if (_ff_id != 0) ff.disconnect(_ff_id);
            if (_outputs_id != 0) ff.disconnect(_outputs_id);
            _ff_id = 0;
            _outputs_id = 0;
            untrack_surface();
            if (_rebuild_source != 0) Source.remove(_rebuild_source);
            _rebuild_source = 0;
            if (_ok_source != 0) Source.remove(_ok_source);
            _ok_source = 0;
            if (_visible_id != 0) _win.disconnect(_visible_id);
            _visible_id = 0;
        }

        private void track_surface() {
            var surface = _win.get_surface();
            if (surface == _surface) return;
            untrack_surface();
            _surface = surface;
            if (surface == null) return;
            _enter_id = surface.enter_monitor.connect((m) => {
                if (_entered.find(m, null)) return;
                _entered.add(m);
                if (_we_fullscreened) _monitor = m;
                update();
            });
            _leave_id = surface.leave_monitor.connect((m) => {
                _entered.remove(m);
                update();
            });
        }

        private void untrack_surface() {
            if (_surface != null) {
                if (_enter_id != 0) _surface.disconnect(_enter_id);
                if (_leave_id != 0) _surface.disconnect(_leave_id);
            }
            _enter_id = 0;
            _leave_id = 0;
            _surface = null;
            _entered.remove_range(0, _entered.length);
        }

        private Gdk.Monitor? pick_monitor() {
            if (_monitor != null && _entered.find(_monitor, null)) return _monitor;
            if (_entered.length > 0) return _entered[0];
            return FormFactor.monitor_of(_win);
        }

        public static string[]? declared(GLib.Application? app) {
            var sapp = app as Singularity.Application;
            if (sapp != null && sapp.form_factors != null) return sapp.form_factors;
            if (app == null || app.application_id == null) return null;
            string value;
            var kf = new KeyFile();
            try {
                kf.load_from_data_dirs("applications/" + app.application_id + ".desktop", null, KeyFileFlags.NONE);
                value = kf.get_string("Desktop Entry", DESKTOP_KEY);
            } catch (Error e) {
                return null;
            }
            string[] ids = {};
            foreach (var part in value.split(";")) {
                string id = part.strip().down();
                if (id != "") ids += id;
            }
            return ids;
        }

        public static bool supports(string[]? ids, FormFactorKind kind) {
            if (ids == null) return true;
            foreach (var id in ids) {
                if (id == kind.to_id()) return true;
            }
            return false;
        }

        private void update() {
            _monitor = pick_monitor();
            var next = FormFactor.at(_monitor);
            bool next_compat = next == FormFactorKind.TV && !supports(declared(_win.application), FormFactorKind.TV);
            if (next == kind && next_compat == compat) {
                if (kind == FormFactorKind.TV) apply_scale();
                return;
            }
            var previous = kind;
            bool was_tv = kind == FormFactorKind.TV;
            kind = next;
            compat = next_compat;
            foreach (var k in FormFactorKind.all()) _win.remove_css_class("ff-" + k.to_id());
            _win.add_css_class("ff-" + kind.to_id());
            if (compat) _win.add_css_class("ff-compat");
            else _win.remove_css_class("ff-compat");
            if (was_tv) leave_tv();
            if (kind == FormFactorKind.TV) enter_tv();
            changed(previous);
        }

        private void apply_scale() {
            var bin = _win.scale_bin;
            if (bin == null) return;
            if (kind != FormFactorKind.TV || _monitor == null) {
                bin.factor = 1.0;
                return;
            }
            double f = (double) _monitor.get_geometry().width / TV_LOGICAL_WIDTH;
            bin.factor = f.clamp(1.0, 3.0);
        }

        private void enter_tv() {
            if (!_win.fullscreened) {
                _we_fullscreened = true;
                _win.fullscreen();
            }
            apply_scale();
            hold_dark(true);
            _win.set_focus_visible(true);
            if (_visible_id == 0) {
                _visible_id = _win.notify["focus-visible"].connect(() => {
                    if (!_win.focus_visible && kind == FormFactorKind.TV && !compat) _win.focus_visible = true;
                });
            }
            if (_keys == null) {
                _keys = new EventControllerKey();
                _keys.propagation_phase = PropagationPhase.CAPTURE;
                _keys.key_pressed.connect(on_key);
                _keys.key_released.connect(on_key_up);
                ((Widget) _win).add_controller(_keys);
            }
            if (compat) {
                show_pointer();
                if (!_hinted) {
                    _hinted = true;
                    _win.add_toast(new Toast(_("Not made for TV. Use the arrows to move the pointer and OK to click.")));
                }
                return;
            }
            _win.tv_sidebar_hidden = true;
            build_head();
            schedule_rebuild();
            _user_moved = false;
            _start_tries = 0;
            Timeout.add(200, () => {
                focus_start(true);
                return Source.REMOVE;
            });
        }

        private void leave_tv() {
            if (_ok_source != 0) {
                Source.remove(_ok_source);
                _ok_source = 0;
            }
            _ok_target = null;
            if (_visible_id != 0) {
                _win.disconnect(_visible_id);
                _visible_id = 0;
            }
            if (_keys != null) {
                ((Widget) _win).remove_controller(_keys);
                _keys = null;
            }
            hide_pointer();
            hold_dark(false);
            if (_head != null) {
                _head.unparent();
                _head = null;
                _tabs = null;
                _search_entry = null;
                _search_tab = null;
            }
            _win.tv_sidebar_hidden = false;
            if (_win.scale_bin != null) _win.scale_bin.factor = 1.0;
            if (_we_fullscreened) {
                _we_fullscreened = false;
                _win.unfullscreen();
            }
        }

        private void hold_dark(bool on) {
            if (_dark_held == on) return;
            var sapp = _win.application as Singularity.Application;
            if (sapp == null) return;
            _dark_held = on;
            sapp.tv_window(on);
        }

        private void schedule_rebuild() {
            if (_rebuild_source != 0) Source.remove(_rebuild_source);
            _rebuild_source = Timeout.add(600, () => {
                _rebuild_source = 0;
                if (kind == FormFactorKind.TV && !compat) fill_tabs();
                return Source.REMOVE;
            });
        }

        private static void collect_rows(Widget root, ref GenericArray<SidebarRow> rows) {
            for (var c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
                if (!c.visible) continue;
                var row = c as SidebarRow;
                if (row != null) {
                    rows.add(row);
                    continue;
                }
                collect_rows(c, ref rows);
            }
        }

        private void build_head() {
            if (_head != null) return;
            _head = new Box(Orientation.HORIZONTAL, 24);
            _head.add_css_class("tv-app-head");
            string? icon = _win.application != null ? _win.application.application_id : null;
            var sapp = _win.application as Singularity.Application;
            if (sapp != null && sapp.about_icon != null) icon = sapp.about_icon;
            if (icon != null) {
                var img = new Image.from_icon_name(icon);
                img.pixel_size = 32;
                _head.append(img);
            }
            var title = new Label(_win.title ?? "");
            title.add_css_class("tv-app-title");
            _win.bind_property("title", title, "label");
            _head.append(title);
            _tabs = new Box(Orientation.HORIZONTAL, 8);
            _tabs.add_css_class("tv-app-tabs");
            _head.append(_tabs);
            var outer = _win.main_container.get_parent() as Box;
            if (outer != null) outer.insert_child_after(_head, _win.main_container.get_prev_sibling());
            fill_tabs();
        }

        private void fill_tabs() {
            if (_tabs == null) return;
            Widget? w;
            while ((w = _tabs.get_first_child()) != null) _tabs.remove(w);
            var rows = new GenericArray<SidebarRow>();
            collect_rows(_win.sidebar_area, ref rows);
            _search_target = find_search(_win);
            bool searchable = _search_target != null;
            _tabs.visible = rows.length > 0 || searchable;
            _search_tab = null;
            if (searchable) {
                _search_tab = new Button();
                var sbox = new Box(Orientation.HORIZONTAL, 8);
                sbox.append(new Image.from_icon_name("system-search-symbolic"));
                sbox.append(new Label(_("Search")));
                _search_tab.child = sbox;
                _search_tab.add_css_class("tv-app-tab");
                _search_tab.add_css_class("tv-app-search");
                _search_tab.clicked.connect(() => open_tv_search());
            }
            Box? more_box = null;
            for (int i = 0; i < rows.length; i++) {
                var row = rows[i];
                var tab = new Button.with_label(row.text);
                tab.add_css_class("tv-app-tab");
                sync_tab(tab, row);
                row.notify["css-classes"].connect(() => sync_tab(tab, row));
                tab.clicked.connect(() => row.clicked());
                if (i < TV_MAX_TABS - 1 || rows.length <= TV_MAX_TABS) {
                    _tabs.append(tab);
                    continue;
                }
                if (more_box == null) {
                    more_box = new Box(Orientation.VERTICAL, 4);
                    var pop = new Popover();
                    pop.child = more_box;
                    var more = new MenuButton();
                    more.label = _("More");
                    more.popover = pop;
                    more.add_css_class("tv-app-tab");
                    _tabs.append(more);
                }
                tab.clicked.connect(() => {
                    var pop = more_box.get_ancestor(typeof(Popover)) as Popover;
                    if (pop != null) pop.popdown();
                });
                more_box.append(tab);
            }
            if (_search_tab != null) _tabs.append(_search_tab);
            if (_search_entry == null && _head != null) {
                _search_entry = new Gtk.SearchEntry();
                _search_entry.add_css_class("tv-app-search-entry");
                _search_entry.hexpand = true;
                _search_entry.visible = false;
                _search_entry.search_changed.connect(() => {
                    if (_search_target != null) _search_target.text = _search_entry.text;
                });
                _search_entry.stop_search.connect(() => close_tv_search());
                _head.append(_search_entry);
            }
            if (_search_entry != null && _search_target != null) _search_entry.placeholder_text = _search_target.placeholder;
        }

        private static SearchBubble? find_search(Widget root) {
            if (root is SearchBubble) return (SearchBubble) root;
            for (var c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
                var found = find_search(c);
                if (found != null) return found;
            }
            return null;
        }

        private void open_tv_search() {
            if (_search_entry == null || _search_target == null) return;
            _search_entry.text = _search_target.text;
            _search_entry.visible = true;
            if (_search_tab != null) _search_tab.visible = false;
            _search_entry.grab_focus();
        }

        private bool close_tv_search() {
            if (_search_entry == null || !_search_entry.visible) return false;
            _search_entry.visible = false;
            _search_entry.text = "";
            if (_search_target != null) _search_target.text = "";
            if (_search_tab != null) {
                _search_tab.visible = true;
                _search_tab.grab_focus();
            }
            return true;
        }

        private static void sync_tab(Button tab, SidebarRow row) {
            if (row.has_css_class("sidebar-nav-active")) tab.add_css_class("active");
            else tab.remove_css_class("active");
        }

        private void focus_start(bool force = false) {
            var current = _win.get_focus();
            if (!force && current != null && is_candidate(current) && !in_head(current) && !in_chrome(current)) return;
            var all = new GenericArray<Widget>();
            collect_focusable(_win, ref all);
            Widget? best = null;
            Graphene.Rect best_rect = Graphene.Rect.zero();
            foreach (var w in all) {
                if (in_head(w) || in_chrome(w)) continue;
                Graphene.Rect b;
                if (!w.compute_bounds(_win, out b)) continue;
                bool primary = w.has_css_class("suggested-action");
                if (best != null && !primary) {
                    if (best.has_css_class("suggested-action")) continue;
                    if (b.origin.y > best_rect.origin.y + 4) continue;
                    if (Math.fabsf(b.origin.y - best_rect.origin.y) <= 4 && b.origin.x >= best_rect.origin.x) continue;
                }
                best = w;
                best_rect = b;
                if (primary) break;
            }
            if (best == null && force && !_user_moved && _start_tries < 20) {
                _start_tries++;
                Timeout.add(500, () => {
                    if (!_user_moved && kind == FormFactorKind.TV && !compat) focus_start(true);
                    return Source.REMOVE;
                });
                return;
            }
            if (best == null && all.length > 0) best = all[0];
            if (best == null) return;
            best.grab_focus();
            _win.focus_visible = true;
        }

        private static bool in_chrome(Widget w) {
            if (w.has_css_class("singularity-hover-btn")) return true;
            return w.get_ancestor(typeof(SearchBubble)) != null;
        }

        private bool in_head(Widget w) {
            return _head != null && w.is_ancestor(_head);
        }

        private bool is_candidate(Widget w) {
            if (!w.get_mapped() || !w.focusable || !w.can_focus || !w.is_sensitive()) return false;
            if (w is Window || w is Label) return false;
            Graphene.Rect r;
            if (!w.compute_bounds(_win, out r)) return false;
            return r.size.width > 1 && r.size.height > 1;
        }

        private static bool is_target(Widget w) {
            return w is Button || w is MenuButton || w is ListBoxRow || w is FlowBoxChild || w is Editable
                || w is Switch || w is CheckButton || w is Scale || w is DropDown || w.get_parent() is GridView
                || w.get_parent() is ListView;
        }

        private void collect_focusable(Widget root, ref GenericArray<Widget> out_list) {
            for (var c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
                if (!c.get_mapped() || !c.can_focus) continue;
                int before = out_list.length;
                collect_focusable(c, ref out_list);
                if (!is_candidate(c)) continue;
                if (out_list.length > before && !is_target(c)) continue;
                out_list.insert(before, c);
            }
        }

        private bool on_key(uint keyval, uint keycode, Gdk.ModifierType state) {
            var held = Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK;
            if ((state & held) != 0) return false;
            if (compat) return pointer_key(keyval);
            if (keyval == Gdk.Key.Up || keyval == Gdk.Key.Down || keyval == Gdk.Key.Left || keyval == Gdk.Key.Right) {
                _win.focus_visible = true;
                _user_moved = true;
            }
            var focus = _win.get_focus();
            Editable? editable = focus as Editable;
            if (editable == null && focus != null) editable = focus.get_ancestor(typeof(Editable)) as Editable;
            bool editing = editable != null;
            bool at_start = editing && editable.get_position() <= 0;
            bool at_end = editing && editable.get_position() >= editable.get_text().char_count();
            if (editing && _text_keys.key(_win, keyval)) return true;
            bool custom = focus != null && !editing && !is_target(focus) && !in_head(focus) && !in_chrome(focus) && is_candidate(focus);
            if (custom && (keyval == Gdk.Key.Up || keyval == Gdk.Key.Down || keyval == Gdk.Key.Left || keyval == Gdk.Key.Right)) return false;
            switch (keyval) {
                case Gdk.Key.Up:
                    return move(0, -1);
                case Gdk.Key.Down:
                    return move(0, 1);
                case Gdk.Key.Left:
                    return editing && !at_start ? false : move(-1, 0);
                case Gdk.Key.Right:
                    return editing && !at_end ? false : move(1, 0);
                case Gdk.Key.Escape:
                    return go_back();
                case Gdk.Key.BackSpace:
                    return editing ? false : go_back();
                case Gdk.Key.Menu:
                    return _win.popup_app_menu();
                case Gdk.Key.Return:
                case Gdk.Key.KP_Enter:
                    return editing ? false : ok_down(focus);
                default:
                    return false;
            }
        }

        private bool ok_down(Widget? focus) {
            if (_ok_target != null) return true;
            if (focus == null || !(focus is Button || focus is ListBoxRow || focus is FlowBoxChild)) return false;
            _ok_target = focus;
            _ok_long = false;
            _ok_source = Timeout.add(600, () => {
                _ok_source = 0;
                _ok_long = true;
                if (_ok_target != null && !_ok_target.activate_action("menu.popup", null)) _win.popup_app_menu();
                return Source.REMOVE;
            });
            return true;
        }

        private void on_key_up(uint keyval, uint keycode, Gdk.ModifierType state) {
            if (keyval != Gdk.Key.Return && keyval != Gdk.Key.KP_Enter) return;
            var target = _ok_target;
            _ok_target = null;
            if (_ok_source != 0) {
                Source.remove(_ok_source);
                _ok_source = 0;
            }
            if (target == null || _ok_long || !target.get_mapped()) return;
            bool content = !in_head(target) && !in_chrome(target);
            if (content) {
                _origins.add(target);
                if (_origins.length > 16) _origins.remove_index(0);
            }
            target.activate();
            if (content) {
                Timeout.add(300, () => {
                    if (kind == FormFactorKind.TV && !compat) focus_start();
                    return Source.REMOVE;
                });
            }
        }

        private bool move(int dx, int dy) {
            var focus = _win.get_focus();
            var all = new GenericArray<Widget>();
            collect_focusable(_win, ref all);
            if (focus == null || !is_candidate(focus)) {
                focus_start();
                return true;
            }
            Graphene.Rect a;
            focus.compute_bounds(_win, out a);
            float acx = a.origin.x + a.size.width / 2;
            float acy = a.origin.y + a.size.height / 2;
            Widget? best = null;
            float best_score = float.MAX;
            bool from_head = in_head(focus);
            foreach (var w in all) {
                if (w == focus || focus.is_ancestor(w) || w.is_ancestor(focus)) continue;
                if (from_head && dy > 0 && in_chrome(w)) continue;
                Graphene.Rect b;
                w.compute_bounds(_win, out b);
                float bcx = b.origin.x + b.size.width / 2;
                float bcy = b.origin.y + b.size.height / 2;
                float along, across;
                if (dx != 0) {
                    float edge = dx > 0 ? b.origin.x - (a.origin.x + a.size.width) : a.origin.x - (b.origin.x + b.size.width);
                    if ((bcx - acx) * dx <= 1) continue;
                    along = float.max(edge, 0);
                    float overlap = float.min(a.origin.y + a.size.height, b.origin.y + b.size.height) - float.max(a.origin.y, b.origin.y);
                    if (overlap <= 0) continue;
                    across = 0;
                } else {
                    float edge = dy > 0 ? b.origin.y - (a.origin.y + a.size.height) : a.origin.y - (b.origin.y + b.size.height);
                    if ((bcy - acy) * dy <= 1) continue;
                    along = float.max(edge, 0);
                    float overlap = float.min(a.origin.x + a.size.width, b.origin.x + b.size.width) - float.max(a.origin.x, b.origin.x);
                    across = overlap > 0 ? Math.fabsf(bcx - acx) * 0.2f : Math.fabsf(bcx - acx);
                }
                float score = along + across * 2;
                if (score < best_score) {
                    best_score = score;
                    best = w;
                }
            }
            if (best != null) best.grab_focus();
            return true;
        }

        private static bool in_controls(Widget w) {
            for (Widget? p = w.get_parent(); p != null; p = p.get_parent()) {
                if (p.has_css_class("singularity-hover-controls")) return true;
            }
            return false;
        }

        private static Button? find_back(Widget root, bool controls) {
            for (var c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
                var b = c as Button;
                if (b != null && b.is_sensitive() && b.icon_name == "go-previous-symbolic") {
                    if (controls ? b.visible && in_controls(b) : b.get_mapped()) return b;
                }
                var deep = find_back(c, controls);
                if (deep != null) return deep;
            }
            return null;
        }

        private bool go_back() {
            if (close_tv_search()) return true;
            var back = find_back(_win, true) ?? find_back(_win, false);
            if (back != null) {
                back.clicked();
                Idle.add(() => {
                    if (!return_to_origin()) focus_start();
                    return Source.REMOVE;
                });
                return true;
            }
            var focus = _win.get_focus();
            if (_tabs != null && _tabs.visible && (focus == null || !in_head(focus))) {
                for (var c = _tabs.get_first_child(); c != null; c = c.get_next_sibling()) {
                    if (c.has_css_class("active")) {
                        c.grab_focus();
                        return true;
                    }
                }
                var first = _tabs.get_first_child();
                if (first != null) {
                    first.grab_focus();
                    return true;
                }
            }
            _win.minimize();
            return true;
        }

        private bool return_to_origin() {
            while (_origins.length > 0) {
                var w = _origins[_origins.length - 1];
                _origins.remove_index(_origins.length - 1);
                if (is_candidate(w) && !in_head(w) && !in_chrome(w)) {
                    w.grab_focus();
                    return true;
                }
            }
            return false;
        }

        private void show_pointer() {
            if (_pointer_layer != null || _win.root_overlay == null) return;
            _pointer_layer = new Fixed();
            _pointer_layer.can_target = false;
            _pointer = new Box(Orientation.VERTICAL, 0);
            _pointer.add_css_class("tv-pointer");
            _pointer.set_size_request(POINTER_SIZE, POINTER_SIZE);
            _pointer_layer.put(_pointer, _px, _py);
            _win.root_overlay.add_overlay(_pointer_layer);
            place_pointer();
        }

        private void hide_pointer() {
            if (_pointer_layer == null) return;
            _win.root_overlay.remove_overlay(_pointer_layer);
            _pointer_layer = null;
            _pointer = null;
        }

        private void place_pointer() {
            int w = _win.root_overlay.get_width();
            int h = _win.root_overlay.get_height();
            if (w > 0) _px = _px.clamp(0, w - 1);
            if (h > 0) _py = _py.clamp(0, h - 1);
            _pointer_layer.move(_pointer, _px - POINTER_SIZE / 2, _py - POINTER_SIZE / 2);
        }

        private bool pointer_key(uint keyval) {
            int dx = 0, dy = 0;
            switch (keyval) {
                case Gdk.Key.Up: dy = -1; break;
                case Gdk.Key.Down: dy = 1; break;
                case Gdk.Key.Left: dx = -1; break;
                case Gdk.Key.Right: dx = 1; break;
                case Gdk.Key.Return:
                case Gdk.Key.KP_Enter:
                    click_at_pointer();
                    return true;
                case Gdk.Key.Escape:
                    _win.minimize();
                    return true;
                default:
                    _step = POINTER_STEP;
                    return false;
            }
            int64 now = get_monotonic_time();
            if (now - _last_press > 250000) _step = POINTER_STEP;
            _last_press = now;
            _px += dx * _step;
            _py += dy * _step;
            _step = int.min(_step + 12, POINTER_STEP_MAX);
            place_pointer();
            return true;
        }

        private void click_at_pointer() {
            _step = POINTER_STEP;
            Graphene.Point p = { _px, _py };
            Graphene.Point q;
            if (!_win.root_overlay.compute_point(_win, p, out q)) return;
            var hit = _win.pick(q.x, q.y, PickFlags.DEFAULT);
            for (var w = hit; w != null; w = w.get_parent()) {
                var button = w as Button;
                if (button != null) {
                    button.clicked();
                    return;
                }
                var mbutton = w as MenuButton;
                if (mbutton != null) {
                    mbutton.popup();
                    return;
                }
                var row = w as ListBoxRow;
                if (row != null) {
                    row.activate();
                    return;
                }
                var child = w as FlowBoxChild;
                if (child != null) {
                    child.activate();
                    return;
                }
                var check = w as CheckButton;
                if (check != null) {
                    check.active = !check.active;
                    return;
                }
                var sw = w as Switch;
                if (sw != null) {
                    sw.active = !sw.active;
                    return;
                }
                if (w.focusable) {
                    w.grab_focus();
                    return;
                }
            }
        }
    }
}
