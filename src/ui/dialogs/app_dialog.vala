using Gtk;

namespace Singularity.Widgets {

    /**
     * Lightweight Singularity dialog window. Custom titlebar with a
     * centered title and a top-right close bubble. The close button is
     * shown by default; pass `show_close: false` to the constructor for
     * dialogs that require an explicit action to dismiss.
     *
     * The window background is transparent and the visible card is inset
     * by `SHADOW_MARGIN` pixels so its drop shadow has room to render.
     */
    public class AppDialog : Gtk.ApplicationWindow {

        public const int SHADOW_MARGIN = 20;

        /** Main content area; apps append widgets here. */
        public Box content_box;

        private Box        titlebar_box;
        private Label      title_label;
        private CloseButton _close_btn;

        /** Toggle the close button at runtime. */
        public bool closable {
            get { return _close_btn.visible; }
            set { _close_btn.visible = value; }
        }

        /**
         * @param app        Owning application.
         * @param use_modal  Block input to the parent while open.
         * @param show_close Show the top-right close bubble (default true).
         */
        public AppDialog(Gtk.Application app,
                         bool use_modal  = false,
                         bool show_close = true) {
            Object(application: app);
            add_css_class("singularity");
            add_css_class("singularity-app");
            add_css_class("dialog");

            // Build titlebar (centered title + close on the right).
            titlebar_box = new Box(Orientation.HORIZONTAL, 0);
            titlebar_box.add_css_class("dialog-titlebar");

            var start_spacer = new Box(Orientation.HORIZONTAL, 0);
            start_spacer.hexpand = true;
            titlebar_box.append(start_spacer);

            title_label = new Label("");
            title_label.add_css_class("title");
            title_label.halign = Align.CENTER;
            titlebar_box.append(title_label);

            var end_spacer = new Box(Orientation.HORIZONTAL, 0);
            end_spacer.hexpand = true;
            titlebar_box.append(end_spacer);

            _close_btn = new Singularity.Widgets.CloseButton();
            _close_btn.visible = show_close;
            _close_btn.clicked.connect(() => close_dialog());
            titlebar_box.append(_close_btn);

            // Card wraps titlebar + content. The card is what carries the
            // shadow; the surrounding margin lets the shadow render.
            content_box = new Box(Orientation.VERTICAL, 0);
            content_box.add_css_class("dialog-content");
            content_box.vexpand = true;
            content_box.hexpand = true;

            var card = new Box(Orientation.VERTICAL, 0);
            card.add_css_class("dialog-card");
            card.hexpand = true;
            card.vexpand = true;

            var handle = new WindowHandle();
            handle.set_child(titlebar_box);
            card.append(handle);
            card.append(content_box);

            var outer = new Box(Orientation.VERTICAL, 0);
            outer.margin_top    = SHADOW_MARGIN;
            outer.margin_bottom = SHADOW_MARGIN;
            outer.margin_start  = SHADOW_MARGIN;
            outer.margin_end    = SHADOW_MARGIN;
            outer.append(card);
            set_child(outer);

            this.modal = use_modal;
            set_decorated(false);

            var key = new EventControllerKey();
            key.key_pressed.connect((keyval, _kc, _st) => {
                if (keyval == Gdk.Key.Escape && _close_btn.visible) {
                    close_dialog();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget)this).add_controller(key);

            set_default_size(400, 500);
        }

        /**
         * Updates the dialog title in both the OS title bar and the visible label.
         *
         * @param title Human-readable title string.
         */
        public new void set_title(string title) {
            base.title = title;
            title_label.label = title;
        }

        /**
         * Closes the dialog. Override to add custom close behaviour.
         */
        public virtual void close_dialog() { close(); }

        /**
         * Presents the dialog. Override to add custom show behaviour.
         */
        public virtual void open_dialog() {
            present();
            var focus = get_focus();
            if (focus == null) {
                var first_btn = find_first_button(content_box);
                if (first_btn != null) first_btn.grab_focus();
            }
        }

        private static Button? find_first_button(Widget root) {
            unowned Widget child = root.get_first_child();
            while (child != null) {
                if (child is Button) return (Button) child;
                var inner = find_first_button(child);
                if (inner != null) return inner;
                child = child.get_next_sibling();
            }
            return null;
        }
    }
}
