using GLib;
using Gtk;

namespace Singularity.FileSystem {

    /**
     * A FileProvider that exposes SMB/CIFS network shares.
     *
     * Handles the `smb` URI scheme. Mounting is attempted via
     * GLib.File.mount_enclosing_volume; if the share is already mounted the call succeeds immediately.
     */
    public class SambaProvider : Object, FileProvider {
        public string name { get { return "Network (SMB)"; } }
        public string icon_name { get { return "network-workgroup-symbolic"; } }
        public string scheme { get { return "smb"; } }

        public async bool mount(string uri, Cancellable? cancellable = null) throws Error {
            var file = File.new_for_uri(uri);
            try {
                yield file.mount_enclosing_volume(MountMountFlags.NONE, null, cancellable);
                return true;
            } catch (Error e) {
                if (e.code == IOError.ALREADY_MOUNTED) return true;
                throw e;
            }
        }

        public async List<FileItem> enumerate(string uri, Cancellable? cancellable = null) throws Error {
            var list = new List<FileItem>();
            var folder = File.new_for_uri(uri);
            var enumerator = yield folder.enumerate_children_async(
                "standard::*,standard::icon,standard::is-hidden,standard::content-type",
                FileQueryInfoFlags.NONE,
                Priority.DEFAULT,
                cancellable
            );
            List<FileInfo> files;
            while ((files = yield enumerator.next_files_async(10, Priority.DEFAULT, cancellable)) != null && files.length() > 0) {
                foreach (var info in files) {
                    if (info.get_is_hidden()) continue;
                    var child = folder.get_child(info.get_name());
                    list.append(new FileItem(child, info));
                }
            }
            return list;
        }

        public async FileItem? get_info(string uri, Cancellable? cancellable = null) throws Error {
            var file = File.new_for_uri(uri);
            var info = yield file.query_info_async(
                "standard::*,standard::icon,standard::is-hidden,standard::content-type",
                FileQueryInfoFlags.NONE,
                Priority.DEFAULT,
                cancellable
            );
            return new FileItem(file, info);
        }
    }
}
