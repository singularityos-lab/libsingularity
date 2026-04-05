using GLib;
using Gtk;

namespace Singularity.FileSystem {

    /**
     * Interface for pluggable file-system backends.
     *
     * Implement this to expose a new URI scheme (e.g. `smb`, `recent`,
     * `ftp`) to the Singularity Files app.  Register each provider with
     * the file manager by calling its `add_provider` method.
     */
    public interface FileProvider : Object {
        /** Human-readable name shown in the sidebar (e.g. `Network (SMB)`). */
        public abstract string name { get; }
        /** Symbolic icon name representing this provider. */
        public abstract string icon_name { get; }
        /** URI scheme this provider handles (e.g. `smb`, `recent`). */
        public abstract string scheme { get; }

        /**
         * Mounts the location identified by `uri` if necessary.
         *
         * @param uri         URI of the location to mount.
         * @param cancellable Optional cancellable.
         * @return `true` if mounted successfully (or already mounted).
         */
        public abstract async bool mount(string uri, Cancellable? cancellable = null) throws Error;

        /**
         * Lists the children of the directory at `uri`.
         *
         * @param uri         Directory URI to enumerate.
         * @param cancellable Optional cancellable.
         * @return List of FileItem objects.
         */
        public abstract async List<FileItem> enumerate(string uri, Cancellable? cancellable = null) throws Error;

        /**
         * Returns metadata for the file at `uri`, or null if not found.
         *
         * @param uri         URI of the file.
         * @param cancellable Optional cancellable.
         * @return A FileItem or null.
         */
        public abstract async FileItem? get_info(string uri, Cancellable? cancellable = null) throws Error;
    }

    /**
     * Lightweight value object that wraps a GLib.File and its GLib.FileInfo
     * for display in the Files UI.
     */
    public class FileItem : Object {
        /** The underlying GIO file object. */
        public File file { get; construct; }
        /** File metadata provided by GIO. */
        public FileInfo info { get; construct; }
        /** Display name of the file (from `standard::name`). */
        public string name { get; construct; }
        /** Icon name string for this file (from `standard::icon`). */
        public string icon_name { get; construct; }
        /** Full URI of this file. */
        public string uri { get; construct; }
        /** `true` if the entry is a directory. */
        public bool is_folder { get; construct; }

        /**
         * Creates a new FileItem from a GIO File and its FileInfo.
         *
         * @param f The file object.
         * @param i The corresponding file info (must include `standard::*` attributes).
         */
        public FileItem(File f, FileInfo i) {
            Object(
                file: f,
                info: i,
                name: i.get_name(),
                icon_name: i.get_icon().to_string(),
                uri: f.get_uri(),
                is_folder: i.get_file_type() == FileType.DIRECTORY
            );
        }
    }
}
