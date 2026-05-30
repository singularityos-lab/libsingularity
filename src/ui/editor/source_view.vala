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

        public SourceView(GtkSource.Buffer? buf = null) {
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
        }
    }
}
