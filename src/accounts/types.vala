namespace Singularity.Accounts {

    /**
     * Errors reported by the accounts service and the client API.
     *
     * The same codes travel over D-Bus as dev.sinty.Accounts.Error.*.
     */
    [DBus (name = "dev.sinty.Accounts.Error")]
    public errordomain AccountsError {
        /** No account, flow or collection has the given identifier. */
        NOT_FOUND,
        /** The stored credentials stopped working; the user must sign in again. */
        NEEDS_REAUTH,
        /** The provider needs an OAuth client that this system does not have. */
        NOT_CONFIGURED,
        /** The server could not be reached. */
        NETWORK,
        /** The server refused the user name, password or token. */
        AUTH_FAILED,
        /** The server answered something this client does not understand. */
        PROTOCOL,
        /** The user or the caller cancelled the operation. */
        CANCELLED,
        /** The request was malformed or the account lacks the capability. */
        INVALID,
        /** The item changed on the server since it was last read. */
        CONFLICT,
        /** The accounts service is not running and cannot be started. */
        UNAVAILABLE
    }

    /**
     * What an online account can be used for.
     */
    public enum Capability {
        MAIL,
        CALENDAR,
        CONTACTS,
        TASKS,
        FILES,
        NOTES,
        PHOTOS,
        MUSIC,
        VIDEOS;

        /** Stable identifier used in D-Bus calls and stored metadata. */
        public string to_id() {
            switch (this) {
                case MAIL: return "mail";
                case CALENDAR: return "calendar";
                case CONTACTS: return "contacts";
                case TASKS: return "tasks";
                case FILES: return "files";
                case PHOTOS: return "photos";
                case MUSIC: return "music";
                case VIDEOS: return "videos";
                default: return "notes";
            }
        }

        /**
         * Parses an identifier produced by to_id().
         *
         * @param id     The identifier.
         * @param result The parsed capability.
         * @return false when the identifier is unknown.
         */
        public static bool try_parse(string id, out Capability result) {
            switch (id) {
                case "mail": result = MAIL; return true;
                case "calendar": result = CALENDAR; return true;
                case "contacts": result = CONTACTS; return true;
                case "tasks": result = TASKS; return true;
                case "files": result = FILES; return true;
                case "notes": result = NOTES; return true;
                case "photos": result = PHOTOS; return true;
                case "music": result = MUSIC; return true;
                case "videos": result = VIDEOS; return true;
                default: result = MAIL; return false;
            }
        }

        /** Translated name shown in Settings. */
        public string label() {
            switch (this) {
                case MAIL: return _("Mail");
                case CALENDAR: return _("Calendar");
                case CONTACTS: return _("Contacts");
                case TASKS: return _("Tasks");
                case FILES: return _("Files");
                case PHOTOS: return _("Photos");
                case MUSIC: return _("Music");
                case VIDEOS: return _("Videos");
                default: return _("Notes");
            }
        }

        /** Symbolic glyph for rows and switches. */
        public string icon_name() {
            switch (this) {
                case MAIL: return "mail-unread-symbolic";
                case CALENDAR: return "x-office-calendar-symbolic";
                case CONTACTS: return "x-office-address-book-symbolic";
                case TASKS: return "checkbox-checked-symbolic";
                case FILES: return "folder-remote-symbolic";
                case PHOTOS: return "image-x-generic-symbolic";
                case MUSIC: return "audio-x-generic-symbolic";
                case VIDEOS: return "video-x-generic-symbolic";
                default: return "accessories-text-editor-symbolic";
            }
        }

        /** Every capability, in display order. */
        public static Capability[] all() {
            return { MAIL, CALENDAR, CONTACTS, TASKS, FILES, PHOTOS, MUSIC, VIDEOS, NOTES };
        }
    }

    /**
     * Credentials handed out for one capability of an account.
     *
     * For password accounts `secret` is the password or app password; for
     * OAuth accounts it is a short-lived access token and `mechanism` says so.
     */
    public class AccountCredentials : Object {
        /** User name to present to the server. */
        public string username { get; construct; }
        /** Password, app password or access token. */
        public string secret { get; construct; }
        /** "password", "oauth2" or "ntlm". */
        public string mechanism { get; construct; }

        public AccountCredentials(string username, string secret, string mechanism) {
            Object(username: username, secret: secret, mechanism: mechanism);
        }

        /** True when `secret` is an OAuth2 bearer token. */
        public bool is_token {
            get { return mechanism == "oauth2"; }
        }

        /**
         * The value of an HTTP Authorization header for these credentials:
         * "Bearer <token>" or "Basic <base64>". NTLM credentials return null
         * because the HTTP session negotiates them itself.
         */
        public string? authorization_header() {
            if (mechanism == "oauth2") return "Bearer " + secret;
            if (mechanism == "ntlm") return null;
            return "Basic " + Base64.encode((username + ":" + secret).data);
        }

        /**
         * The SASL XOAUTH2 initial response for IMAP and SMTP, already
         * base64 encoded.
         */
        public string xoauth2_response() {
            string raw = "user=" + username + "\x01" + "auth=Bearer " + secret + "\x01\x01";
            return Base64.encode(raw.data);
        }
    }
}
