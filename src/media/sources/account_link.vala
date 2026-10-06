
namespace Singularity.MediaSources {

    public class AccountLink : Object {
        private HashTable<string, string> _endpoints = new HashTable<string, string> (str_hash, str_equal);

        public string id { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string server { get; set; default = ""; }
        public string provider { get; set; default = ""; }
        public Singularity.Accounts.Account? account { get; set; default = null; }
        public string username { get; set; default = ""; }
        public string secret { get; set; default = ""; }
        public string mechanism { get; set; default = "password"; }

        public static AccountLink from_account (Singularity.Accounts.Account a) {
            var l = new AccountLink ();
            l.id = a.id;
            l.title = a.display_name != "" ? a.display_name : a.identity;
            l.server = a.server;
            l.provider = a.provider;
            l.account = a;
            foreach (var k in a.get_endpoint_keys ()) l._endpoints.insert (k, a.get_endpoint (k));
            return l;
        }

        public string endpoint (string key, string fallback = "") {
            string? v = _endpoints.lookup (key);
            return v != null && v != "" ? v : fallback;
        }

        public void set_endpoint (string key, string value) {
            _endpoints.insert (key, value);
        }

        public async Singularity.Accounts.AccountCredentials credentials (Singularity.Accounts.Capability capability, bool refresh = false) throws Error {
            if (account != null) return yield account.get_credentials (capability, refresh);
            if (secret == "") throw new MediaError.NEEDS_ACCOUNT ("No credentials");
            return new Singularity.Accounts.AccountCredentials (username, secret, mechanism);
        }

        public async void report_problem (Singularity.Accounts.Capability capability) {
            if (account != null) yield account.report_problem (capability, "reauth");
        }
    }

    public class AccountLinks : Object {
        public static Gee.List<AccountLink> find (MediaHost host, Singularity.Accounts.Capability capability, string provider) {
            var result = new Gee.ArrayList<AccountLink> ();
            foreach (var a in host.accounts (capability)) {
                if (a.provider == provider) result.add (AccountLink.from_account (a));
            }
            return result;
        }

        public static string trim_slash (string url) {
            string u = url;
            while (u.has_suffix ("/")) u = u.substring (0, u.length - 1);
            return u;
        }

        public static string node (string link_id, string kind, string id = "") {
            return link_id + "/" + kind + (id != "" ? "/" + id : "");
        }

        public static bool parse (string node, out string link_id, out string kind, out string id) {
            link_id = "";
            kind = "";
            id = "";
            var parts = node.split ("/", 3);
            if (parts.length < 2) return false;
            link_id = parts[0];
            kind = parts[1];
            if (parts.length > 2) id = parts[2];
            return true;
        }
    }
}
