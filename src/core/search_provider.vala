using GLib;
using Gdk;

namespace Singularity {

    public interface SearchProvider : Object {
        public abstract string id { get; }
        public abstract string name { get; }
        public abstract async List<SearchResult> search(string query, Cancellable? cancellable) throws Error;
    }

    /**
     * A secondary action shown as a button on a search result row, next to
     * the primary click. Typical actions are Copy, Open or Add.
     *
     * Connect to `activated` or subclass and override `activate`. The shell
     * closes the search after an action runs unless `keeps_open` is set.
     */
    public class SearchAction : Object {
        /** Stable identifier of the action within its result. */
        public string id { get; construct; }
        /** Human readable label, used as the button tooltip or text. */
        public string label { get; construct; }
        /** Symbolic icon for the button, or null to show the label. */
        public string? icon_name { get; construct; }
        /** When true, the search stays open after the action runs. */
        public bool keeps_open { get; set; default = false; }

        /** Emitted when the user clicks the action button. */
        public signal void activated();

        public SearchAction(string id, string label, string? icon_name = null) {
            Object(id: id, label: label, icon_name: icon_name);
        }

        /**
         * Runs the action. The default implementation emits `activated`.
         */
        public virtual void activate() {
            activated();
        }

        /**
         * Returns an action that puts `text` on the clipboard when clicked.
         *
         * @param text  The text to copy.
         * @param label Label of the button, "Copy" when null.
         */
        public static SearchAction copy_text(string text, string? label = null) {
            var action = new SearchAction("copy", label ?? _("Copy"), "edit-copy-symbolic");
            action.activated.connect(() => {
                var display = Gdk.Display.get_default();
                if (display != null) display.get_clipboard().set_text(text);
            });
            return action;
        }
    }

    /**
     * Kind of rich preview attached to a search result.
     */
    public enum SearchResultPreviewKind {
        /** A colour swatch, from `color`. */
        COLOR,
        /** A picture, from `paintable`. */
        IMAGE,
        /** A large icon, from `icon`, for example an encoded QR code image. */
        ICON,
        /** A short block of monospace text, from `text`. */
        TEXT
    }

    /**
     * Rich preview shown inside a search result row, such as a colour
     * swatch, a QR code or a thumbnail.
     */
    public class SearchResultPreview : Object {
        public SearchResultPreviewKind kind { get; construct; }
        /** Swatch colour for `COLOR` previews. */
        public Gdk.RGBA color { get; construct; }
        /** Picture for `IMAGE` previews. */
        public Gdk.Paintable? paintable { get; construct; }
        /** Icon for `ICON` previews; a GLib.BytesIcon carries encoded image data. */
        public GLib.Icon? icon { get; construct; }
        /** Text for `TEXT` previews. */
        public string? text { get; construct; }
        /**
         * Draws the preview at `LARGE_SIZE` instead of the row size, for
         * content that must stay readable, such as a QR code to scan.
         */
        public bool large { get; set; default = false; }

        /** Size in pixels of a `large` preview. */
        public const int LARGE_SIZE = 160;

        private SearchResultPreview(SearchResultPreviewKind kind, Gdk.RGBA color,
                                    Gdk.Paintable? paintable, GLib.Icon? icon, string? text) {
            Object(kind: kind, color: color, paintable: paintable, icon: icon, text: text);
        }

        /**
         * A colour swatch. Returns null when `spec` is not a colour that
         * Gdk.RGBA.parse understands, such as "#3584e4" or "rgb(53,132,228)".
         */
        public static SearchResultPreview? for_color(string spec) {
            var rgba = Gdk.RGBA();
            if (!rgba.parse(spec)) return null;
            return new SearchResultPreview(SearchResultPreviewKind.COLOR, rgba, null, null, null);
        }

        /** A picture preview. */
        public static SearchResultPreview for_paintable(Gdk.Paintable paintable) {
            return new SearchResultPreview(SearchResultPreviewKind.IMAGE, Gdk.RGBA(), paintable, null, null);
        }

        /** An icon preview, drawn large. */
        public static SearchResultPreview for_icon(GLib.Icon icon) {
            return new SearchResultPreview(SearchResultPreviewKind.ICON, Gdk.RGBA(), null, icon, null);
        }

        /** A short monospace text preview. */
        public static SearchResultPreview for_text(string text) {
            return new SearchResultPreview(SearchResultPreviewKind.TEXT, Gdk.RGBA(), null, null, text);
        }
    }

    public class SearchResult : Object {
        public string title { get; construct; }
        public string? description { get; construct; }
        public string? icon_name { get; construct; }
        public Icon? gicon { get; construct; }
        public string? action_id { get; construct; }
        public double score { get; set; default = 0.0; }
        public string? mime_type { get; set; default = null; }
        public SearchProvider provider { get; construct; }
        public signal void activated();

        /** Rich preview shown in the result row, or null for none. */
        public SearchResultPreview? preview { get; set; default = null; }

        /**
         * When true, the search stays open after the primary activation,
         * for example when the result only copies a value.
         */
        public bool keeps_open { get; set; default = false; }

        private GenericArray<SearchAction> _actions = new GenericArray<SearchAction>();

        public SearchResult(SearchProvider provider, string title, string? description = null, string? icon_name = null, Icon? gicon = null, string? action_id = null) {
            Object(
                provider: provider,
                title: title,
                description: description,
                icon_name: icon_name,
                gicon: gicon,
                action_id: action_id
            );
        }

        public virtual void activate() {
            activated();
        }

        /**
         * Adds a secondary action shown as a button on the result row.
         * Rows show at most three actions, in the order they were added.
         */
        public void add_action(SearchAction action) {
            _actions.add(action);
        }

        /** Returns the secondary actions, in the order they were added. */
        public SearchAction[] get_actions() {
            return _actions.data;
        }
    }
}
