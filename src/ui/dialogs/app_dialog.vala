using Gtk;

namespace Singularity.Widgets {

    /**
     * Lightweight Singularity dialog window. Custom titlebar with a
     * centered title and a top-right close bubble. The close button is
     * shown by default; pass `show_close: false` to the constructor for
     * dialogs that require an explicit action to dismiss.
     *
     * One way to dismiss is enough: a dialog whose footer has a Cancel
     * button, or a single Close or OK button as its only dismissal, does
     * not also show the titlebar close bubble. Declare that button with
     * `add_cancel_button()` or `set_cancel_button()`; the bubble is
     * hidden and Escape clicks the button. When nothing is declared, the
     * first visible button in `content_box` that carries the `cancel`
     * style class or whose label is exactly "Cancel" is taken as the
     * cancel button the first time the dialog is mapped. Buttons inside
     * list rows or popovers, and hidden buttons, are skipped; no other
     * button is ever guessed.
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
        private Button?    _cancel_btn = null;
        private bool       _cancel_detected = false;
        private Singularity.Animation.MotionBin _card_motion;
        private bool       _closing = false;
        private bool       _destroyed = false;

        /** Toggle the close button at runtime. Same as `show_close_button`. */
        public bool closable {
            get { return _close_btn.visible; }
            set { _close_btn.visible = value; }
        }

        /**
         * Whether the titlebar shows the close bubble. Declaring a cancel
         * button sets it to false.
         */
        public bool show_close_button {
            get { return _close_btn.visible; }
            set { _close_btn.visible = value; }
        }

        /**
         * @param app        Owning application.
         * @param use_modal  Block input to the parent while open.
         * @param show_close Show the top-right close bubble (default true).
         */
        public AppDialog(Gtk.Application? app,
                         bool use_modal  = false,
                         bool show_close = true) {
            Object(application: app);
            show_menubar = false;
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
            _card_motion = new Singularity.Animation.MotionBin(card);
            _card_motion.hexpand = true;
            _card_motion.vexpand = true;
            outer.append(_card_motion);
            set_child(outer);

            this.modal = use_modal;
            set_decorated(false);

            var key = new EventControllerKey();
            key.propagation_phase = PropagationPhase.CAPTURE;
            key.key_pressed.connect((keyval, _kc, _st) => {
                if (keyval != Gdk.Key.Escape) return false;
                if (_cancel_btn != null) {
                    if (_cancel_btn.is_sensitive()) _cancel_btn.clicked();
                    return true;
                }
                if (_close_btn.visible) {
                    close_dialog();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget)this).add_controller(key);
            ((Gtk.Widget)this).map.connect(() => {
                detect_cancel_button();
                _closing = false;
                _card_motion.can_target = true;
                Singularity.Motion.reveal(_card_motion, Singularity.Motion.Preset.SCALE_FADE);
            });
            ((Gtk.Widget)this).destroy.connect(() => _destroyed = true);
            notify["title"].connect(() => sync_titlebar());
            _close_btn.notify["visible"].connect(() => sync_titlebar());
            sync_titlebar();

            set_default_size(400, 500);
        }

        /**
         * Updates the dialog title in both the OS title bar and the visible label.
         *
         * @param title Human-readable title string.
         */
        public new void set_title(string title) {
            base.title = title;
        }

        private void sync_titlebar() {
            string text = base.title ?? "";
            title_label.label = text;
            titlebar_box.visible = text != "" || _close_btn.visible;
        }

        /**
         * Creates the dialog's cancel button and declares it with
         * `set_cancel_button()`. Clicking it calls `close_dialog()`. The
         * caller places the returned button in its footer and styles it.
         *
         * @param label Button label; defaults to "Cancel". Pass "Close" or
         *              "OK" for a dialog whose only dismissal is that button.
         * @return The new button.
         */
        public Button add_cancel_button(string? label = null) {
            var btn = new Button.with_label(label ?? _("Cancel"));
            btn.clicked.connect(() => close_dialog());
            set_cancel_button(btn);
            return btn;
        }

        /**
         * Declares an existing button as the dialog's cancel action: the
         * titlebar close bubble is hidden and Escape clicks the button.
         * Use it for a Cancel button, or for a single Close or OK button
         * that is the dialog's only dismissal. The button keeps its own
         * click handlers.
         *
         * @param button The footer button that dismisses the dialog.
         */
        public void set_cancel_button(Button button) {
            _cancel_btn = button;
            _close_btn.visible = false;
        }

        /**
         * Closes the dialog. Override to add custom close behaviour.
         */
        public virtual void close_dialog() {
            if (_closing) return;
            if (!get_mapped()) {
                close();
                return;
            }
            _closing = true;
            _card_motion.can_target = false;
            Singularity.Motion.conceal(_card_motion, Singularity.Motion.Preset.SCALE_FADE).done.connect(() => {
                if (_destroyed || !_closing) return;
                close();
                _closing = false;
                _card_motion.opacity = 1.0;
                _card_motion.reset_transform();
                _card_motion.can_target = true;
            });
        }

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

        private void detect_cancel_button() {
            if (_cancel_detected || _cancel_btn != null) return;
            _cancel_detected = true;
            var found = find_cancel_button(content_box);
            if (found != null) set_cancel_button(found);
        }

        private static Button? find_cancel_button(Widget root) {
            unowned Widget child = root.get_first_child();
            while (child != null) {
                if (child.visible && child.get_child_visible()
                    && !(child is ListBoxRow) && !(child is Popover)) {
                    if (child is Button && is_cancel_button((Button) child))
                        return (Button) child;
                    var inner = find_cancel_button(child);
                    if (inner != null) return inner;
                }
                child = child.get_next_sibling();
            }
            return null;
        }

        private static bool is_cancel_button(Button btn) {
            if (btn.has_css_class("cancel")) return true;
            string? label = btn.label;
            if (label == null) return false;
            return label == "Cancel" || label == _("Cancel");
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
