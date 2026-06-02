using Gtk;
using GtkSource;

namespace Singularity.Widgets {

    /**
     * A GtkSource.View preset for Singularity apps.
     *
     * Standardises:
     *   - hexpand / vexpand (fill the parent scroller)
     *   - internal top padding for the floating toolbar (titlebar is float
     *     by design, the editor lives full-bleed underneath)
     *   - sane defaults for monospace, wrap, tab handling
     *   - the `.singularity-sourceview` CSS hook so libsingularity can fix
     *     things like selection accent without each app re-adding classes
     *
     * Crucially, it does NOT add the generic `.view` CSS class - that one
     * is meant for icon/list views and blocks accent propagation when GTK
     * applies it to a textview.
     */
    public class SourceView : GtkSource.View {

        /** Pixels of internal top padding. Defaults to 60 (floating toolbar). */
        public int toolbar_top_padding {
            get { return top_margin; }
            set { top_margin = value; }
        }

        /**
         * When true (default), right-clicking shows the Singularity
         * {@link ContextMenu} (Undo/Redo, Cut/Copy/Paste, Select All) instead
         * of GtkSourceView's built-in, unthemed popover menu.
         */
        public bool use_context_menu { get; set; default = true; }

        public SourceView(GtkSource.Buffer? buf = null) {
            Object(buffer: buf);
            init_defaults();
        }

        public SourceView.with_buffer(GtkSource.Buffer buf) {
            Object(buffer: buf);
            init_defaults();
        }

        construct {
            init_defaults();
        }

        private bool _did_init = false;
        private void init_defaults() {
            if (_did_init) return;
            _did_init = true;

            add_css_class("singularity-sourceview");

            hexpand                       = true;
            vexpand                       = true;
            monospace                     = true;
            auto_indent                   = true;
            smart_backspace               = true;
            tab_width                     = 4;
            indent_width                  = 4;
            insert_spaces_instead_of_tabs = true;
            wrap_mode                     = Gtk.WrapMode.WORD_CHAR;

            // Internal padding: titlebar is float by design (46-54 px),
            // so the editor needs to push its first line below it.
            top_margin    = 60;
            bottom_margin = 8;
            left_margin   = 12;
            right_margin  = 12;

            _install_context_menu();
        }

        // Right-click shows our ContextMenu. A CAPTURE-phase secondary-button
        // gesture claims the press so GtkSourceView's own popover never opens.
        private void _install_context_menu() {
            var click = new Gtk.GestureClick();
            click.button = Gdk.BUTTON_SECONDARY;
            click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
            click.pressed.connect((n, x, y) => {
                if (!use_context_menu) return;

                var menu = new ContextMenu(this);
                Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
                menu.set_pointing_to(rect);

                menu.add_item("Undo", "edit-undo-symbolic", () => {
                    if (buffer != null && buffer.can_undo) buffer.undo();
                });
                menu.add_item("Redo", "edit-redo-symbolic", () => {
                    if (buffer != null && buffer.can_redo) buffer.redo();
                });
                menu.add_separator();
                menu.add_item("Cut", "edit-cut-symbolic",
                    () => activate_action("clipboard.cut", null));
                menu.add_item("Copy", "edit-copy-symbolic",
                    () => activate_action("clipboard.copy", null));
                menu.add_item("Paste", "edit-paste-symbolic",
                    () => activate_action("clipboard.paste", null));
                menu.add_separator();
                menu.add_item("Select All", "edit-select-all-symbolic",
                    () => activate_action("selection.select-all", null));

                menu.popup();
                click.set_state(Gtk.EventSequenceState.CLAIMED);
            });
            add_controller(click);
        }
    }
}
