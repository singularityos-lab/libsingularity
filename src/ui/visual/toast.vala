using Gtk;

namespace Singularity.Widgets {

    /**
     * A transient message shown at the bottom of a window.
     *
     * Show it with Window.add_toast or ToastOverlay.add_toast. Toasts added
     * while another one is visible wait in a queue and appear one after the
     * other. Screen readers announce each toast when it appears.
     *
     * Example:
     * {{{
     *   var toast = new Singularity.Widgets.Toast (_("Message deleted"));
     *   toast.button_label = _("Undo");
     *   toast.button_clicked.connect (() => restore ());
     *   window.add_toast (toast);
     * }}}
     */
    public class Toast : Object {

        /** Text of the message. */
        public string title { get; set; }

        /** Label of the optional action button, e.g. `"Undo"`. Hidden when null. */
        public string? button_label { get; set; default = null; }

        /** Seconds the toast stays on screen; 0 keeps it until dismissed. */
        public uint timeout { get; set; default = 5; }

        /** Emitted when the user presses the action button, before the toast is dismissed. */
        public signal void button_clicked();

        /** Emitted once the toast leaves the screen or the queue. */
        public signal void dismissed();

        internal ToastHost? host = null;

        /**
         * @param title Text of the message.
         */
        public Toast(string title) {
            Object(title: title);
        }

        /** Removes the toast from the screen, or from the queue if it is still waiting. */
        public void dismiss() {
            if (host != null) host.dismiss_toast(this);
        }
    }

    /**
     * Container that shows toasts over its child.
     *
     * Singularity.Widgets.Window already has one around its whole content,
     * reached through Window.add_toast; use a ToastOverlay for toasts over a
     * single area, such as one pane of a split view.
     */
    public class ToastOverlay : Widget {

        private Overlay _overlay;
        private ToastHost _host;

        /** Widget the toasts are shown over. */
        public Widget? child {
            get { return _overlay.child; }
            set { _overlay.child = value; }
        }

        static construct {
            set_layout_manager_type(typeof(BinLayout));
        }

        construct {
            _overlay = new Overlay();
            _overlay.set_parent(this);
            _host = new ToastHost();
            _overlay.add_overlay(_host.slot);
        }

        public ToastOverlay() {
            Object();
        }

        public override void dispose() {
            if (_overlay != null) {
                _overlay.unparent();
                _overlay = null;
            }
            base.dispose();
        }

        /**
         * Shows a toast, or queues it while another one is visible.
         *
         * @param toast The toast to show.
         */
        public void add_toast(Toast toast) {
            _host.add_toast(toast);
        }
    }

    internal class ToastHost : Box {

        private GenericArray<Toast> _queue = new GenericArray<Toast>();
        private Toast? _current = null;
        private Label _label;
        private Button _action;
        private uint _timeout_id = 0;
        private bool _hiding = false;

        internal Singularity.Animation.MotionBin slot;

        public ToastHost() {
            Object(orientation: Orientation.HORIZONTAL, spacing: 10);
        }

        construct {
            add_css_class("singularity-toast");
            visible = false;
            slot = new Singularity.Animation.MotionBin(this);
            slot.halign = Align.CENTER;
            slot.valign = Align.END;
            slot.margin_bottom = 18;
            slot.margin_start = 12;
            slot.margin_end = 12;

            _label = new Label("");
            _label.wrap = true;
            _label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            _label.max_width_chars = 60;
            _label.natural_wrap_mode = NaturalWrapMode.NONE;
            _label.xalign = 0;
            _label.valign = Align.CENTER;
            append(_label);

            _action = new Button();
            _action.add_css_class("flat");
            _action.valign = Align.CENTER;
            _action.clicked.connect(() => {
                var toast = _current;
                if (toast == null) return;
                toast.button_clicked();
                dismiss_toast(toast);
            });
            append(_action);

            var close = new Button.from_icon_name("window-close-symbolic");
            close.add_css_class("flat");
            close.add_css_class("circular");
            close.valign = Align.CENTER;
            close.tooltip_text = _("Dismiss");
            close.clicked.connect(() => {
                if (_current != null) dismiss_toast(_current);
            });
            append(close);
        }

        public override void dispose() {
            if (_timeout_id != 0) {
                Source.remove(_timeout_id);
                _timeout_id = 0;
            }
            base.dispose();
        }

        public void add_toast(Toast toast) {
            if (toast == _current || _index_of(toast) >= 0) return;
            if (toast.host != null) toast.host.dismiss_toast(toast);
            toast.host = this;
            _queue.add(toast);
            if (_current == null) _show_next();
        }

        public void dismiss_toast(Toast toast) {
            Toast keep = toast;
            if (keep == _current) {
                if (_timeout_id != 0) {
                    Source.remove(_timeout_id);
                    _timeout_id = 0;
                }
                _current = null;
                keep.host = null;
                keep.dismissed();
                _show_next();
                return;
            }
            int index = _index_of(keep);
            if (index < 0) return;
            _queue.remove_index(index);
            keep.host = null;
            keep.dismissed();
        }

        private void _hide() {
            if (!visible || _hiding) return;
            _hiding = true;
            Singularity.Motion.conceal(slot, Singularity.Motion.Preset.FADE_SLIDE).done.connect(() => {
                if (!_hiding) return;
                _hiding = false;
                visible = false;
                slot.opacity = 1.0;
                slot.reset_transform();
            });
        }

        private int _index_of(Toast toast) {
            for (int i = 0; i < _queue.length; i++) {
                if (_queue[i] == toast) return i;
            }
            return -1;
        }

        private void _show_next() {
            if (_queue.length == 0) {
                _hide();
                return;
            }
            var toast = _queue[0];
            _queue.remove_index(0);
            _current = toast;
            _label.label = toast.title;
            _action.visible = toast.button_label != null && toast.button_label != "";
            if (_action.visible) _action.label = toast.button_label;
            if (!visible || _hiding) {
                _hiding = false;
                visible = true;
                Singularity.Motion.reveal(slot, Singularity.Motion.Preset.FADE_SLIDE);
            }
            announce(toast.title, AccessibleAnnouncementPriority.MEDIUM);
            if (toast.timeout > 0) {
                _timeout_id = Timeout.add_seconds(toast.timeout, () => {
                    _timeout_id = 0;
                    if (_current != null) dismiss_toast(_current);
                    return Source.REMOVE;
                });
            }
        }
    }
}
