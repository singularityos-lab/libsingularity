using Gtk;
using Peas;

namespace Singularity {

    public interface FileIconProvider : Object {
        public abstract bool matches(GLib.File file, string? content_type);
        public abstract async Gdk.Paintable? load_icon(GLib.File file, int size);
    }

    public interface FilesPlugin : Object {
        public abstract void activate(FilesPluginContext context);
        public abstract void deactivate();
    }

    public class FilesPluginContext : Object {
        public signal void file_icon_provider_added(FileIconProvider provider);
        public signal void file_icon_provider_removed(FileIconProvider provider);

        public FilesPluginContext() {
        }

        public void add_file_icon_provider(FileIconProvider provider) {
            file_icon_provider_added(provider);
        }

        public void remove_file_icon_provider(FileIconProvider provider) {
            file_icon_provider_removed(provider);
        }
    }
}
