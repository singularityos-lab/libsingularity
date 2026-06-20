using GLib;

namespace Singularity.Core.Users {

    [DBus (name = "org.freedesktop.Accounts")]
    public interface AccountsManager : Object {
        public abstract async ObjectPath create_user (string name, string fullname, int account_type) throws IOError;
        public abstract async void delete_user (int64 id, bool remove_files) throws IOError;
        public abstract async ObjectPath[] list_cached_users () throws IOError;
        [DBus (name = "ListUsers")]
        public abstract async ObjectPath[] list_users () throws IOError;
        public abstract async ObjectPath find_user_by_name (string name) throws IOError;
        public abstract async ObjectPath find_user_by_id (int64 id) throws IOError;
        [DBus (name = "UserAdded")]
        public signal void user_added (ObjectPath user);
        [DBus (name = "UserDeleted")]
        public signal void user_deleted (ObjectPath user);
    }
    [DBus (name = "org.freedesktop.Accounts.User")]
    public interface AccountUser : Object {
        public abstract string user_name { owned get; }
        public abstract string real_name { owned get; }
        public abstract int account_type { get; }
        public abstract bool automatic_login { get; }
        public abstract string home_directory { owned get; }
        public abstract string shell { owned get; }
        public abstract bool locked { get; }
        public abstract uint64 uid { get; }
        public abstract async void set_user_name (string name) throws IOError;
        public abstract async void set_real_name (string name) throws IOError;
        public abstract async void set_account_type (int account_type) throws IOError;
        public abstract async void set_password (string password, string hint) throws IOError;
        public abstract async void set_locked (bool locked) throws IOError;
        public abstract async void set_automatic_login (bool enabled) throws IOError;
    }
    [DBus (name = "org.freedesktop.DBus.Properties")]
    public interface AccountProperties : Object {
        [DBus (name = "Set")]
        public abstract async void set_prop (string iface, string name, Variant value) throws GLib.Error;
    }
    public class AccountsService : Object {
        private static AccountsService? instance;
        private AccountsManager? manager;
        private Gee.HashMap<string, AccountUser> user_cache = new Gee.HashMap<string, AccountUser>();
        public signal void user_added (AccountUser user);
        public signal void user_removed (AccountUser user);

        public static AccountsService get_default() {
            if (instance == null) {
                instance = new AccountsService();
            }
            return instance;
        }

        private AccountsService() {
            init_manager.begin();
        }

        private async void init_manager() {
            try {
                manager = yield Bus.get_proxy (BusType.SYSTEM, "org.freedesktop.Accounts", "/org/freedesktop/Accounts");
                manager.user_added.connect((path) => {
                    fetch_user.begin(path, (obj, res) => {
                        var user = fetch_user.end(res);
                        if (user != null) {
                            user_cache[path] = user;
                            user_added(user);
                        }
                    });
                });
                manager.user_deleted.connect((path) => {
                    var user = user_cache[path];
                    if (user != null) {
                        user_cache.unset(path);
                        user_removed(user);
                    }
                });
            } catch (IOError e) {
                warning("Failed to connect to AccountsService: %s", e.message);
            }
        }

        public async Gee.List<AccountUser> list_users() {
            var list = new Gee.ArrayList<AccountUser>();
            if (manager == null) return list;
            try {
                var paths = yield manager.list_users();
                foreach (var path in paths) {
                    var user = yield fetch_user(path);
                    if (user != null) list.add(user);
                }
            } catch (IOError e) {
                warning("Failed to list users: %s", e.message);
            }
            return list;
        }

        public async AccountUser? fetch_user(ObjectPath path) {
            try {
                return yield Bus.get_proxy (BusType.SYSTEM, "org.freedesktop.Accounts", path.to_string());
            } catch (IOError e) {
                warning("Failed to fetch user %s: %s", path.to_string(), e.message);
                return null;
            }
        }

        public async AccountUser? create_user(string name, string fullname, int type) throws IOError {
            if (manager == null) throw new IOError.FAILED("Manager not initialized");
            var path = yield manager.create_user(name, fullname, type);
            return yield fetch_user(path);
        }

        public async void delete_user(AccountUser user, bool remove_files) throws IOError {
            if (manager == null) throw new IOError.FAILED("Manager not initialized");
            yield manager.delete_user((int64)user.uid, remove_files);
        }

        // Persist a value under the com.singularity.Desktop AccountsService vendor
        // extension, so the greeter can read it per-user before login. The daemon
        // writes the world-readable keyfile after a polkit set-own-user-data check.
        public async void set_desktop_string(string key, string val) {
            if (manager == null) return;
            try {
                var path = yield manager.find_user_by_name(Environment.get_user_name());
                AccountProperties props = yield Bus.get_proxy(
                    BusType.SYSTEM, "org.freedesktop.Accounts", path);
                yield props.set_prop("com.singularity.Desktop", key, new Variant.string(val));
            } catch (GLib.Error e) {
                warning("Failed to persist %s to AccountsService: %s", key, e.message);
            }
        }

        public async AccountUser? get_current_user() {
            try {
                string user_name = Environment.get_user_name();
                if (manager != null) {
                    var path = yield manager.find_user_by_name(user_name);
                    return yield fetch_user(path);
                }
            } catch (IOError e) {
                warning("Failed to get current user: %s", e.message);
            }
            return null;
        }
    }
}
