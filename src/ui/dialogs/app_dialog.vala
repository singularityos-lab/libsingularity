using Gtk;

namespace Singularity.Widgets {

    /**
     * A lightweight modal or non-modal dialog with a custom title bar.
     *
     * Provides a consistent title bar with a centered title label and close button,
     * bypassing GTK's default window decorations. The Escape key always closes the dialog.
     * Subclass and override `close_dialog()` and `open_dialog()` for custom show/hide behavior.
     */
    public class AppDialog : Gtk.ApplicationWindow {
        /** The main content area; append widgets here. */
        public Box content_box;
        private Box titlebar_box;
        private Label title_label;
        private CloseButton _close_btn;

        /**
         * Whether the close button is visible in the title bar (default: true).
         * Set to false for dialogs that must be dismissed via an explicit action.
         */
        public bool closable {
            get { return _close_btn.visible; }
            set { _close_btn.visible = value; }
        }

        /**
         * Creates a new dialog window.
         *
         * @param app       The owning Gtk.Application
         * @param use_modal Whether the dialog should be modal
         */
        public AppDialog(Gtk.Application app, bool use_modal = false) {
            Object(application: app);
            add_css_class("singularity");
            add_css_class("singularity-app");
            add_css_class("dialog");
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
            _close_btn.clicked.connect(() => close_dialog());
            titlebar_box.append(_close_btn);
            var handle = new WindowHandle();
            handle.set_child(titlebar_box);
            set_titlebar(handle);
            content_box = new Box(Orientation.VERTICAL, 0);
            content_box.add_css_class("dialog-content");
            set_child(content_box);
            this.modal = use_modal;
            this.set_decorated(false);
            var key_controller = new EventControllerKey();
            key_controller.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    close_dialog();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget)this).add_controller(key_controller);
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
        public virtual void close_dialog() {
            close();
        }

        /**
         * Presents the dialog. Override to add custom show behaviour.
         */
        public virtual void open_dialog() {
            present();
        }
    }
}
