using Gtk;

namespace Singularity.Widgets {

    public class ChoiceButton : Button {
        private const int SCROLL_AFTER = 12;
        private const int MAX_MENU_HEIGHT = 360;

        private Label value_label;
        private ListModel? _model = null;
        private uint _selected = INVALID_LIST_POSITION;
        private ulong items_handler = 0;

        public Gtk.Expression? expression { get; set; }
        public bool enable_search { get; set; default = false; }

        public ListModel? model {
            get { return _model; }
            set {
                if (_model != null && items_handler != 0) _model.disconnect(items_handler);
                items_handler = 0;
                _model = value;
                if (_model != null) items_handler = _model.items_changed.connect(on_items_changed);
                uint n = _model != null ? _model.get_n_items() : 0;
                _selected = INVALID_LIST_POSITION;
                apply_selected(n > 0 ? 0 : INVALID_LIST_POSITION, true);
            }
        }

        [CCode (notify = false)]
        public uint selected {
            get { return _selected; }
            set { apply_selected(value, false); }
        }

        public Object? selected_item {
            owned get {
                if (_model == null || _selected == INVALID_LIST_POSITION) return null;
                return _model.get_item(_selected);
            }
        }

        public ChoiceButton(ListModel? model = null, owned Gtk.Expression? expression = null) {
            Object();
            this.expression = expression;
            add_css_class("choice-button");
            value_label = new Label("");
            value_label.xalign = 0;
            value_label.hexpand = true;
            value_label.ellipsize = Pango.EllipsizeMode.END;
            var box = new Box(Orientation.HORIZONTAL, 6);
            box.append(value_label);
            box.append(new Image.from_icon_name("pan-down-symbolic"));
            set_child(box);
            clicked.connect(show_menu);
            this.model = model;
            notify["expression"].connect(update_label);
        }

        public ChoiceButton.from_strings(string[] strings) {
            this(new StringList(strings), null);
        }

        private void apply_selected(uint value, bool force) {
            uint n = _model != null ? _model.get_n_items() : 0;
            uint next = value < n ? value : INVALID_LIST_POSITION;
            if (next == _selected && !force) return;
            _selected = next;
            update_label();
            notify_property("selected");
            notify_property("selected-item");
        }

        private void on_items_changed(uint position, uint removed, uint added) {
            uint n = _model.get_n_items();
            if (_selected == INVALID_LIST_POSITION) {
                if (n > 0) apply_selected(0, false);
                return;
            }
            if (_selected >= position && _selected < position + removed) {
                apply_selected(n > 0 ? uint.min(position, n - 1) : INVALID_LIST_POSITION, true);
                return;
            }
            if (_selected >= position + removed) {
                _selected = _selected - removed + added;
                notify_property("selected");
            }
            update_label();
        }

        private string item_label(Object? item) {
            if (item == null) return "";
            if (expression != null) {
                var value = Value(typeof(string));
                if (expression.evaluate(item, ref value)) return value.get_string() ?? "";
            }
            if (item is StringObject) return ((StringObject) item).string;
            return "";
        }

        private void update_label() {
            if (value_label == null) return;
            value_label.label = item_label(selected_item);
        }

        private void show_menu() {
            if (_model == null || _model.get_n_items() == 0) return;
            var menu = new ContextMenu(this);
            unowned ContextMenu weak_menu = menu;
            var list = new Box(Orientation.VERTICAL, 0);
            var rows = new Gee.ArrayList<MenuRow>();
            MenuRow? current = null;
            uint n = _model.get_n_items();
            for (uint i = 0; i < n; i++) {
                uint index = i;
                var row = new MenuRow(item_label(_model.get_item(i)), "object-select-symbolic");
                row.halign = Align.FILL;
                row.add_css_class("check-row");
                if (i == _selected) {
                    row.add_css_class("checked");
                    current = row;
                }
                row.clicked.connect(() => {
                    weak_menu.popdown();
                    selected = index;
                });
                list.append(row);
                rows.add(row);
            }
            if (enable_search) {
                var search = new Gtk.SearchEntry();
                search.margin_bottom = 4;
                search.search_changed.connect(() => {
                    string needle = search.text.casefold();
                    foreach (var row in rows) row.visible = needle == "" || row.label_text.casefold().contains(needle);
                });
                menu.add_widget(search);
            }
            if (n > SCROLL_AFTER) {
                var scroller = new ScrolledWindow();
                scroller.hscrollbar_policy = PolicyType.NEVER;
                scroller.propagate_natural_height = true;
                scroller.propagate_natural_width = true;
                scroller.max_content_height = MAX_MENU_HEIGHT;
                scroller.child = list;
                menu.add_widget(scroller);
            } else {
                menu.add_widget(list);
            }
            menu.closed.connect(() => Idle.add(() => {
                weak_menu.unparent();
                return Source.REMOVE;
            }));
            menu.popup();
            if (current != null && !enable_search) current.grab_focus();
        }
    }
}
