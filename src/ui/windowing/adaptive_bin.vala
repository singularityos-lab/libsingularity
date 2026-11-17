using Gtk;

namespace Singularity.Widgets {

    public delegate Widget AdaptiveBuilder(FormFactorKind kind);

    public class AdaptiveBin : Widget {
        private AdaptiveBuilder _builder;
        private Widget? _child = null;
        private FormFactorKind _built = FormFactorKind.DESKTOP;
        private unowned Window? _window = null;
        private ulong _window_id = 0;

        public AdaptiveBin(owned AdaptiveBuilder builder) {
            _builder = (owned) builder;
            layout_manager = new BinLayout();
            build(FormFactor.current());
            notify["root"].connect(track_root);
        }

        public FormFactorKind kind {
            get { return _built; }
        }

        public void rebuild() {
            build(_window != null ? _window.form_factor : FormFactor.current());
        }

        private void build(FormFactorKind kind) {
            if (_child != null) {
                _child.unparent();
                _child = null;
            }
            _built = kind;
            _child = _builder(kind);
            _child.set_parent(this);
        }

        private void track_root() {
            var win = get_root() as Window;
            if (win == _window) return;
            detach();
            _window = win;
            if (_window == null) return;
            _window_id = _window.form_factor_changed.connect((previous) => {
                if (_window.form_factor != _built) rebuild();
            });
            if (_window.form_factor != _built) rebuild();
        }

        private void detach() {
            if (_window != null && _window_id != 0) _window.disconnect(_window_id);
            _window = null;
            _window_id = 0;
        }

        public override void dispose() {
            detach();
            if (_child != null) {
                _child.unparent();
                _child = null;
            }
            base.dispose();
        }
    }
}
