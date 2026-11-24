namespace Singularity.Startup {

    [DBus (name = "dev.sinty.Startup1")]
    public class Boot : Object {
        private const string KEY = "singularity-startup-boot";

        private weak GLib.Application app;
        private Runner? runner = null;
        private Profile? profile = null;
        private Gee.ArrayList<Request> pending = new Gee.ArrayList<Request>();
        private Gee.HashMap<Milestone, int64?> observed = new Gee.HashMap<Milestone, int64?>();
        private uint registration = 0;
        private DBusConnection? connection = null;

        public string plan_kind {
            owned get {
                if (runner != null) return runner.plan.kind.to_id();
                return (app is Bootable) ? "pending" : "unmanaged";
            }
        }

        public string state {
            owned get {
                if (runner == null) return (app is Bootable) ? "idle" : "unmanaged";
                if (runner.failed) return "failed";
                return runner.running ? "running" : "settled";
            }
        }

        public signal void milestone(string name, int64 at_us);

        [DBus (visible = false)]
        public signal void ready(Milestone milestone);

        [DBus (visible = false)]
        public static Boot of(GLib.Application app) {
            var boot = app.get_data<Boot>(KEY);
            if (boot == null) {
                boot = new Boot(app);
                app.set_data<Boot>(KEY, boot);
            }
            return boot;
        }

        private Boot(GLib.Application app) {
            this.app = app;
            if (!(app is Bootable) && app is Gtk.Application) watch_legacy((Gtk.Application) app);
        }

        [DBus (visible = false)]
        public Runner? current() {
            return runner;
        }

        [DBus (visible = false)]
        public void request(Request request) {
            var bootable = app as Bootable;
            if (bootable == null) return;
            if (runner == null) {
                begin(bootable, request);
                return;
            }
            if (runner.failed) {
                if (runner.running) {
                    pending.add(request);
                    return;
                }
                runner = null;
                begin(bootable, request);
                return;
            }
            if (!runner.has_reached(Milestone.INTERACTIVE) || (request.kind != RequestKind.SERVICE && runner.context.request.kind == RequestKind.SERVICE && !runner.has_reached(Milestone.SETTLED))) {
                pending.add(request);
                return;
            }
            if (request.kind != RequestKind.SERVICE) bootable.handle_request(request);
        }

        private void begin(Bootable bootable, Request request) {
            Plan plan;
            plan = bootable.build_plan(request);
            runner = new Runner(plan, app, request);
            profile = Profile.load(app.application_id ?? "app", plan, request);
            profile.apply(runner);
            runner.milestone_reached.connect(on_milestone);
            runner.essential_failure.connect(on_failure);
            runner.settled.connect(on_settled);
            app.hold();
            try {
                runner.start();
            } catch (PlanError e) {
                critical("%s: invalid start-up plan: %s", app.application_id ?? "app", e.message);
                Observer.get_default().mark("plan-invalid", e.message);
                app.release();
                bootable.show_startup_error(null, new Task("plan", Category.PREPARE, Placement.MAIN), e);
            }
        }

        private void on_milestone(Milestone m, int64 at) {
            ready(m);
            milestone(m.to_id(), at);
            if (m == Milestone.INTERACTIVE) flush();
        }

        private void flush() {
            var bootable = app as Bootable;
            var queued = pending;
            pending = new Gee.ArrayList<Request>();
            foreach (var r in queued) {
                if (r.kind != RequestKind.SERVICE) bootable.handle_request(r);
            }
        }

        private void on_failure(Task task, Error error) {
            var bootable = app as Bootable;
            Gtk.Window? window = runner.context.window;
            if (window == null && app is Gtk.Application) window = ((Gtk.Application) app).active_window;
            bootable.show_startup_error(window, task, error);
        }

        private void on_settled() {
            if (profile != null && !runner.failed) profile.record(runner);
            Observer.get_default().attach(this);
            app.release();
            if ((runner.failed || runner.context.request.kind == RequestKind.SERVICE) && pending.size > 0) {
                var bootable = app as Bootable;
                var queued = pending;
                pending = new Gee.ArrayList<Request>();
                runner = null;
                foreach (var r in queued) request(r);
                if (runner == null && bootable != null) return;
            }
        }

        [DBus (visible = false)]
        public void cancel() {
            if (runner != null) runner.cancel();
        }

        [DBus (visible = false)]
        public async void wait(Milestone m) {
            if (runner == null) {
                if (!(app is Bootable)) return;
                request(new Request(RequestKind.SERVICE));
            }
            if (runner == null || runner.failed || runner.has_reached(m) || runner.has_reached(Milestone.SETTLED)) return;
            ulong id = 0;
            ulong fail = 0;
            id = runner.milestone_reached.connect((reached) => {
                if (reached >= m) wait.callback();
            });
            fail = runner.essential_failure.connect(() => wait.callback());
            yield;
            runner.disconnect(id);
            runner.disconnect(fail);
        }

        private void watch_legacy(Gtk.Application gapp) {
            gapp.window_added.connect((w) => {
                if (observed.has_key(Milestone.SHELL_READY)) return;
                ((Gtk.Widget) w).map.connect(() => {
                    if (observed.has_key(Milestone.SHELL_READY)) return;
                    int64 at = Observer.get_default().elapsed_us();
                    observed[Milestone.SHELL_READY] = at;
                    Observer.get_default().mark("observed", "shell-ready");
                    milestone("observed-shell-ready", at);
                });
            });
        }

        public string report() throws DBusError, IOError {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("app");
            b.add_string_value(app.application_id ?? "");
            b.set_member_name("kind");
            b.add_string_value(plan_kind);
            b.set_member_name("state");
            b.add_string_value(state);
            b.set_member_name("milestones");
            b.begin_object();
            if (runner != null) {
                foreach (var m in new Milestone[] { Milestone.SHELL_READY, Milestone.CONTENT_READY, Milestone.INTERACTIVE, Milestone.SETTLED }) {
                    if (!runner.has_reached(m)) continue;
                    b.set_member_name(m.to_id());
                    b.add_double_value(runner.reached_at(m) / 1000.0);
                }
            }
            foreach (var e in observed.entries) {
                b.set_member_name("observed-" + e.key.to_id());
                b.add_double_value(e.value / 1000.0);
            }
            b.end_object();
            if (runner != null) {
                b.set_member_name("request");
                b.add_string_value(runner.context.request.kind.to_id());
                b.set_member_name("longest_main_slice_ms");
                b.add_double_value(runner.longest_slice_us() / 1000.0);
                b.set_member_name("disabled");
                b.begin_array();
                foreach (var f in runner.disabled_features()) b.add_string_value(f);
                b.end_array();
                b.set_member_name("tasks");
                b.begin_array();
                foreach (var t in runner.plan.tasks()) {
                    b.begin_object();
                    b.set_member_name("id");
                    b.add_string_value(t.id);
                    b.set_member_name("category");
                    b.add_string_value(t.category.to_id());
                    b.set_member_name("placement");
                    b.add_string_value(t.placement == Placement.MAIN ? "main" : "worker");
                    b.set_member_name("state");
                    b.add_string_value(t.state.to_string().substring("SINGULARITY_STARTUP_TASK_STATE_".length).down());
                    b.set_member_name("start_ms");
                    b.add_double_value(t.started_us / 1000.0);
                    b.set_member_name("ms");
                    b.add_double_value(t.duration_us() / 1000.0);
                    b.set_member_name("overrun_ms");
                    b.add_double_value(t.overrun_us / 1000.0);
                    if (t.cached) {
                        b.set_member_name("cached");
                        b.add_boolean_value(true);
                    }
                    if (t.lingering) {
                        b.set_member_name("lingering");
                        b.add_boolean_value(true);
                    }
                    if (t.error != null) {
                        b.set_member_name("error");
                        b.add_string_value(t.error.message);
                    }
                    b.end_object();
                }
                b.end_array();
            }
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        [DBus (visible = false)]
        public Json.Node report_node() {
            try {
                return Json.from_string(report());
            } catch (Error e) {
                return new Json.Node(Json.NodeType.NULL);
            }
        }

        [DBus (visible = false)]
        public void export(DBusConnection connection, string object_path) throws IOError {
            this.connection = connection;
            registration = connection.register_object(object_path, this);
        }

        [DBus (visible = false)]
        public void unexport() {
            if (connection != null && registration != 0) connection.unregister_object(registration);
            registration = 0;
            connection = null;
        }
    }
}
