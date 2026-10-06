namespace Singularity.Accounts {

    /**
     * A kind of account the service can add, as listed by
     * Manager.list_providers().
     */
    public class ProviderInfo : Object {
        /** Provider identifier passed to add_account() or begin_sign_in(). */
        public string id { get; construct; }
        /** Translated name. */
        public string name { get; construct; }
        /** One-line translated description. */
        public string description { get; construct; }
        /** Full colour icon name. */
        public string icon_name { get; construct; }
        /** "password", "oauth2" or "login-flow". */
        public string auth { get; construct; }
        /** Capabilities an account of this kind can offer. */
        public string[] capabilities { get; construct; }
        /**
         * False when the provider signs in with OAuth and the system has no
         * client registration for it; the browser sign-in is then unavailable.
         */
        public bool configured { get; construct; }
        /**
         * Where the active OAuth client comes from: "built-in" (compiled
         * into the service), "distribution" (a data directory file),
         * "system" (/etc), "user" (the per-user override) or an empty
         * string when there is none. Only set for OAuth providers.
         */
        public string client_source { get; construct; }
        /** File the active OAuth client was read from, or an empty string. */
        public string client_path { get; construct; }
        /** Active OAuth client id; the secret is never exposed. */
        public string client_id { get; construct; }
        /** True when the active OAuth client has a secret. */
        public bool client_has_secret { get; construct; }

        public ProviderInfo(HashTable<string, Variant> data) {
            Object(
                id: str(data, "id"),
                name: str(data, "name"),
                description: str(data, "description"),
                icon_name: str(data, "icon"),
                auth: str(data, "auth"),
                capabilities: data.lookup("capabilities") != null && data.lookup("capabilities").is_of_type(VariantType.STRING_ARRAY)
                    ? data.lookup("capabilities").dup_strv() : new string[0],
                configured: data.lookup("configured") != null && data.lookup("configured").is_of_type(VariantType.BOOLEAN)
                    ? data.lookup("configured").get_boolean() : true,
                client_source: str(data, "client-source"),
                client_path: str(data, "client-path"),
                client_id: str(data, "client-id"),
                client_has_secret: data.lookup("client-has-secret") != null && data.lookup("client-has-secret").is_of_type(VariantType.BOOLEAN)
                    && data.lookup("client-has-secret").get_boolean()
            );
        }

        private static string str(HashTable<string, Variant> data, string key) {
            var v = data.lookup(key);
            return v != null && v.is_of_type(VariantType.STRING) ? v.get_string() : "";
        }
    }

    /**
     * Entry point of the online accounts client API.
     *
     * Obtain the shared instance with get_default() and call load() once;
     * afterwards the account list follows the service through the
     * account_added, account_removed and account_changed signals.
     *
     * {{{
     * var manager = Singularity.Accounts.Manager.get_default();
     * yield manager.load();
     * foreach (var account in manager.get_accounts_for(Capability.CALENDAR)) {
     *     var creds = yield account.get_credentials(Capability.CALENDAR);
     * }
     * }}}
     */
    public class Manager : Object {
        public const string BUS_NAME = "dev.sinty.Accounts";
        public const string OBJECT_PATH = "/dev/sinty/Accounts";

        private static Manager? instance;
        private ServiceBus? bus;
        private Gee.ArrayList<Account> accounts = new Gee.ArrayList<Account>();
        private bool loading;
        private bool loaded_once;
        private uint watch_id;

        /** False when the accounts service could not be reached. */
        public bool available { get; private set; default = false; }
        /** Message of the last failure to reach the service. */
        public string last_error { get; private set; default = ""; }

        /** Emitted after an account was added. */
        public signal void account_added(Account account);
        /** Emitted after an account was removed; the object is no longer listed. */
        public signal void account_removed(Account account);
        /** Emitted when an account's metadata or capabilities changed. */
        public signal void account_changed(Account account);
        /** Emitted when an account needs the user to sign in again. */
        public signal void needs_attention(Account account, string reason);
        /** Emitted when a browser sign-in started with begin_sign_in() ended. */
        public signal void sign_in_finished(string flow_id, string account_id, string error_message);
        /**
         * Emitted when a sign-in window opened with open_sign_in_window()
         * closes; `switched_to_browser` is true when the provider refused the
         * window and the user continued in the browser instead.
         */
        public signal void sign_in_window_closed(string flow_id, bool switched_to_browser);
        /** Emitted after the list was loaded or reloaded as a whole. */
        public signal void reloaded();

        /** Returns the shared manager. */
        public static Manager get_default() {
            if (instance == null) instance = new Manager();
            return instance;
        }

        private Manager() {
        }

        internal async ServiceBus get_bus() throws Error {
            if (bus != null) return bus;
            try {
                bus = yield Bus.get_proxy<ServiceBus>(BusType.SESSION, BUS_NAME, OBJECT_PATH, DBusProxyFlags.DO_NOT_LOAD_PROPERTIES);
            } catch (Error e) {
                available = false;
                last_error = e.message;
                throw new AccountsError.UNAVAILABLE(_("The accounts service is not available: %s").printf(e.message));
            }
            ((DBusProxy) bus).set_default_timeout(120000);
            bus.account_added.connect((id) => refresh_one.begin(id, true));
            bus.account_changed.connect((id) => {
                var account = get_account(id);
                if (account != null) account.forget_tokens();
                refresh_one.begin(id, false);
            });
            bus.account_removed.connect((id) => {
                var account = get_account(id);
                if (account == null) return;
                accounts.remove(account);
                account.detach();
                account_removed(account);
            });
            bus.needs_attention.connect((id, reason) => {
                var account = get_account(id);
                if (account == null) return;
                account.forget_tokens();
                refresh_one.begin(id, false, (obj, res) => {
                    refresh_one.end(res);
                    needs_attention(account, reason);
                });
            });
            bus.sign_in_finished.connect((flow, account_id, error_message) => sign_in_finished(flow, account_id, error_message));
            if (watch_id == 0) {
                watch_id = Bus.watch_name(BusType.SESSION, BUS_NAME, BusNameWatcherFlags.NONE, null, () => {
                    if (loaded_once) reload.begin();
                });
            }
            return bus;
        }

        /**
         * Loads the account list, starting the service when needed. Calling it
         * again after a successful load does nothing; use reload() to force.
         */
        public async void load() {
            if (loaded_once || loading) {
                while (loading) {
                    Idle.add(load.callback);
                    yield;
                }
                return;
            }
            yield reload();
        }

        /** Reloads every account from the service. */
        public async void reload() {
            loading = true;
            try {
                var b = yield get_bus();
                var list = yield b.list_accounts();
                var seen = new Gee.HashSet<string>();
                foreach (var data in list) {
                    var idv = data.lookup("id");
                    if (idv == null) continue;
                    string id = idv.get_string();
                    seen.add(id);
                    var account = get_account(id);
                    if (account == null) {
                        account = new Account(id);
                        account.manager = this;
                        account.update(data);
                        accounts.add(account);
                        if (loaded_once) account_added(account);
                    } else {
                        account.update(data);
                        if (loaded_once) account_changed(account);
                    }
                }
                foreach (var account in accounts.to_array()) {
                    if (!seen.contains(account.id)) {
                        accounts.remove(account);
                        account.detach();
                        if (loaded_once) account_removed(account);
                    }
                }
                available = true;
                last_error = "";
            } catch (Error e) {
                available = false;
                last_error = e.message;
                warning("accounts: %s", e.message);
            }
            loaded_once = true;
            loading = false;
            reloaded();
        }

        private async void refresh_one(string id, bool added) {
            try {
                var b = yield get_bus();
                foreach (var data in yield b.list_accounts()) {
                    var idv = data.lookup("id");
                    if (idv == null || idv.get_string() != id) continue;
                    var account = get_account(id);
                    if (account == null) {
                        account = new Account(id);
                        account.manager = this;
                        account.update(data);
                        accounts.add(account);
                        account_added(account);
                    } else {
                        account.update(data);
                        account_changed(account);
                    }
                    return;
                }
            } catch (Error e) {
                warning("accounts: %s", e.message);
            }
        }

        /** All accounts, in the order the service lists them. */
        public Gee.List<Account> get_accounts() {
            return accounts.read_only_view;
        }

        /** Accounts that offer the capability and have it switched on. */
        public Gee.List<Account> get_accounts_for(Capability capability) {
            var result = new Gee.ArrayList<Account>();
            foreach (var a in accounts) if (a.has_capability(capability)) result.add(a);
            return result;
        }

        /** Returns the account with the identifier, or null. */
        public Account? get_account(string id) {
            foreach (var a in accounts) if (a.id == id) return a;
            return null;
        }

        /** Lists the kinds of account the service can add. */
        public async Gee.List<ProviderInfo> list_providers() throws Error {
            var b = yield get_bus();
            var result = new Gee.ArrayList<ProviderInfo>();
            foreach (var data in yield b.list_providers()) result.add(new ProviderInfo(data));
            return result;
        }

        /**
         * Adds a password based account. The service checks the credentials
         * against the server before storing anything.
         *
         * @param provider Provider identifier.
         * @param settings Provider fields such as "server", "username",
         *                 "email", "imap-host"; see docs/online-accounts.md.
         * @param secret   Password or app password.
         * @return The new account identifier.
         */
        public async string add_account(string provider, HashTable<string, Variant> settings, string secret) throws Error {
            var b = yield get_bus();
            string id = yield b.add_account(provider, settings, secret);
            yield refresh_one(id, true);
            return id;
        }

        /**
         * Starts a browser sign-in (OAuth2 or Nextcloud Login Flow). Open the
         * returned address in the browser, then wait for sign_in_finished with
         * the same flow identifier.
         *
         * @param provider Provider identifier.
         * @param settings "server" for Nextcloud, "account" to sign an existing
         *                 account in again.
         * @param url      Address to open in the browser.
         * @return The flow identifier.
         */
        public async string begin_sign_in(string provider, HashTable<string, Variant> settings, out string url) throws Error {
            var b = yield get_bus();
            string flow;
            string address;
            yield b.begin_sign_in(provider, settings, out flow, out address);
            url = address;
            return flow;
        }

        /**
         * Finishes a browser sign-in with the address the browser showed
         * after the user approved, for browsers that cannot reach this
         * computer's loopback address (sandboxed or remote browsers). The
         * address must carry the flow's state and an authorization code;
         * sign_in_finished follows as usual.
         */
        public async void complete_sign_in(string flow_id, string address) throws Error {
            var b = yield get_bus();
            yield b.complete_sign_in(flow_id, address);
        }

        /**
         * Opens the in-house sign-in window for a flow started with
         * begin_sign_in(). The window loads the provider page in an
         * ephemeral web view and hands the redirect to the service itself,
         * so the user's browser and its sandbox play no part. Returns false
         * when the window is not installed; open the address in the
         * browser then.
         *
         * @param flow_id       Flow identifier.
         * @param url           Address returned by begin_sign_in().
         * @param provider_name Provider name for the window title.
         * @param provider_icon Full colour provider icon for status pages.
         */
        public async bool open_sign_in_window(string flow_id, string url, string provider_name, string provider_icon = "") {
            try {
                var b = yield get_bus();
                string helper = yield b.get_sign_in_helper();
                if (helper == "") return false;
                string[] argv = { helper, "--flow", flow_id, "--url", url, "--provider-name", provider_name, "--provider-icon", provider_icon };
                Pid pid;
                Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH_FROM_ENVP | SpawnFlags.DO_NOT_REAP_CHILD, null, out pid);
                ChildWatch.add(pid, (p, status) => {
                    Process.close_pid(p);
                    sign_in_window_closed(flow_id, Process.if_exited(status) && Process.exit_status(status) == 3);
                });
                return true;
            } catch (Error e) {
                warning("accounts: cannot open the sign-in window: %s", e.message);
                return false;
            }
        }

        /** Cancels a browser sign-in. */
        public async void cancel_sign_in(string flow_id) {
            try {
                var b = yield get_bus();
                yield b.cancel_sign_in(flow_id);
            } catch (Error e) {
                warning("accounts: %s", e.message);
            }
        }

        /** Removes the account and every secret the service stored for it. */
        public async void remove_account(Account account) throws Error {
            var b = yield get_bus();
            yield b.remove_account(account.id);
        }

        /** Switches a capability of an account on or off. */
        public async void set_capability_enabled(Account account, Capability capability, bool enabled) throws Error {
            var b = yield get_bus();
            yield b.set_capability_enabled(account.id, capability.to_id(), enabled);
        }

        /** Switches Microsoft mail between Graph and the IMAP and SMTP fallback; NEEDS_REAUTH asks for consent first. */
        public async void set_mail_imap_fallback(Account account, bool enabled) throws Error {
            var b = yield get_bus();
            yield b.set_capability_enabled(account.id, "mail-imap", enabled);
            account.forget_tokens();
        }

        /** Renames an account. */
        public async void set_display_name(Account account, string name) throws Error {
            var b = yield get_bus();
            yield b.set_display_name(account.id, name);
        }

        /** Replaces the password of a password based account after checking it. */
        public async void update_password(Account account, string secret) throws Error {
            var b = yield get_bus();
            yield b.update_password(account.id, secret);
            account.forget_tokens();
        }

        /**
         * Stores a per-user OAuth client for a provider, overriding the one
         * the distribution installed. Empty values remove the override.
         */
        public async void set_oauth_client(string provider, string client_id, string client_secret) throws Error {
            var b = yield get_bus();
            yield b.set_oauth_client(provider, client_id, client_secret);
        }
    }
}
