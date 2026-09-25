namespace Singularity.Text {

    /**
     * Turns on spell checking for every text field of an application.
     *
     * Once installed, any Gtk.TextView or Gtk.Entry that takes the keyboard
     * focus in one of the application's windows gets misspelled words
     * underlined, with corrections and "Add to Dictionary" in its context
     * menu. Password, number, email, URL and terminal fields are skipped, as
     * are fields that set Gtk.InputHints.NO_SPELLCHECK and source code views
     * that do not ask for Gtk.InputHints.SPELLCHECK.
     */
    public class SpellIntegration : Object {
        private const string DATA_KEY = "singularity-speller";

        /** Starts spell checking the text fields of `app`. */
        public static void install(Gtk.Application app) {
            app.window_added.connect(watch_window);
            foreach (var window in app.get_windows()) watch_window(window);
        }

        /** Spell checks `widget` now if it is a text field that wants it. */
        public static void attach(Gtk.Widget? widget) {
            if (widget == null || widget.get_data<Object>(DATA_KEY) != null) return;
            if (widget is Gtk.TextView) {
                var view = (Gtk.TextView) widget;
                bool source_view = view.get_type().name().has_prefix("GtkSource")
                    && (view.input_hints & Gtk.InputHints.SPELLCHECK) == 0;
                if (!view.editable || source_view || !wanted(view.input_purpose, view.input_hints)) return;
                widget.set_data<Object>(DATA_KEY, new TextViewSpeller(view));
            } else if (widget is Gtk.Text) {
                var text = (Gtk.Text) widget;
                if (!text.visibility || text.attributes != null
                        || !wanted(text.input_purpose, text.input_hints)) return;
                widget.set_data<Object>(DATA_KEY, new EntrySpeller(text));
            }
        }

        private static void watch_window(Gtk.Window window) {
            window.notify["focus-widget"].connect(() => attach(window.get_focus()));
        }

        internal static bool wanted(Gtk.InputPurpose purpose, Gtk.InputHints hints) {
            if ((hints & Gtk.InputHints.NO_SPELLCHECK) != 0) return false;
            return purpose == Gtk.InputPurpose.FREE_FORM || purpose == Gtk.InputPurpose.ALPHA
                || purpose == Gtk.InputPurpose.NAME;
        }

        internal static bool checkable(string word) {
            if (word.char_count() < 2) return false;
            unichar c;
            int i = 0;
            while (word.get_next_char(ref i, out c)) {
                if (c.isdigit() || c == '_' || c == '@' || c == '/') return false;
            }
            return true;
        }

        internal static GLib.Menu suggestion_menu(string word) {
            var menu = new GLib.Menu();
            foreach (string suggestion in SpellChecker.get_default().suggest(word)) {
                var item = new GLib.MenuItem(suggestion, null);
                item.set_action_and_target_value("spell.replace", new Variant.string(suggestion));
                menu.append_item(item);
            }
            var add = new GLib.MenuItem(_("Add to Dictionary"), null);
            add.set_action_and_target_value("spell.add", new Variant.string(word));
            menu.append_item(add);
            return menu;
        }
    }

    internal class TextViewSpeller : Object {
        private unowned Gtk.TextView view;
        private Gtk.TextTag tag;
        private GLib.Menu section = new GLib.Menu();
        private Gtk.TextMark word_start;
        private Gtk.TextMark word_end;
        private uint recheck_id = 0;

        public TextViewSpeller(Gtk.TextView view) {
            this.view = view;
            var buffer = view.buffer;
            tag = buffer.create_tag(null, "underline", Pango.Underline.ERROR);
            Gtk.TextIter start;
            buffer.get_start_iter(out start);
            word_start = buffer.create_mark(null, start, true);
            word_end = buffer.create_mark(null, start, false);

            var extra = new GLib.Menu();
            extra.append_section(null, section);
            if (view.extra_menu != null) extra.append_section(null, view.extra_menu);
            view.extra_menu = extra;

            var actions = new SimpleActionGroup();
            var replace = new SimpleAction("replace", VariantType.STRING);
            replace.activate.connect((param) => replace_word(param.get_string()));
            actions.add_action(replace);
            var add = new SimpleAction("add", VariantType.STRING);
            add.activate.connect((param) => SpellChecker.get_default().add_to_dictionary(param.get_string()));
            actions.add_action(add);
            view.insert_action_group("spell", actions);

            var click = new Gtk.GestureClick();
            click.button = Gdk.BUTTON_SECONDARY;
            click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
            click.pressed.connect((n, x, y) => prepare_menu(x, y));
            view.add_controller(click);

            buffer.changed.connect(schedule_recheck);
            SpellChecker.get_default().changed.connect(schedule_recheck);
            recheck();
        }

        private void schedule_recheck() {
            if (recheck_id != 0) Source.remove(recheck_id);
            recheck_id = Timeout.add(300, () => {
                recheck_id = 0;
                recheck();
                return Source.REMOVE;
            });
        }

        private void recheck() {
            var buffer = view.buffer;
            Gtk.TextIter start, end, cursor;
            buffer.get_bounds(out start, out end);
            buffer.remove_tag(tag, start, end);
            var checker = SpellChecker.get_default();
            if (!checker.enabled || !checker.available || buffer.get_char_count() > 200000) return;
            buffer.get_iter_at_mark(out cursor, buffer.get_insert());
            var iter = start;
            while (iter.forward_word_end()) {
                var word_begin = iter;
                word_begin.backward_word_start();
                if (iter.equal(cursor)) continue;
                string word = buffer.get_text(word_begin, iter, false);
                if (SpellIntegration.checkable(word) && !checker.check(word)) {
                    buffer.apply_tag(tag, word_begin, iter);
                }
            }
        }

        private void prepare_menu(double x, double y) {
            section.remove_all();
            var buffer = view.buffer;
            int bx, by;
            view.window_to_buffer_coords(Gtk.TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);
            Gtk.TextIter iter;
            if (!view.get_iter_at_location(out iter, bx, by)) return;
            if (!iter.inside_word() && !iter.ends_word()) return;
            var start = iter;
            var end = iter;
            if (!start.starts_word()) start.backward_word_start();
            if (!end.ends_word()) end.forward_word_end();
            string word = buffer.get_text(start, end, false);
            var checker = SpellChecker.get_default();
            if (!checker.enabled || !SpellIntegration.checkable(word) || checker.check(word)) return;
            buffer.move_mark(word_start, start);
            buffer.move_mark(word_end, end);
            section.append_section(null, SpellIntegration.suggestion_menu(word));
        }

        private void replace_word(string replacement) {
            var buffer = view.buffer;
            Gtk.TextIter start, end;
            buffer.get_iter_at_mark(out start, word_start);
            buffer.get_iter_at_mark(out end, word_end);
            buffer.begin_user_action();
            buffer.delete(ref start, ref end);
            buffer.insert(ref start, replacement, -1);
            buffer.end_user_action();
        }
    }

    internal class EntrySpeller : Object {
        private unowned Gtk.Text text;
        private GLib.Menu section = new GLib.Menu();
        private int word_start = 0;
        private int word_end = 0;
        private uint recheck_id = 0;

        public EntrySpeller(Gtk.Text text) {
            this.text = text;
            var extra = new GLib.Menu();
            extra.append_section(null, section);
            if (text.extra_menu != null) extra.append_section(null, text.extra_menu);
            text.extra_menu = extra;

            var actions = new SimpleActionGroup();
            var replace = new SimpleAction("replace", VariantType.STRING);
            replace.activate.connect((param) => {
                text.delete_text(word_start, word_end);
                int position = word_start;
                text.insert_text(param.get_string(), -1, ref position);
            });
            actions.add_action(replace);
            var add = new SimpleAction("add", VariantType.STRING);
            add.activate.connect((param) => SpellChecker.get_default().add_to_dictionary(param.get_string()));
            actions.add_action(add);
            text.insert_action_group("spell", actions);

            var click = new Gtk.GestureClick();
            click.button = Gdk.BUTTON_SECONDARY;
            click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
            click.pressed.connect(() => prepare_menu());
            text.add_controller(click);

            text.changed.connect(schedule_recheck);
            SpellChecker.get_default().changed.connect(schedule_recheck);
            recheck();
        }

        private void schedule_recheck() {
            if (recheck_id != 0) Source.remove(recheck_id);
            recheck_id = Timeout.add(300, () => {
                recheck_id = 0;
                recheck();
                return Source.REMOVE;
            });
        }

        private void recheck() {
            var checker = SpellChecker.get_default();
            var attrs = new Pango.AttrList();
            if (checker.enabled && checker.available) {
                string content = text.text;
                int cursor_byte = content.index_of_nth_char(text.get_position());
                int i = 0;
                while (i < content.length) {
                    int start, end;
                    if (!next_word(content, ref i, out start, out end)) break;
                    if (end == cursor_byte) continue;
                    string word = content.substring(start, end - start);
                    if (SpellIntegration.checkable(word) && !checker.check(word)) {
                        var underline = Pango.attr_underline_new(Pango.Underline.ERROR);
                        underline.start_index = start;
                        underline.end_index = end;
                        attrs.insert((owned) underline);
                    }
                }
            }
            text.attributes = attrs;
        }

        private static bool next_word(string content, ref int index, out int start, out int end) {
            start = end = index;
            unichar c;
            int position = index;
            while (position < content.length) {
                int before = position;
                content.get_next_char(ref position, out c);
                if (c.isalpha()) {
                    start = before;
                    end = position;
                    int inner = position;
                    while (inner < content.length) {
                        int prev = inner;
                        content.get_next_char(ref inner, out c);
                        if (!c.isalpha() && c != '\'') {
                            inner = prev;
                            break;
                        }
                        end = inner;
                    }
                    index = end;
                    return true;
                }
            }
            index = content.length;
            return false;
        }

        private void prepare_menu() {
            section.remove_all();
            var checker = SpellChecker.get_default();
            if (!checker.enabled) return;
            string content = text.text;
            int cursor_byte = content.index_of_nth_char(text.get_position());
            int i = 0;
            int start, end;
            while (next_word(content, ref i, out start, out end)) {
                if (cursor_byte < start || cursor_byte > end) continue;
                string word = content.substring(start, end - start);
                if (!SpellIntegration.checkable(word) || checker.check(word)) return;
                word_start = (int) content.char_count(start);
                word_end = (int) content.char_count(end);
                section.append_section(null, SpellIntegration.suggestion_menu(word));
                return;
            }
        }
    }
}
