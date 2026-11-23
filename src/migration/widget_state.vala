namespace Singularity.Migration {

    [CCode (cname = "singularity_migration_text_history_available", cheader_filename = "migration/text_history.h")]
    internal extern bool text_history_available();
    [CCode (cname = "singularity_migration_save_buffer_history", cheader_filename = "migration/text_history.h")]
    internal extern Variant? save_buffer_history(Gtk.TextBuffer buffer);
    [CCode (cname = "singularity_migration_restore_buffer_history", cheader_filename = "migration/text_history.h")]
    internal extern bool restore_buffer_history(Gtk.TextBuffer buffer, Variant history);
    [CCode (cname = "singularity_migration_save_text_history", cheader_filename = "migration/text_history.h")]
    internal extern Variant? save_text_history(Gtk.Text text);
    [CCode (cname = "singularity_migration_restore_text_history", cheader_filename = "migration/text_history.h")]
    internal extern bool restore_text_history(Gtk.Text text, Variant history);

    public interface Stateful : Gtk.Widget {
        public abstract Variant? save_widget_state();
        public abstract void restore_widget_state(Variant state);
    }

    public class WidgetState : Object {
        public const string TYPE = "a{sa{sv}}";

        private Gee.ArrayList<string> missing_paths = new Gee.ArrayList<string>();
        private Gee.ArrayList<string> unsupported_paths = new Gee.ArrayList<string>();
        private Gee.HashMap<Gtk.ScrolledWindow, Variant> pending_scroll = new Gee.HashMap<Gtk.ScrolledWindow, Variant>();
        private Gee.ArrayList<Gtk.Popover> pending_popovers = new Gee.ArrayList<Gtk.Popover>();
        private Gee.HashSet<Gtk.TextBuffer> seen_buffers = new Gee.HashSet<Gtk.TextBuffer>();

        public string[] missing {
            owned get { return missing_paths.to_array(); }
        }

        public string[] unsupported {
            owned get { return unsupported_paths.to_array(); }
        }

        public static string segment(Gtk.Widget widget) {
            string type = widget.get_type().name();
            string name = widget.get_name();
            bool named = name != null && name != "" && name != type;
            int index = 0;
            for (var s = widget.get_prev_sibling(); s != null; s = s.get_prev_sibling()) {
                if (named ? s.get_name() == name : (s.get_type() == widget.get_type() && !own_name(s))) index++;
            }
            return named ? "@%s#%d".printf(name, index) : "%s#%d".printf(type, index);
        }

        private static bool own_name(Gtk.Widget w) {
            string n = w.get_name();
            return n != null && n != "" && n != w.get_type().name();
        }

        private static bool virtual_rows(Gtk.Widget widget) {
            return widget is Gtk.ListView || widget is Gtk.GridView || widget is Gtk.ColumnView;
        }

        public static string? path_of(Gtk.Widget root, Gtk.Widget? widget) {
            if (widget == null) return null;
            string[] parts = {};
            for (Gtk.Widget? w = widget; w != null && w != root; w = w.get_parent()) parts += segment(w);
            string path = "";
            for (int i = parts.length - 1; i >= 0; i--) path += "/" + parts[i];
            return path == "" ? "/" : path;
        }

        public Variant capture(Gtk.Window window) {
            var all = new VariantBuilder(new VariantType(TYPE));
            seen_buffers.clear();
            walk(window, "", (widget, path) => {
                var dict = new VariantDict();
                if (capture_widget(widget, dict, path)) all.add("{s@a{sv}}", path, dict.end());
            });
            return all.end();
        }

        private delegate void Visit(Gtk.Widget widget, string path);

        private void walk(Gtk.Widget widget, string path, Visit visit) {
            visit(widget, path == "" ? "/" : path);
            if (virtual_rows(widget)) return;
            for (var child = widget.get_first_child(); child != null; child = child.get_next_sibling()) {
                walk(child, path + "/" + segment(child), visit);
            }
        }

        private bool capture_widget(Gtk.Widget widget, VariantDict d, string path) {
            bool any = false;
            if (widget is Stateful) {
                var s = ((Stateful) widget).save_widget_state();
                if (s != null) {
                    d.insert_value("stateful", s);
                    any = true;
                }
            }
            if (widget is Gtk.Window) {
                var w = (Gtk.Window) widget;
                int dw, dh;
                w.get_default_size(out dw, out dh);
                d.insert_value("width", new Variant.int32(w.get_width() > 0 ? w.get_width() : dw));
                d.insert_value("height", new Variant.int32(w.get_height() > 0 ? w.get_height() : dh));
                d.insert_value("maximized", new Variant.boolean(w.maximized));
                d.insert_value("fullscreened", new Variant.boolean(w.fullscreened));
                d.insert_value("focus-visible", new Variant.boolean(w.focus_visible));
                string? focus = path_of(w, w.get_focus());
                if (focus != null) d.insert_value("focus", new Variant.string(focus));
                any = true;
            }
            if (widget is Gtk.TextView && !(widget is Stateful)) {
                var buffer = ((Gtk.TextView) widget).buffer;
                if (seen_buffers.add(buffer)) any |= capture_buffer(buffer, d, path);
            } else if (widget is Gtk.Text) {
                var t = (Gtk.Text) widget;
                int start, end;
                bool selected = t.get_selection_bounds(out start, out end);
                d.insert_value("text", new Variant.string(t.get_text()));
                d.insert_value("position", new Variant.int32(t.get_position()));
                d.insert_value("selection", new Variant("(bii)", selected, start, end));
                if (t.enable_undo) {
                    var history = save_text_history(t);
                    if (history != null) d.insert_value("history", history);
                    else unsupported_paths.add(path);
                }
                any = true;
            }
            if (widget is Gtk.ScrolledWindow) {
                var sw = (Gtk.ScrolledWindow) widget;
                d.insert_value("scroll", new Variant("(dd)", sw.hadjustment.value, sw.vadjustment.value));
                any = true;
            } else if (widget is Gtk.Range && widget.get_ancestor(typeof(Gtk.Scrollbar)) == null) {
                d.insert_value("value", new Variant.double(((Gtk.Range) widget).get_value()));
                any = true;
            }
            if (widget is Gtk.SpinButton) {
                d.insert_value("value", new Variant.double(((Gtk.SpinButton) widget).value));
                any = true;
            }
            if (widget is Gtk.CheckButton) {
                d.insert_value("active", new Variant.boolean(((Gtk.CheckButton) widget).active));
                any = true;
            } else if (widget is Gtk.ToggleButton) {
                d.insert_value("active", new Variant.boolean(((Gtk.ToggleButton) widget).active));
                any = true;
            } else if (widget is Gtk.Switch) {
                d.insert_value("active", new Variant.boolean(((Gtk.Switch) widget).active));
                any = true;
            }
            if (widget is Gtk.DropDown) {
                d.insert_value("selected", new Variant.uint32(((Gtk.DropDown) widget).selected));
                any = true;
            }
            if (widget is Gtk.Stack) {
                var st = (Gtk.Stack) widget;
                if (st.visible_child_name != null) d.insert_value("child", new Variant.string(st.visible_child_name));
                any = true;
            }
            if (widget is Gtk.Notebook) {
                d.insert_value("page", new Variant.int32(((Gtk.Notebook) widget).page));
                any = true;
            }
            if (widget is Gtk.Paned) {
                d.insert_value("position", new Variant.int32(((Gtk.Paned) widget).position));
                any = true;
            }
            if (widget is Gtk.Expander) {
                d.insert_value("expanded", new Variant.boolean(((Gtk.Expander) widget).expanded));
                any = true;
            }
            if (widget is Gtk.Revealer) {
                d.insert_value("reveal", new Variant.boolean(((Gtk.Revealer) widget).reveal_child));
                any = true;
            }
            if (widget is Gtk.SearchBar) {
                d.insert_value("search", new Variant.boolean(((Gtk.SearchBar) widget).search_mode_enabled));
                any = true;
            }
            if (widget is Gtk.Popover) {
                d.insert_value("open", new Variant.boolean(widget.visible));
                any = true;
            }
            if (widget is Gtk.Calendar) {
                var date = ((Gtk.Calendar) widget).get_date();
                d.insert_value("date", new Variant("(iii)", date.get_year(), date.get_month(), date.get_day_of_month()));
                any = true;
            }
            if (widget is Gtk.Video) {
                var stream = ((Gtk.Video) widget).media_stream;
                if (stream != null) {
                    d.insert_value("media", new Variant("(xbdb)", stream.timestamp, stream.playing, stream.volume, stream.muted));
                    any = true;
                }
            }
            if (widget is Gtk.ListBox) {
                d.insert_value("rows", selected_rows((Gtk.ListBox) widget));
                any = true;
            } else if (widget is Gtk.FlowBox) {
                d.insert_value("rows", selected_children((Gtk.FlowBox) widget));
                any = true;
            }
            Gtk.SelectionModel? model = selection_model(widget);
            if (model != null) {
                d.insert_value("selection", capture_selection(model));
                any = true;
            }
            if (widget is Gtk.ColumnView) {
                d.insert_value("columns", capture_columns((Gtk.ColumnView) widget));
                any = true;
            }
            return any;
        }

        private bool capture_buffer(Gtk.TextBuffer buffer, VariantDict d, string path) {
            Gtk.TextIter start, end, insert, bound;
            buffer.get_bounds(out start, out end);
            buffer.get_iter_at_mark(out insert, buffer.get_insert());
            buffer.get_iter_at_mark(out bound, buffer.get_selection_bound());
            d.insert_value("text", new Variant.string(buffer.get_text(start, end, true)));
            d.insert_value("cursor", new Variant("(ii)", insert.get_offset(), bound.get_offset()));
            d.insert_value("modified", new Variant.boolean(buffer.get_modified()));
            d.insert_value("tags", capture_tags(buffer));
            if (buffer.enable_undo) {
                var history = save_buffer_history(buffer);
                if (history != null) d.insert_value("history", history);
                else unsupported_paths.add(path);
            }
            return true;
        }

        private static Variant capture_tags(Gtk.TextBuffer buffer) {
            var tags = new VariantBuilder(new VariantType("a(sii)"));
            var named = new Gee.ArrayList<Gtk.TextTag>();
            buffer.tag_table.foreach((tag) => {
                if (tag.name != null) named.add(tag);
            });
            named.sort((a, b) => strcmp(a.name, b.name));
            foreach (var tag in named) {
                Gtk.TextIter iter;
                buffer.get_start_iter(out iter);
                if (!iter.starts_tag(tag) && !iter.forward_to_tag_toggle(tag)) continue;
                while (true) {
                    if (!iter.starts_tag(tag)) {
                        if (!iter.forward_to_tag_toggle(tag)) break;
                        continue;
                    }
                    int from = iter.get_offset();
                    if (!iter.forward_to_tag_toggle(tag)) {
                        Gtk.TextIter last;
                        buffer.get_end_iter(out last);
                        tags.add("(sii)", tag.name, from, last.get_offset());
                        break;
                    }
                    tags.add("(sii)", tag.name, from, iter.get_offset());
                }
            }
            return tags.end();
        }

        private static Gtk.SelectionModel? selection_model(Gtk.Widget widget) {
            if (widget is Gtk.ListView) return ((Gtk.ListView) widget).model;
            if (widget is Gtk.GridView) return ((Gtk.GridView) widget).model;
            if (widget is Gtk.ColumnView) return ((Gtk.ColumnView) widget).model;
            return null;
        }

        private static Variant capture_selection(Gtk.SelectionModel model) {
            var positions = new VariantBuilder(new VariantType("au"));
            var chosen = model.get_selection();
            uint n = (uint) chosen.get_size();
            for (uint i = 0; i < n; i++) positions.add("u", chosen.get_nth(i));
            return new Variant.tuple({ new Variant.uint32(model.get_n_items()), positions.end() });
        }

        private static Variant capture_columns(Gtk.ColumnView view) {
            var order = new VariantBuilder(new VariantType("a(sbi)"));
            var columns = view.columns;
            for (uint i = 0; i < columns.get_n_items(); i++) {
                var c = (Gtk.ColumnViewColumn) columns.get_item(i);
                order.add("(sbi)", c.id ?? c.title ?? "", c.visible, c.fixed_width);
            }
            string sort_id = "";
            int sort_order = 0;
            var sorter = view.sorter as Gtk.ColumnViewSorter;
            if (sorter != null && sorter.primary_sort_column != null) {
                sort_id = sorter.primary_sort_column.id ?? sorter.primary_sort_column.title ?? "";
                sort_order = (int) sorter.primary_sort_order;
            }
            return new Variant.tuple({ order.end(), new Variant.string(sort_id), new Variant.int32(sort_order) });
        }

        private static Variant selected_rows(Gtk.ListBox box) {
            var rows = new VariantBuilder(new VariantType("ai"));
            foreach (var row in box.get_selected_rows()) rows.add("i", row.get_index());
            return rows.end();
        }

        private static Variant selected_children(Gtk.FlowBox box) {
            var rows = new VariantBuilder(new VariantType("ai"));
            foreach (var child in box.get_selected_children()) rows.add("i", child.get_index());
            return rows.end();
        }

        public void apply(Gtk.Window window, Variant state) {
            missing_paths.clear();
            var wanted = new Gee.HashMap<string, Variant>();
            var iter = state.iterator();
            string path;
            Variant dict;
            while (iter.next("{s@a{sv}}", out path, out dict)) wanted[path] = dict;
            var found = new Gee.HashSet<string>();
            string? focus = null;
            Variant? focus_visible = null;
            walk(window, "", (widget, p) => {
                var d = wanted[p];
                if (d == null) return;
                found.add(p);
                var lookup = new VariantDict(d);
                if (widget is Gtk.Window) {
                    var f = lookup.lookup_value("focus", VariantType.STRING);
                    if (f != null) focus = f.get_string();
                    focus_visible = lookup.lookup_value("focus-visible", VariantType.BOOLEAN);
                }
                apply_widget(widget, lookup);
            });
            foreach (var p in wanted.keys) {
                if (!found.contains(p)) missing_paths.add(p);
            }
            if (focus != null) {
                walk(window, "", (widget, p) => {
                    if (p == focus) widget.grab_focus();
                });
            }
            if (focus_visible != null) window.focus_visible = focus_visible.get_boolean();
        }

        public bool settle() {
            bool done = true;
            foreach (var entry in pending_scroll.entries.to_array()) {
                double h, v;
                entry.value.get("(dd)", out h, out v);
                var sw = entry.key;
                bool ok = reach(sw.hadjustment, h) & reach(sw.vadjustment, v);
                if (ok) pending_scroll.unset(entry.key);
                else done = false;
            }
            if (done) {
                foreach (var p in pending_popovers) p.popup();
                pending_popovers.clear();
            }
            return done;
        }

        private static bool reach(Gtk.Adjustment a, double value) {
            if (value > a.upper - a.page_size + 0.5 && a.upper > 0) {
                a.value = a.upper - a.page_size;
                return false;
            }
            a.value = value;
            return Math.fabs(a.value - value) < 0.5;
        }

        private void apply_widget(Gtk.Widget widget, VariantDict d) {
            Variant? v;
            if (widget is Gtk.Window) {
                var w = (Gtk.Window) widget;
                int width = (int) (d.lookup_value("width", VariantType.INT32) ?? new Variant.int32(-1)).get_int32();
                int height = (int) (d.lookup_value("height", VariantType.INT32) ?? new Variant.int32(-1)).get_int32();
                if (width > 0 && height > 0) w.set_default_size(width, height);
                v = d.lookup_value("maximized", VariantType.BOOLEAN);
                if (v != null && v.get_boolean()) w.maximize();
                v = d.lookup_value("fullscreened", VariantType.BOOLEAN);
                if (v != null && v.get_boolean()) w.fullscreen();
            }
            if (widget is Gtk.TextView && !(widget is Stateful)) {
                apply_buffer(((Gtk.TextView) widget).buffer, d);
            } else if (widget is Gtk.Text) {
                var t = (Gtk.Text) widget;
                v = d.lookup_value("text", VariantType.STRING);
                if (v != null && t.get_text() != v.get_string()) t.set_text(v.get_string());
                v = d.lookup_value("history", null);
                if (v != null) restore_text_history(t, v);
                v = d.lookup_value("selection", new VariantType("(bii)"));
                bool selected = false;
                int start = 0, end = 0;
                if (v != null) v.get("(bii)", out selected, out start, out end);
                v = d.lookup_value("position", VariantType.INT32);
                if (selected) t.select_region(start, end);
                else if (v != null) t.set_position(v.get_int32());
            }
            v = d.lookup_value("scroll", new VariantType("(dd)"));
            if (v != null && widget is Gtk.ScrolledWindow) pending_scroll[(Gtk.ScrolledWindow) widget] = v;
            v = d.lookup_value("value", VariantType.DOUBLE);
            if (v != null) {
                if (widget is Gtk.SpinButton) ((Gtk.SpinButton) widget).value = v.get_double();
                else if (widget is Gtk.Range && widget.get_ancestor(typeof(Gtk.Scrollbar)) == null) ((Gtk.Range) widget).set_value(v.get_double());
            }
            v = d.lookup_value("active", VariantType.BOOLEAN);
            if (v != null) {
                if (widget is Gtk.CheckButton) ((Gtk.CheckButton) widget).active = v.get_boolean();
                else if (widget is Gtk.ToggleButton) ((Gtk.ToggleButton) widget).active = v.get_boolean();
                else if (widget is Gtk.Switch) ((Gtk.Switch) widget).active = v.get_boolean();
            }
            v = d.lookup_value("selected", VariantType.UINT32);
            if (v != null && widget is Gtk.DropDown) ((Gtk.DropDown) widget).selected = v.get_uint32();
            v = d.lookup_value("child", VariantType.STRING);
            if (v != null && widget is Gtk.Stack) {
                var st = (Gtk.Stack) widget;
                if (st.get_child_by_name(v.get_string()) != null) st.set_visible_child_full(v.get_string(), Gtk.StackTransitionType.NONE);
            }
            v = d.lookup_value("page", VariantType.INT32);
            if (v != null && widget is Gtk.Notebook) ((Gtk.Notebook) widget).page = v.get_int32();
            v = d.lookup_value("position", VariantType.INT32);
            if (v != null && widget is Gtk.Paned) ((Gtk.Paned) widget).position = v.get_int32();
            v = d.lookup_value("expanded", VariantType.BOOLEAN);
            if (v != null && widget is Gtk.Expander) ((Gtk.Expander) widget).expanded = v.get_boolean();
            v = d.lookup_value("reveal", VariantType.BOOLEAN);
            if (v != null && widget is Gtk.Revealer) {
                var r = (Gtk.Revealer) widget;
                var kind = r.transition_type;
                r.transition_type = Gtk.RevealerTransitionType.NONE;
                r.reveal_child = v.get_boolean();
                r.transition_type = kind;
            }
            v = d.lookup_value("search", VariantType.BOOLEAN);
            if (v != null && widget is Gtk.SearchBar) ((Gtk.SearchBar) widget).search_mode_enabled = v.get_boolean();
            v = d.lookup_value("open", VariantType.BOOLEAN);
            if (v != null && v.get_boolean() && widget is Gtk.Popover) pending_popovers.add((Gtk.Popover) widget);
            v = d.lookup_value("date", new VariantType("(iii)"));
            if (v != null && widget is Gtk.Calendar) {
                int y, m, day;
                v.get("(iii)", out y, out m, out day);
                ((Gtk.Calendar) widget).select_day(new DateTime.local(y, m, day, 0, 0, 0));
            }
            v = d.lookup_value("media", new VariantType("(xbdb)"));
            if (v != null && widget is Gtk.Video) apply_media(((Gtk.Video) widget).media_stream, v);
            v = d.lookup_value("rows", new VariantType("ai"));
            if (v != null) {
                if (widget is Gtk.ListBox) {
                    var box = (Gtk.ListBox) widget;
                    box.unselect_all();
                    foreach (var i in (int[]) v) {
                        var row = box.get_row_at_index(i);
                        if (row != null) box.select_row(row);
                    }
                } else if (widget is Gtk.FlowBox) {
                    var box = (Gtk.FlowBox) widget;
                    box.unselect_all();
                    foreach (var i in (int[]) v) {
                        var child = box.get_child_at_index(i);
                        if (child != null) box.select_child(child);
                    }
                }
            }
            v = d.lookup_value("columns", new VariantType("(a(sbi)si)"));
            if (v != null && widget is Gtk.ColumnView) apply_columns((Gtk.ColumnView) widget, v);
            v = d.lookup_value("selection", new VariantType("(uau)"));
            Gtk.SelectionModel? model = selection_model(widget);
            if (v != null && model != null) apply_selection(model, v);
            v = d.lookup_value("stateful", null);
            if (v != null && widget is Stateful) ((Stateful) widget).restore_widget_state(v);
        }

        private static void apply_buffer(Gtk.TextBuffer buffer, VariantDict d) {
            var text = d.lookup_value("text", VariantType.STRING);
            if (text != null) {
                Gtk.TextIter start, end;
                buffer.get_bounds(out start, out end);
                if (buffer.get_text(start, end, true) != text.get_string()) {
                    buffer.begin_irreversible_action();
                    buffer.set_text(text.get_string());
                    buffer.end_irreversible_action();
                }
            }
            var tags = d.lookup_value("tags", new VariantType("a(sii)"));
            if (tags != null) {
                Gtk.TextIter start, end;
                buffer.get_bounds(out start, out end);
                var names = new Gee.HashSet<string>();
                var it = tags.iterator();
                string name;
                int from, to;
                while (it.next("(sii)", out name, out from, out to)) names.add(name);
                buffer.tag_table.foreach((tag) => {
                    if (tag.name != null) buffer.remove_tag(tag, start, end);
                });
                it = tags.iterator();
                while (it.next("(sii)", out name, out from, out to)) {
                    if (buffer.tag_table.lookup(name) == null) continue;
                    Gtk.TextIter a, b;
                    buffer.get_iter_at_offset(out a, from);
                    buffer.get_iter_at_offset(out b, to);
                    buffer.apply_tag_by_name(name, a, b);
                }
            }
            var modified = d.lookup_value("modified", VariantType.BOOLEAN);
            if (modified != null) buffer.set_modified(modified.get_boolean());
            var history = d.lookup_value("history", null);
            if (history != null) restore_buffer_history(buffer, history);
            var cursor = d.lookup_value("cursor", new VariantType("(ii)"));
            if (cursor != null) {
                int insert, bound;
                cursor.get("(ii)", out insert, out bound);
                Gtk.TextIter a, b;
                buffer.get_iter_at_offset(out a, insert);
                buffer.get_iter_at_offset(out b, bound);
                buffer.select_range(a, b);
            }
        }

        private static void apply_media(Gtk.MediaStream? stream, Variant v) {
            if (stream == null) return;
            int64 timestamp;
            bool playing, muted;
            double volume;
            v.get("(xbdb)", out timestamp, out playing, out volume, out muted);
            stream.volume = volume;
            stream.muted = muted;
            if (stream.prepared) {
                stream.seek(timestamp);
                stream.playing = playing;
                return;
            }
            ulong id = 0;
            id = stream.notify["prepared"].connect(() => {
                if (!stream.prepared) return;
                stream.disconnect(id);
                stream.seek(timestamp);
                stream.playing = playing;
            });
        }

        private static void apply_selection(Gtk.SelectionModel model, Variant v) {
            uint n;
            VariantIter positions;
            v.get("(uau)", out n, out positions);
            var wanted = new Gtk.Bitset.empty();
            uint p;
            while (positions.next("u", out p)) {
                if (p < model.get_n_items()) wanted.add(p);
            }
            if (model is Gtk.SingleSelection) {
                ((Gtk.SingleSelection) model).selected = wanted.is_empty() ? Gtk.INVALID_LIST_POSITION : wanted.get_minimum();
                return;
            }
            var mask = new Gtk.Bitset.range(0, model.get_n_items());
            model.set_selection(wanted, mask);
        }

        private static void apply_columns(Gtk.ColumnView view, Variant v) {
            VariantIter order;
            string sort_id;
            int sort_order;
            v.get("(a(sbi)si)", out order, out sort_id, out sort_order);
            string id;
            bool visible;
            int width;
            uint position = 0;
            while (order.next("(sbi)", out id, out visible, out width)) {
                var columns = view.columns;
                for (uint i = 0; i < columns.get_n_items(); i++) {
                    var c = (Gtk.ColumnViewColumn) columns.get_item(i);
                    if ((c.id ?? c.title ?? "") != id) continue;
                    c.visible = visible;
                    c.fixed_width = width;
                    if (i != position) view.insert_column(position, c);
                    break;
                }
                position++;
            }
            if (sort_id == "") return;
            var columns = view.columns;
            for (uint i = 0; i < columns.get_n_items(); i++) {
                var c = (Gtk.ColumnViewColumn) columns.get_item(i);
                if ((c.id ?? c.title ?? "") == sort_id) {
                    view.sort_by_column(c, (Gtk.SortType) sort_order);
                    break;
                }
            }
        }
    }
}
