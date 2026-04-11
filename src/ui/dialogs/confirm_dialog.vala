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
     * Usage:
     *   var dlg = new ConfirmDialog(app, "Save Changes?", "dialog-warning-symbolic",
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

        /**
         * Creates a new confirmation dialog.
         *
         * @param app            The owning application
         * @param title          Dialog title
         * @param icon_name      Icon name for the header, or null for no icon
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

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top    = 32;
            box.margin_bottom = 24;
            box.margin_start  = 32;
            box.margin_end    = 32;

            if (icon_name != null) {
                var icon = new Image.from_icon_name(icon_name);
                icon.pixel_size = 48;
                icon.add_css_class("dim-label");
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

            var cancel_btn = new Button.with_label("Cancel");
            cancel_btn.add_css_class("pill");
            cancel_btn.width_request = 120;
            cancel_btn.clicked.connect(() => {
                response(Response.CANCEL);
                close_dialog();
            });
            btn_row.append(cancel_btn);

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
            _primary_btn.clicked.connect(() => {
                response(Response.PRIMARY);
                close_dialog();
            });
            btn_row.append(_primary_btn);

            box.append(btn_row);
            content_box.append(box);
        }

        /**
         * Adds a secondary action button (displayed between Cancel and Primary).
         *
         * @param label  Button label
         * @param style  Button style
         */
        public void set_secondary(string label, ActionStyle style = ActionStyle.DEFAULT) {
            _secondary_btn.label = label;
            _secondary_btn.visible = true;
            if (style == ActionStyle.SUGGESTED)
                _secondary_btn.add_css_class("suggested-action");
            else if (style == ActionStyle.DESTRUCTIVE)
                _secondary_btn.add_css_class("destructive-action");
            _secondary_btn.clicked.connect(() => {
                response(Response.SECONDARY);
                close_dialog();
            });
        }

        /**
         * The injectable content area. Append custom widgets (lists, entries, etc.)
         * here before presenting the dialog. Widgets appear between the
         * description and the button row.
         */
        public Box custom_area {
            get { return _custom_area; }
        }
    }
}