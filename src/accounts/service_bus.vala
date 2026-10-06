namespace Singularity.Accounts {

    /**
     * D-Bus interface of the accounts service (dev.sinty.Accounts on the
     * session bus, object /dev/sinty/Accounts).
     *
     * Apps normally use Manager and Account instead of this proxy. Account
     * and provider descriptions travel as a{sv} dictionaries; see
     * docs/online-accounts.md for the keys.
     */
    [DBus (name = "dev.sinty.Accounts")]
    public interface ServiceBus : Object {
        public abstract async HashTable<string, Variant>[] list_accounts() throws AccountsError, DBusError, IOError;
        public abstract async HashTable<string, Variant>[] list_providers() throws AccountsError, DBusError, IOError;
        public abstract async void get_access_token(string id, string capability, bool refresh, out string token, out int expires_in) throws AccountsError, DBusError, IOError;
        public abstract async void get_credentials(string id, string capability, out string username, out string secret, out string mechanism) throws AccountsError, DBusError, IOError;
        public abstract async void set_capability_enabled(string id, string capability, bool enabled) throws AccountsError, DBusError, IOError;
        public abstract async void set_display_name(string id, string name) throws AccountsError, DBusError, IOError;
        public abstract async void remove_account(string id) throws AccountsError, DBusError, IOError;
        public abstract async string add_account(string provider, HashTable<string, Variant> settings, string secret) throws AccountsError, DBusError, IOError;
        public abstract async void update_password(string id, string secret) throws AccountsError, DBusError, IOError;
        public abstract async void begin_sign_in(string provider, HashTable<string, Variant> settings, out string flow_id, out string url) throws AccountsError, DBusError, IOError;
        public abstract async void cancel_sign_in(string flow_id) throws AccountsError, DBusError, IOError;
        public abstract async string get_sign_in_helper() throws AccountsError, DBusError, IOError;
        public abstract async void complete_sign_in(string flow_id, string address) throws AccountsError, DBusError, IOError;
        public abstract async void report_problem(string id, string capability, string reason) throws AccountsError, DBusError, IOError;
        public abstract async void set_oauth_client(string provider, string client_id, string client_secret) throws AccountsError, DBusError, IOError;

        public signal void account_added(string id);
        public signal void account_removed(string id);
        public signal void account_changed(string id);
        public signal void needs_attention(string id, string reason);
        public signal void sign_in_finished(string flow_id, string account_id, string error_message);
    }
}
