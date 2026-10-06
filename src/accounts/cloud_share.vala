namespace Singularity.Accounts {

    public class CloudLocation : Object {
        public string account_id { get; construct; }
        public string entry_id { get; construct; }
        public string name { get; construct; }
        public bool is_folder { get; construct; }

        public CloudLocation(string account_id, string entry_id, string name, bool is_folder = false) {
            Object(account_id: account_id, entry_id: entry_id, name: name, is_folder: is_folder);
        }
    }

    public delegate CloudLocation? CloudLocator(File file);

    public class SharedFile : Object {
        public SharedLink link { get; construct; }
        public CloudEntry? uploaded { get; construct; }
        public File? source { get; construct; }

        public SharedFile(SharedLink link, CloudEntry? uploaded, File? source) {
            Object(link: link, uploaded: uploaded, source: source);
        }
    }

    public class CloudShare : Object {
        public const string XATTR_ACCOUNT = "xattr::singularity.cloud-account";
        public const string XATTR_ENTRY = "xattr::singularity.cloud-id";

        private class LocatorEntry {
            public CloudLocator func;
            public LocatorEntry(owned CloudLocator func) {
                this.func = (owned) func;
            }
        }

        private static Gee.ArrayList<LocatorEntry>? locators;

        public static void add_locator(owned CloudLocator locator) {
            if (locators == null) locators = new Gee.ArrayList<LocatorEntry>();
            locators.add(new LocatorEntry((owned) locator));
        }

        public static CloudLocation? locate(File file) {
            var working = CloudFile.for_local(file);
            if (working != null) return new CloudLocation(working.account_id, working.entry.id, working.entry.name, working.entry.is_folder);
            if (locators != null) {
                foreach (var l in locators) {
                    var found = l.func(file);
                    if (found != null) return found;
                }
            }
            try {
                var info = file.query_info(XATTR_ACCOUNT + "," + XATTR_ENTRY + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_NAME,
                    FileQueryInfoFlags.NONE, null);
                string? account = info.get_attribute_string(XATTR_ACCOUNT);
                string? entry = info.get_attribute_string(XATTR_ENTRY);
                if (account != null && account != "" && entry != null && entry != "") {
                    return new CloudLocation(account, entry, file.get_basename() ?? entry, info.get_file_type() == FileType.DIRECTORY);
                }
            } catch (Error e) {
            }
            return null;
        }

        public static Gee.List<Account> link_accounts() {
            var result = new Gee.ArrayList<Account>();
            foreach (var account in Manager.get_default().get_accounts_for(Capability.FILES)) {
                if (!account.healthy) continue;
                if (CloudDrive.for_account(account) != null && LinkSharing.for_account(account) != null) result.add(account);
            }
            return result;
        }

        private static string settings_path() {
            return Path.build_filename(Environment.get_user_config_dir(), "singularity", "share.ini");
        }

        private static KeyFile load_settings() {
            var kf = new KeyFile();
            try {
                kf.load_from_file(settings_path(), KeyFileFlags.NONE);
            } catch (Error e) {
            }
            return kf;
        }

        private static void save_settings(KeyFile kf) {
            try {
                DirUtils.create_with_parents(Path.get_dirname(settings_path()), 0700);
                FileUtils.set_contents(settings_path(), kf.to_data());
            } catch (Error e) {
                warning("share: %s", e.message);
            }
        }

        public static string last_account_id {
            owned get {
                try {
                    return load_settings().get_string("Links", "account");
                } catch (Error e) {
                    return "";
                }
            }
            set {
                var kf = load_settings();
                kf.set_string("Links", "account", value);
                save_settings(kf);
            }
        }

        public static LinkAccess last_access {
            get {
                try {
                    return LinkAccess.from_id(load_settings().get_string("Links", "access"));
                } catch (Error e) {
                    return LinkAccess.VIEW;
                }
            }
            set {
                var kf = load_settings();
                kf.set_string("Links", "access", value.to_id());
                save_settings(kf);
            }
        }

        public static Account? default_account() {
            var accounts = link_accounts();
            string last = last_account_id;
            foreach (var a in accounts) if (a.id == last) return a;
            return accounts.size > 0 ? accounts[0] : null;
        }

        public static async SharedLink link_location(CloudLocation location, LinkAccess access, DateTime? expires = null, Cancellable? cancellable = null) throws Error {
            var manager = Manager.get_default();
            yield manager.load();
            var account = manager.get_account(location.account_id);
            if (account == null) throw new AccountsError.NOT_FOUND(_("The online account of this file is no longer available"));
            var links = LinkSharing.for_account(account);
            if (links == null) throw new AccountsError.INVALID(_("%s cannot create links").printf(account.display_name));
            var entry = new CloudEntry();
            entry.id = location.entry_id;
            entry.name = location.name;
            entry.is_folder = location.is_folder;
            return yield links.create_link(entry, access, links.supports_expiry ? expires : null, cancellable);
        }

        public static async SharedLink link_entry(string account_id, string entry_id, LinkAccess access = LinkAccess.VIEW, DateTime? expires = null, Cancellable? cancellable = null) throws Error {
            return yield link_location(new CloudLocation(account_id, entry_id, ""), access, expires, cancellable);
        }

        private static async string share_folder(CloudDrive drive, Cancellable? cancellable) throws Error {
            string wanted = _("Shared");
            foreach (var e in yield drive.list(drive.root_id, cancellable)) {
                if (e.is_folder && e.name == wanted) return e.id;
            }
            var folder = yield drive.create_folder(drive.root_id, wanted, cancellable);
            return folder.id;
        }

        private static string free_name(Gee.List<CloudEntry> existing, string name) {
            var taken = new Gee.HashSet<string>();
            foreach (var e in existing) taken.add(e.name.down());
            if (!(name.down() in taken)) return name;
            int dot = name.last_index_of(".");
            string stem = dot > 0 ? name.substring(0, dot) : name;
            string ext = dot > 0 ? name.substring(dot) : "";
            for (int i = 2; i < 1000; i++) {
                string candidate = "%s (%d)%s".printf(stem, i, ext);
                if (!(candidate.down() in taken)) return candidate;
            }
            return "%s %s%s".printf(stem, Uuid.string_random().substring(0, 8), ext);
        }

        public static async CloudEntry upload(Account account, File file, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            var drive = CloudDrive.for_account(account);
            if (drive == null) throw new AccountsError.INVALID(_("%s has no files").printf(account.display_name));
            string folder = yield share_folder(drive, cancellable);
            var existing = yield drive.list(folder, cancellable);
            return yield drive.upload(folder, free_name(existing, file.get_basename() ?? "file"), file, cancellable, progress);
        }

        public static async SharedFile share_file(File file, Account? target, LinkAccess access, DateTime? expires = null, Cancellable? cancellable = null, TransferProgress? progress = null) throws Error {
            yield Manager.get_default().load();
            var location = locate(file);
            if (location != null) {
                var link = yield link_location(location, access, expires, cancellable);
                return new SharedFile(link, null, file);
            }
            if (target == null) throw new AccountsError.INVALID(_("Choose an online account to upload to"));
            var links = LinkSharing.for_account(target);
            if (links == null) throw new AccountsError.INVALID(_("%s cannot create links").printf(target.display_name));
            var entry = yield upload(target, file, cancellable, progress);
            try {
                var link = yield links.create_link(entry, access, links.supports_expiry ? expires : null, cancellable);
                last_account_id = target.id;
                return new SharedFile(link, entry, file);
            } catch (Error e) {
                var drive = CloudDrive.for_account(target);
                if (drive != null) {
                    try {
                        yield drive.delete(entry, null);
                    } catch (Error ignored) {
                    }
                }
                throw e;
            }
        }

        public static async void unshare(SharedFile shared, Cancellable? cancellable = null) throws Error {
            yield Manager.get_default().load();
            var account = Manager.get_default().get_account(shared.link.account_id);
            if (account == null) throw new AccountsError.NOT_FOUND(_("The online account of this file is no longer available"));
            var links = LinkSharing.for_account(account);
            if (links != null) yield links.remove_link(shared.link, cancellable);
            if (shared.uploaded != null) {
                var drive = CloudDrive.for_account(account);
                if (drive != null) yield drive.delete(shared.uploaded, cancellable);
            }
        }

        public static async void remove_link(SharedLink link, Cancellable? cancellable = null) throws Error {
            yield unshare(new SharedFile(link, null, null), cancellable);
        }
    }
}
