using Gtk;

namespace Singularity {

    public class Focus : Object {
        private const string KEY = "singularity-focus-key";
        private const string PRIMARY = "singularity-focus-primary";
        private const string CANCEL = "singularity-focus-cancel";

        public static void set_key(Widget widget, string? key) {
            widget.set_data<string?>(KEY, key);
        }

        public static string? get_key(Widget widget) {
            return widget.get_data<string?>(KEY);
        }

        public static void set_primary(Widget widget, bool primary = true) {
            widget.set_data<bool>(PRIMARY, primary);
        }

        public static bool is_primary(Widget widget) {
            return widget.get_data<bool>(PRIMARY) || widget.has_css_class("suggested-action");
        }

        public static void set_cancel(Widget widget, bool cancel = true) {
            widget.set_data<bool>(CANCEL, cancel);
        }

        public static bool is_cancel(Widget widget) {
            return widget.get_data<bool>(CANCEL);
        }

        public static void retarget(Widget widget, string key) {
            var win = widget.get_root() as Singularity.Widgets.Window;
            if (win != null) win.retarget_focus(key);
        }

        public static bool is_covered(Widget widget, Widget root) {
            Graphene.Rect r;
            if (!widget.compute_bounds(root, out r)) return false;
            float cx = r.origin.x + r.size.width / 2;
            float cy = r.origin.y + r.size.height / 2;
            Widget inner = widget;
            for (Widget? p = widget.get_parent(); p != null && inner != root; inner = p, p = p.get_parent()) {
                var overlay = p as Overlay;
                if (overlay == null || overlay.child != inner) continue;
                Graphene.Rect ob;
                if (!overlay.compute_bounds(root, out ob)) continue;
                float area = ob.size.width * ob.size.height;
                for (var c = inner.get_next_sibling(); c != null; c = c.get_next_sibling()) {
                    if (!c.get_mapped() || !c.can_target) continue;
                    Graphene.Rect cb;
                    if (!c.compute_bounds(root, out cb)) continue;
                    if (cb.size.width * cb.size.height < area * 0.5f) continue;
                    if (cx >= cb.origin.x && cx <= cb.origin.x + cb.size.width
                            && cy >= cb.origin.y && cy <= cb.origin.y + cb.size.height) return true;
                }
            }
            return false;
        }

        internal static string? find_key(Widget widget) {
            for (Widget? w = widget; w != null && !(w is Window); w = w.get_parent()) {
                string? key = get_key(w);
                if (key != null) return key;
            }
            return key_below(widget);
        }

        private static string? key_below(Widget root) {
            for (var c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
                string? key = get_key(c);
                if (key != null) return key;
                key = key_below(c);
                if (key != null) return key;
            }
            return null;
        }

        internal static GenericArray<Widget> find_keyed(Widget root, string key) {
            var found = new GenericArray<Widget>();
            collect_keyed(root, key, found);
            return found;
        }

        private static void collect_keyed(Widget root, string key, GenericArray<Widget> found) {
            for (var c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
                if (!c.get_mapped()) continue;
                if (get_key(c) == key) {
                    found.add(c);
                    continue;
                }
                collect_keyed(c, key, found);
            }
        }
    }
}
