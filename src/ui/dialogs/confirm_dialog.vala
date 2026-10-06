using Gtk;

namespace Singularity.Widgets {

    /**
     * A confirmation dialog with standard action buttons and an injectable
     * content area for custom widgets.
     *
     * Built on top of AppDialog for consistent appearance with other
     * Singularity dialogs (Properties, New Folder, etc.).
     *
     * Supports three response types: primary, secondary, and cancel.
     * The primary button can be styled as suggested or destructive.
     *
     * The Cancel button is always present, so the titlebar close bubble is
     * hidden. Escape clicks Cancel, and closing the window any other way
     * without a response, for example from the compositor, emits
     * `Response.CANCEL` as well.
     *
     * Usage:
     *   var dlg = new ConfirmDialog(app, "Save Changes?", null,
     *       "You have unsaved changes.", "Discard", ConfirmDialog.ActionStyle.DESTRUCTIVE);
     *   dlg.set_secondary("Save", ConfirmDialog.ActionStyle.SUGGESTED);
     *   dlg.response.connect((r) => {
     *       if (r == Response.SECONDARY) save();
     *       else if (r == Response.PRIMARY) discard();
     *   });
     *   dlg.present();
     */
    public class ConfirmDialog : AppDialog {

        public enum Response {
            PRIMARY,
            SECONDARY,
            CANCEL
        }

        public enum ActionStyle {
            DEFAULT,
            SUGGESTED,
            DESTRUCTIVE
        }

        /** Emitted when the user clicks any button. */
        public signal void response(Response r);

        private Box _custom_area;
        private Button _primary_btn;
        private Button _secondary_btn;
        private Button _cancel_btn;
        private bool _responded = false;

        /**
         * Creates a new confirmation dialog.
         *
         * @param app            The owning application
         * @param title          Dialog title
         * @param icon_name      Full-color hicolor icon for the header, drawn at
         *                       48 px, or null for no icon
         * @param description    Body text shown below the title
         * @param primary_label  Label for the primary action button (rightmost)
         * @param primary_style  Style for the primary button
         */
        public ConfirmDialog(Gtk.Application app,
                             string title,
                             string? icon_name,
                             string? description,
                             string primary_label,
                             ActionStyle primary_style = ActionStyle.DEFAULT) {
            base(app, false);
            set_title(title);
            set_default_size(380, 0);

            var box = new Box(Orientation.VERTICAL, 12);
            box.margin_top    = 24;
            box.margin_bottom = 20;
            box.margin_start  = 24;
            box.margin_end    = 24;

            if (icon_name != null) {
                string shown = large_icon_name(icon_name);
                var icon = new Image.from_icon_name(shown);
                icon.pixel_size = 48;
                if (shown.has_suffix("-symbolic")) icon.add_css_class("dim-label");
                box.append(icon);
            }

            if (description != null && description != "") {
                var desc_lbl = new Label(description);
                desc_lbl.wrap = true;
                desc_lbl.max_width_chars = 42;
                desc_lbl.justify = Justification.CENTER;
                box.append(desc_lbl);
            }

            // Injectable custom area: callers append widgets here before presenting
            _custom_area = new Box(Orientation.VERTICAL, 8);
            box.append(_custom_area);

            var btn_row = new Box(Orientation.HORIZONTAL, 12);
            btn_row.halign = Align.CENTER;
            btn_row.margin_top = 8;

            _cancel_btn = new Button.with_label(_("Cancel"));
            _cancel_btn.add_css_class("pill");
            _cancel_btn.width_request = 120;
            _cancel_btn.clicked.connect(() => respond(Response.CANCEL));
            btn_row.append(_cancel_btn);
            set_cancel_button(_cancel_btn);

            _secondary_btn = new Button.with_label("");
            _secondary_btn.add_css_class("pill");
            _secondary_btn.width_request = 120;
            _secondary_btn.visible = false;
            btn_row.append(_secondary_btn);

            _primary_btn = new Button.with_label(primary_label);
            _primary_btn.add_css_class("pill");
            _primary_btn.width_request = 120;
            if (primary_style == ActionStyle.SUGGESTED)
                _primary_btn.add_css_class("suggested-action");
            else if (primary_style == ActionStyle.DESTRUCTIVE)
                _primary_btn.add_css_class("destructive-action");
            _primary_btn.clicked.connect(() => respond(Response.PRIMARY));
            btn_row.append(_primary_btn);

            box.append(btn_row);
            content_box.append(box);

            response.connect(() => _responded = true);
            close_request.connect(() => {
                if (!_responded) response(Response.CANCEL);
                return false;
            });
        }

        /**
         * Creates a message dialog with a single button, for an error or a
         * notice that the user only acknowledges. There is no Cancel button;
         * the button, Escape and closing the window all dismiss it. The
         * button and Escape emit `Response.PRIMARY`; closing the window from
         * the compositor emits `Response.CANCEL`.
         *
         * @param app          The owning application
         * @param title        Dialog title
         * @param icon_name    Full-color hicolor icon for the header, or null
         * @param description  Body text shown below the title
         * @param button_label Label of the button, "OK" when null
         */
        public ConfirmDialog.message(Gtk.Application app,
                                     string title,
                                     string? icon_name,
                                     string? description,
                                     string? button_label = null) {
            this(app, title, icon_name, description, button_label ?? _("OK"), ActionStyle.SUGGESTED);
            has_cancel = false;
        }

        /**
         * Whether the dialog shows its Cancel button. Without it the primary
         * button is the only one and Escape presses it.
         */
        public bool has_cancel {
            get { return _cancel_btn.visible; }
            set {
                _cancel_btn.visible = value;
                set_cancel_button(value ? _cancel_btn : _primary_btn);
            }
        }

        private void respond(Response r) {
            response(r);
            close_dialog();
        }

        /**
         * Adds a secondary action button (displayed between Cancel and Primary).
         *
         * @param label  Button label
         * @param style  Button style
         */
        public void focus_primary() {
            _primary_btn.grab_focus();
        }

        public void set_secondary(string label, ActionStyle style = ActionStyle.DEFAULT) {
            _secondary_btn.label = label;
            _secondary_btn.visible = true;
            if (style == ActionStyle.SUGGESTED)
                _secondary_btn.add_css_class("suggested-action");
            else if (style == ActionStyle.DESTRUCTIVE)
                _secondary_btn.add_css_class("destructive-action");
            _secondary_btn.clicked.connect(() => respond(Response.SECONDARY));
        }

        /**
         * The injectable content area. Append custom widgets (lists, entries, etc.)
         * here before presenting the dialog. Widgets appear between the
         * description and the button row.
         */
        public Box custom_area {
            get { return _custom_area; }
        }

        /**
         * Whether the primary button can be pressed, for dialogs whose custom
         * area holds input that must be valid first.
         */
        public bool primary_sensitive {
            get { return _primary_btn.sensitive; }
            set { _primary_btn.sensitive = value; }
        }
    }
}