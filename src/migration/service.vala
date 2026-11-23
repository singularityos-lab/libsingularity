namespace Singularity.Migration {

    [DBus (name = "dev.sinty.Migration1")]
    public class Service : Object {
        private weak Gtk.Application app;
        private uint registration = 0;
        private DBusConnection? connection = null;

        public bool available {
            get { return Session.supported(app); }
        }

        public Service(Gtk.Application app) {
            this.app = app;
        }

        public Variant capture() throws DBusError, IOError, MigrationError {
            return Session.capture(app);
        }

        public Variant snapshot() throws DBusError, IOError {
            return Session.snapshot(app);
        }

        public async string[] restore(Variant state) throws DBusError, IOError, Error {
            var report = yield Session.restore(app, state);
            return report.differences;
        }

        public async void certify(out bool exact, out string[] differences) throws DBusError, IOError, Error {
            var report = yield Session.certify(app);
            exact = report.exact;
            differences = report.differences;
        }

        public void release() throws DBusError, IOError {
            var owner = app as Migratable;
            foreach (var w in app.get_windows()) {
                if (owner == null || owner.window_kind(w) != "") w.destroy();
            }
        }

        [DBus (visible = false)]
        public void export(DBusConnection connection, string object_path) throws IOError {
            this.connection = connection;
            registration = connection.register_object(object_path, this);
        }

        [DBus (visible = false)]
        public void unexport() {
            if (registration != 0 && connection != null) connection.unregister_object(registration);
            registration = 0;
            connection = null;
        }
    }
}
