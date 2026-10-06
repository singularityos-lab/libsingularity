namespace Singularity.Accounts {

    /**
     * One online account as described by the accounts service.
     *
     * Accounts are owned by Manager and updated in place when the service
     * reports a change; connect to `changed` to refresh views. Secrets are
     * never cached on disk by the client: tokens live in memory until they
     * expire.
     */
    public class Account : Object {
        /** Stable identifier. */
        public string id { get; construct; }
        /** Provider identifier, such as "nextcloud", "google" or "imap". */
        public string provider { get; private set; default = ""; }
        /** Translated provider name. */
        public string provider_name { get; private set; default = ""; }
        /** Name the user gave the account, or the identity. */
        public string display_name { get; private set; default = ""; }
        /** User name or address the account signs in with. */
        public string identity { get; private set; default = ""; }
        /** Full colour icon name of the provider. */
        public string icon_name { get; private set; default = "singularity-account-generic"; }
        /** "password" or "oauth2". */
        public string auth { get; private set; default = "password"; }
        /** Why the account needs attention, or an empty string when it works. */
        public string attention { get; private set; default = ""; }
        /** Base address of the server, when the provider has one. */
        public string server { get; private set; default = ""; }

        /** Emitted after the service reported new metadata. */
        public signal void changed();

        private string[] supported = {};
        private string[] enabled = {};
        private HashTable<string, string> endpoints = new HashTable<string, string>(str_hash, str_equal);
        private HashTable<string, string> tokens = new HashTable<string, string>(str_hash, str_equal);
        private HashTable<string, int64?> token_expiry = new HashTable<string, int64?>(str_hash, str_equal);
        private uint credential_revision;
        internal weak Manager? manager;

        internal Account(string id) {
            Object(id: id);
        }

        /** Symbolic glyph of the provider, for sidebar rows. */
        public string symbolic_icon_name {
            owned get { return icon_name + "-symbolic"; }
        }

        /** True when the account works and needs no action from the user. */
        public bool healthy {
            get { return attention == ""; }
        }

        internal void update(HashTable<string, Variant> data) {
            if (provider != lookup_string(data, "provider") || auth != lookup_string(data, "auth") ||
                identity != lookup_string(data, "identity") ||
                string.joinv("\n", supported) != string.joinv("\n", lookup_strv(data, "capabilities")) ||
                string.joinv("\n", enabled) != string.joinv("\n", lookup_strv(data, "enabled"))) {
                credential_revision++;
                forget_tokens();
            }
            provider = lookup_string(data, "provider");
            provider_name = lookup_string(data, "provider-name");
            display_name = lookup_string(data, "display-name");
            identity = lookup_string(data, "identity");
            string icon = lookup_string(data, "icon");
            icon_name = icon != "" ? icon : "singularity-account-generic";
            auth = lookup_string(data, "auth");
            attention = lookup_string(data, "attention");
            server = lookup_string(data, "server");
            supported = lookup_strv(data, "capabilities");
            enabled = lookup_strv(data, "enabled");
            endpoints.remove_all();
            var ep = data.lookup("endpoints");
            if (ep != null && ep.is_of_type(new VariantType("a{ss}"))) {
                var iter = ep.iterator();
                string key;
                string val;
                while (iter.next("{ss}", out key, out val)) endpoints.insert(key, val);
            }
            if (display_name == "") display_name = identity;
            changed();
        }

        private static string lookup_string(HashTable<string, Variant> data, string key) {
            var v = data.lookup(key);
            if (v == null || !v.is_of_type(VariantType.STRING)) return "";
            return v.get_string();
        }

        private static string[] lookup_strv(HashTable<string, Variant> data, string key) {
            var v = data.lookup(key);
            if (v == null || !v.is_of_type(VariantType.STRING_ARRAY)) return {};
            return v.dup_strv();
        }

        /** True when the provider offers the capability for this account. */
        public bool supports(Capability capability) {
            return capability.to_id() in supported;
        }

        /** True when the capability is offered and the user left it switched on. */
        public bool has_capability(Capability capability) {
            return supports(capability) && capability.to_id() in enabled;
        }

        /** Capabilities the provider offers for this account. */
        public Capability[] get_supported() {
            Capability[] result = {};
            foreach (var cap in Capability.all()) if (supports(cap)) result += cap;
            return result;
        }

        /**
         * Returns an endpoint value, such as "caldav", "carddav", "webdav",
         * "imap-host" or "files-api". See docs/online-accounts.md.
         *
         * @param key Endpoint key.
         * @return The value, or null when the account has none.
         */
        public string? get_endpoint(string key) {
            return endpoints.lookup(key);
        }

        /** Every endpoint key the account defines. */
        public string[] get_endpoint_keys() {
            string[] keys = {};
            endpoints.foreach((k, v) => keys += k);
            return keys;
        }

        /**
         * Returns credentials for talking to the service behind a capability.
         *
         * For OAuth accounts the service refreshes the access token when it
         * is about to expire; pass `refresh` to force a new one after a
         * server rejected the cached token.
         *
         * @param capability What the credentials will be used for.
         * @param refresh    Discard any cached token first.
         */
        public async AccountCredentials get_credentials(Capability capability, bool refresh = false) throws Error {
            check_credentials(capability, credential_revision);
            uint revision = credential_revision;
            if (auth == "oauth2") return yield get_token_credentials(capability, capability.to_id(), token_key(capability), refresh);
            if (manager == null) throw new AccountsError.UNAVAILABLE(_("The accounts service is not available"));
            var bus = yield manager.get_bus();
            check_credentials(capability, revision);
            string cap = capability.to_id();
            string username;
            string secret;
            string mechanism;
            yield bus.get_credentials(id, cap, out username, out secret, out mechanism);
            check_credentials(capability, revision);
            return new AccountCredentials(username, secret, mechanism);
        }

        /** Microsoft Graph Mail credentials, separate from Outlook IMAP and SMTP. */
        public async AccountCredentials get_graph_mail_credentials(bool refresh = false) throws Error {
            if (provider != "microsoft" || auth != "oauth2" || !has_capability(Capability.MAIL)) {
                throw new AccountsError.INVALID(_("This account does not offer Microsoft Graph mail"));
            }
            return yield get_token_credentials(Capability.MAIL, "mail-graph", "graph-mail", refresh);
        }

        private void check_credentials(Capability capability, uint revision) throws AccountsError {
            if (!has_capability(capability) || revision != credential_revision) {
                throw new AccountsError.INVALID(_("This account does not offer %s").printf(capability.to_id()));
            }
        }

        private async AccountCredentials get_token_credentials(Capability capability, string cap, string key, bool refresh) throws Error {
            uint revision = credential_revision;
            if (manager == null) throw new AccountsError.UNAVAILABLE(_("The accounts service is not available"));
            var bus = yield manager.get_bus();
            check_credentials(capability, revision);
            int64 now = GLib.get_real_time() / 1000000;
            if (refresh) {
                tokens.remove(key);
                token_expiry.remove(key);
            }
            if (!refresh && tokens.contains(key) && token_expiry.lookup(key) > now + 30) {
                return new AccountCredentials(identity, tokens.lookup(key), "oauth2");
            }
            string token;
            int expires_in;
            yield bus.get_access_token(id, cap, refresh, out token, out expires_in);
            check_credentials(capability, revision);
            tokens.insert(key, token);
            token_expiry.insert(key, GLib.get_real_time() / 1000000 + expires_in);
            return new AccountCredentials(identity, token, "oauth2");
        }

        private string token_key(Capability capability) {
            if (provider == "microsoft" && capability == Capability.MAIL) return "mail";
            return provider == "microsoft" ? "graph" : "default";
        }

        internal void forget_tokens() {
            tokens.remove_all();
            token_expiry.remove_all();
        }

        internal void detach() {
            manager = null;
            credential_revision++;
            supported = {};
            enabled = {};
            forget_tokens();
        }

        /**
         * Tells the service that a server rejected this account's
         * credentials, so Settings can ask the user to sign in again.
         */
        public async void report_problem(Capability capability, string reason) {
            if (manager == null) return;
            try {
                var bus = yield manager.get_bus();
                yield bus.report_problem(id, capability.to_id(), reason);
            } catch (Error e) {
                warning("accounts: cannot report problem for %s: %s", id, e.message);
            }
        }
    }
}
