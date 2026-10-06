using GLib;

namespace Singularity.Updates {

    public enum State {
        UNKNOWN,
        IDLE,
        CHECKING,
        UP_TO_DATE,
        AVAILABLE,
        DOWNLOADING,
        READY,
        SCHEDULED,
        ERROR;

        public static State parse(string value) {
            switch (value.strip().down()) {
                case "idle": return IDLE;
                case "checking": return CHECKING;
                case "up-to-date": return UP_TO_DATE;
                case "available": return AVAILABLE;
                case "downloading": return DOWNLOADING;
                case "ready": return READY;
                case "scheduled": return SCHEDULED;
                case "error": return ERROR;
            }
            return UNKNOWN;
        }

        public bool is_busy() {
            return this == CHECKING || this == DOWNLOADING;
        }
    }

    public class Package : Object {
        public string name { get; construct; }
        public string version { get; construct; }
        public string summary { get; construct; }
        public bool security { get; construct; }

        public Package(string name, string version, string summary, bool security) {
            Object(name: name, version: version, summary: summary, security: security);
        }
    }

    public class HistoryEntry : Object {
        public string title { get; construct; }
        public string detail { get; construct; }
        public int64 time { get; construct; }
        public bool success { get; construct; }

        public HistoryEntry(string title, string detail, int64 time, bool success) {
            Object(title: title, detail: detail, time: time, success: success);
        }
    }

    public abstract class Provider : Object {
        public abstract string kind { get; }
        public string name { get; protected set; default = ""; }
        public string description { get; protected set; default = ""; }
        public string current_version { get; protected set; default = ""; }
        public State state { get; protected set; default = State.UNKNOWN; }
        public string available_version { get; protected set; default = ""; }
        public string release_notes { get; protected set; default = ""; }
        public uint64 download_size { get; protected set; default = 0; }
        public double progress { get; protected set; default = -1; }
        public string last_error { get; protected set; default = ""; }
        public int64 last_check { get; protected set; default = 0; }
        public bool can_download { get; protected set; default = false; }
        public bool can_schedule { get; protected set; default = false; }
        public bool can_unschedule { get; protected set; default = false; }
        public bool has_history { get; protected set; default = false; }

        protected Gee.ArrayList<Package> _packages = new Gee.ArrayList<Package>();

        public Gee.List<Package> packages {
            owned get { return _packages.read_only_view; }
        }

        public signal void changed();

        public abstract async bool probe();
        public abstract async void check() throws Error;
        public abstract async void download() throws Error;
        public abstract async void schedule() throws Error;
        public abstract async void unschedule() throws Error;
        public abstract async Gee.List<HistoryEntry> history() throws Error;

        protected void fail(Error e) {
            last_error = e.message;
            state = State.ERROR;
            progress = -1;
            changed();
        }
    }

    public class NoneProvider : Provider {
        public override string kind {
            get { return "none"; }
        }

        public override async bool probe() {
            current_version = HardwareInfo.os_name();
            state = State.UNKNOWN;
            return true;
        }

        public override async void check() throws Error {
            throw new IOError.NOT_SUPPORTED(_("This system has no update service Settings can use"));
        }

        public override async void download() throws Error {
            throw new IOError.NOT_SUPPORTED(_("This system has no update service Settings can use"));
        }

        public override async void schedule() throws Error {
            throw new IOError.NOT_SUPPORTED(_("This system has no update service Settings can use"));
        }

        public override async void unschedule() throws Error {
            throw new IOError.NOT_SUPPORTED(_("This system has no update service Settings can use"));
        }

        public override async Gee.List<HistoryEntry> history() throws Error {
            return new Gee.ArrayList<HistoryEntry>();
        }
    }
}
