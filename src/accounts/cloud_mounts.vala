namespace Singularity.Accounts {

    [DBus (name = "dev.sinty.CloudMount")]
    internal interface CloudMountBus : Object {
        public abstract async HashTable<string, Variant>[] list_mounts() throws Error;
        public abstract async void mount(string account_id) throws Error;
        public abstract async void unmount(string account_id) throws Error;
        public abstract async void set_keep_offline(string[] paths, bool keep) throws Error;
        public abstract async string get_link(string path) throws Error;
        public signal void mounts_changed();
    }

    /**
     * The files of one online account shown as a real folder, as listed by
     * CloudMounts. Every program can use the folder like any other.
     */
    public class CloudMount : Object {
        /** Account identifier. */
        public string account_id { get; construct; }
        /** Account name, also the name of the folder. */
        public string name { get; construct; }
        /** Folder to show to the user, `~/Cloud/<name>`. */
        public string path { get; construct; }
        /** Where the drive is mounted; `path` is a link to it. */
        public string mountpoint { get; construct; }
        /** Provider identifier, such as "google". */
        public string provider { get; construct; }
        /** Translated provider name. */
        public string provider_name { get; construct; }
        /** Full colour icon of the provider. */
        public string icon_name { get; construct; }
        /** "online", "syncing", "offline" or "attention". */
        public string status { get; construct; }
        /** Files saved locally and not uploaded yet. */
        public uint pending { get; construct; }
        /** Bytes used on the server, or -1 when unknown. */
        public int64 used { get; construct; }
        /** Storage size on the server, or -1 when unknown. */
        public int64 total { get; construct; }
        /** True when get_link() can make sharing links for this drive. */
        public bool can_share { get; construct; }
        /** Bytes moved so far by the downloads and uploads running now. */
        public int64 transferred { get; construct; }
        /** Total size of the downloads and uploads running now, or 0 when there are none. */
        public int64 transfer_size { get; construct; }

        internal CloudMount(HashTable<string, Variant> d) {
            string icon = str(d, "icon");
            if (icon == "") icon = "singularity-account-generic";
            Object(
                account_id: str(d, "account-id"),
                name: str(d, "name"),
                path: str(d, "path"),
                mountpoint: str(d, "mountpoint"),
                provider: str(d, "provider"),
                provider_name: str(d, "provider-name"),
                icon_name: icon,
                status: str(d, "status"),
                pending: d["pending"] != null && d["pending"].is_of_type(VariantType.UINT32) ? d["pending"].get_uint32() : 0,
                used: d["used"] != null && d["used"].is_of_type(VariantType.INT64) ? d["used"].get_int64() : -1,
                total: d["total"] != null && d["total"].is_of_type(VariantType.INT64) ? d["total"].get_int64() : -1,
                can_share: d["can-share"] != null && d["can-share"].is_of_type(VariantType.BOOLEAN) && d["can-share"].get_boolean(),
                transferred: d["transferred"] != null && d["transferred"].is_of_type(VariantType.INT64) ? d["transferred"].get_int64() : 0,
                transfer_size: d["transfer-size"] != null && d["transfer-size"].is_of_type(VariantType.INT64) ? d["transfer-size"].get_int64() : 0
            );
        }

        private static string str(HashTable<string, Variant> d, string key) {
            var v = d[key];
            return v != null && v.is_of_type(VariantType.STRING) ? v.get_string() : "";
        }

        /** Symbolic glyph of the provider, for sidebar rows. */
        public string symbolic_icon_name {
            owned get { return icon_name + "-symbolic"; }
        }

        /** True when `file_path` is the drive folder or inside it. */
        public bool contains(string file_path) {
            foreach (string root in new string[] { path, mountpoint }) {
                if (root == "") continue;
                if (file_path == root || file_path.has_prefix(root + "/")) return true;
            }
            return false;
        }
    }

    /**
     * Online account drives mounted as folders by the cloud mount service
     * (`dev.sinty.CloudMount`). Each account with its Files capability
     * switched on appears as `~/Cloud/<account name>`; files are downloaded
     * when opened and uploaded when closed.
     *
     * {{{
     * var mounts = CloudMounts.get_default();
     * yield mounts.load();
     * var drive = mounts.for_account(account.id);
     * if (drive != null) open_folder(drive.path);
     * }}}
     */
    public class CloudMounts : Object {
        public const string BUS_NAME = "dev.sinty.CloudMount";
        public const string OBJECT_PATH = "/dev/sinty/CloudMount";
        /** Extended attribute that is "1" for files kept offline. */
        public const string OFFLINE_ATTRIBUTE = "xattr::singularity.offline";

        private static CloudMounts? instance;
        private CloudMountBus? bus;
        private Gee.ArrayList<CloudMount> list = new Gee.ArrayList<CloudMount>();
        private bool loading;
        private bool loaded_once;
        private uint watch_id;

        /** False when the service is not installed or not running. */
        public bool available { get; private set; default = false; }

        /** Emitted whenever a drive was mounted, unmounted or changed status. */
        public signal void changed();

        /** Returns the shared instance. */
        public static CloudMounts get_default() {
            if (instance == null) instance = new CloudMounts();
            return instance;
        }

        private CloudMounts() {
        }

        /** The mounted drives. */
        public Gee.List<CloudMount> mounts {
            owned get { return list.read_only_view; }
        }

        private async CloudMountBus get_bus() throws Error {
            if (bus != null) return bus;
            bus = yield Bus.get_proxy<CloudMountBus>(BusType.SESSION, BUS_NAME, OBJECT_PATH, DBusProxyFlags.DO_NOT_LOAD_PROPERTIES);
            bus.mounts_changed.connect(() => refresh.begin());
            if (watch_id == 0) {
                watch_id = Bus.watch_name(BusType.SESSION, BUS_NAME, BusNameWatcherFlags.NONE,
                    () => { if (loaded_once) refresh.begin(); },
                    () => {
                        if (list.size == 0 && !available) return;
                        list.clear();
                        available = false;
                        changed();
                    });
            }
            return bus;
        }

        /**
         * Loads the list, starting the service when it is installed. Calling
         * it again does nothing; the list follows the service afterwards.
         */
        public async void load() {
            if (loaded_once) return;
            if (loading) {
                while (loading) {
                    Idle.add(load.callback);
                    yield;
                }
                return;
            }
            loading = true;
            yield refresh();
            loaded_once = true;
            loading = false;
        }

        /** Reloads the list from the service. */
        public async void refresh() {
            try {
                var b = yield get_bus();
                var fresh = new Gee.ArrayList<CloudMount>();
                foreach (var d in yield b.list_mounts()) fresh.add(new CloudMount(d));
                list = fresh;
                available = true;
            } catch (Error e) {
                list.clear();
                available = false;
            }
            changed();
        }

        /** The drive of an account, or null when it is not mounted. */
        public CloudMount? for_account(string account_id) {
            foreach (var m in list) if (m.account_id == account_id) return m;
            return null;
        }

        /** The drive a local path belongs to, or null for other paths. */
        public CloudMount? for_path(string path) {
            foreach (var m in list) if (m.contains(path)) return m;
            return null;
        }

        /** Mounts an account's drive again after unmount(). */
        public async void mount(string account_id) throws Error {
            var b = yield get_bus();
            yield b.mount(account_id);
            yield refresh();
        }

        /**
         * Unmounts an account's drive until mount() is called or the session
         * starts again. Changes not uploaded yet are uploaded next time.
         */
        public async void unmount(string account_id) throws Error {
            var b = yield get_bus();
            yield b.unmount(account_id);
            yield refresh();
        }

        /**
         * Keeps files, or every file of folders, downloaded so they open
         * without a connection, or lets the cache drop them again.
         */
        public async void set_keep_offline(string[] paths, bool keep) throws Error {
            var b = yield get_bus();
            yield b.set_keep_offline(paths, keep);
        }

        /** True when a file or folder of a drive is kept offline. */
        public static bool is_kept_offline(File file) {
            try {
                var info = file.query_info(OFFLINE_ATTRIBUTE, FileQueryInfoFlags.NONE);
                return info.get_attribute_as_string(OFFLINE_ATTRIBUTE) == "1";
            } catch (Error e) {
                return false;
            }
        }

        /**
         * Returns a sharing link for a file of a drive. Throws
         * `dev.sinty.CloudMount.Error.NotSupported` when the provider offers
         * none; see CloudMount.can_share.
         */
        public async string get_link(string path) throws Error {
            var b = yield get_bus();
            return yield b.get_link(path);
        }
    }

    /**
     * A CloudDrive over the mounted folder of an account; ids are absolute
     * paths. Files opened through it are the real files of the drive, so an
     * app saves to them like to any local file.
     */
    public class MountedCloudDrive : Object, CloudDrive {
        private Account _account;
        private string _root;

        public Account account { get { return _account; } }
        public string root_id { get { return _root; } }

        private const string ATTRIBUTES = "standard::name,standard::display-name,standard::type,standard::size,standard::content-type,time::modified,etag::value";

        public MountedCloudDrive(Account account, string root) {
            _account = account;
            _root = root;
        }

        private CloudEntry entry_of(File file, FileInfo info) {
            var e = new CloudEntry();
            e.id = file.get_path();
            var parent = file.get_parent();
            e.parent_id = parent != null ? parent.get_path() : "";
            e.name = info.get_name();
            e.is_folder = info.get_file_type() == FileType.DIRECTORY;
            e.size = e.is_folder ? -1 : info.get_size();
            if (e.is_folder) {
                e.content_type = "inode/directory";
            } else {
                string? mime = info.get_content_type() != null ? ContentType.get_mime_type(info.get_content_type()) : null;
                e.content_type = mime ?? CloudDrive.guess_type(e.name);
            }
            e.etag = info.get_etag() ?? "";
            e.modified = info.get_modification_date_time();
            return e;
        }

        public async Gee.List<CloudEntry> list(string folder_id, Cancellable? cancellable = null) throws Error {
            var result = new Gee.ArrayList<CloudEntry>();
            var dir = File.new_for_path(folder_id);
            var en = yield dir.enumerate_children_async(ATTRIBUTES, FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);
            while (true) {
                var infos = yield en.next_files_async(100, Priority.DEFAULT, cancellable);
                if (infos == null) break;
                foreach (var info in infos) result.add(entry_of(dir.get_child(info.get_name()), info));
            }
            return result;
        }

        public async CloudEntry stat(string id, Cancellable? cancellable = null) throws Error {
            var file = File.new_for_path(id);
            return entry_of(file, yield file.query_info_async(ATTRIBUTES, FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable));
        }

        public async void download_to(CloudEntry entry, OutputStream output, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            var input = yield File.new_for_path(entry.id).read_async(Priority.DEFAULT, cancellable);
            int64 total = entry.size;
            int64 done = 0;
            if (progress != null) progress(0, total);
            while (true) {
                var chunk = yield input.read_bytes_async(128 * 1024, Priority.DEFAULT, cancellable);
                if (chunk.get_size() == 0) break;
                size_t written;
                yield output.write_all_async(chunk.get_data(), Priority.DEFAULT, cancellable, out written);
                done += (int64) chunk.get_size();
                if (progress != null) progress(done, total);
            }
            yield input.close_async(Priority.DEFAULT, null);
        }

        private static async void copy_file(File source, File target, Cancellable? cancellable, TransferProgress? progress) throws Error {
            yield source.copy_async(target, FileCopyFlags.OVERWRITE, Priority.DEFAULT, cancellable, (current, total) => {
                if (progress != null) progress(current, total);
            });
        }

        public async void download(CloudEntry entry, File destination, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            yield copy_file(File.new_for_path(entry.id), destination, cancellable, progress);
        }

        public async CloudEntry upload(string folder_id, string name, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            var target = File.new_for_path(folder_id).get_child(name);
            yield copy_file(source, target, cancellable, progress);
            return yield stat(target.get_path(), cancellable);
        }

        public async CloudEntry replace(CloudEntry entry, File source, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            yield copy_file(source, File.new_for_path(entry.id), cancellable, progress);
            return yield stat(entry.id, cancellable);
        }

        public async CloudEntry move(CloudEntry entry, string folder_id, string? new_name = null, Cancellable? cancellable = null) throws Error {
            var target = File.new_for_path(folder_id).get_child(new_name ?? entry.name);
            yield File.new_for_path(entry.id).move_async(target, FileCopyFlags.NONE, Priority.DEFAULT, cancellable, null);
            return yield stat(target.get_path(), cancellable);
        }

        public async CloudEntry rename(CloudEntry entry, string new_name, Cancellable? cancellable = null) throws Error {
            var renamed = yield File.new_for_path(entry.id).set_display_name_async(new_name, Priority.DEFAULT, cancellable);
            return yield stat(renamed.get_path(), cancellable);
        }

        public async void delete(CloudEntry entry, Cancellable? cancellable = null) throws Error {
            yield File.new_for_path(entry.id).delete_async(Priority.DEFAULT, cancellable);
        }

        public async CloudEntry create_folder(string parent_id, string name, Cancellable? cancellable = null) throws Error {
            var dir = File.new_for_path(parent_id).get_child(name);
            yield dir.make_directory_async(Priority.DEFAULT, cancellable);
            return yield stat(dir.get_path(), cancellable);
        }
    }
}
