using GLib;
using Gtk;

namespace Singularity.FileSystem {

    /**
     * A FileProvider that surfaces the user's recently-opened files
     * via Gtk.RecentManager.
     *
     * Returns up to 50 recently-accessed files sorted by modification date (newest first).
     * Handles the `recent` URI scheme.
     */
    public class RecentProvider : Object, FileProvider {
        public string name { get { return "Recent"; } }
        public string icon_name { get { return "document-open-recent-symbolic"; } }
        public string scheme { get { return "recent"; } }

        public async bool mount(string uri, Cancellable? cancellable = null) throws Error {
            return true;
        }

        public async List<FileItem> enumerate(string uri, Cancellable? cancellable = null) throws Error {
            var list = new List<FileItem>();
            var manager = RecentManager.get_default();
            var items = manager.get_items();
            items.sort((a, b) => {
                return b.get_modified().compare(a.get_modified());
            });
            foreach (var item in items) {
                if (!item.exists()) continue;
                var file = File.new_for_uri(item.get_uri());
                try {
                    if (list.length() > 50) break;
                    var info = yield file.query_info_async(
                        "standard::*,standard::icon,standard::is-hidden,standard::content-type",
                        FileQueryInfoFlags.NONE,
                        Priority.DEFAULT,
                        cancellable
                    );
                    list.append(new FileItem(file, info));
                } catch (Error e) {
                }
            }
            return list;
        }

        public async FileItem? get_info(string uri, Cancellable? cancellable = null) throws Error {
            if (uri == "recent://") return null;
            var manager = RecentManager.get_default();
            try {
                var item = manager.lookup_item(uri);
                if (item == null || !item.exists()) return null;
                var file = File.new_for_uri(item.get_uri());
                var info = yield file.query_info_async(
                    "standard::*,standard::icon,standard::is-hidden,standard::content-type",
                    FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);
                return new FileItem(file, info);
            } catch (Error e) {
                return null;
            }
        }
    }
}
