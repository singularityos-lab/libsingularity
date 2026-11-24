namespace Singularity.Startup {

    public enum RequestKind {
        ACTIVATE,
        OPEN,
        SERVICE;

        public string to_id() {
            switch (this) {
                case ACTIVATE: return "activate";
                case OPEN: return "open";
                default: return "service";
            }
        }
    }

    public class Request : Object {
        public RequestKind kind { get; construct; }
        public string hint { get; construct; default = ""; }
        private File[] _files = {};

        public Request(RequestKind kind, File[] files = {}, string hint = "") {
            Object(kind: kind, hint: hint);
            _files = files;
        }

        public File[] files() {
            return _files;
        }
    }

    public interface Bootable : GLib.Application {
        public abstract Plan build_plan(Request request);

        public abstract void handle_request(Request request);

        public virtual void show_startup_error(Gtk.Window? window, Task task, Error error) {
            var app = this as Gtk.Application;
            if (app == null) return;
            var dialog = new Singularity.Widgets.ConfirmDialog(app,
                _("Could Not Start"),
                "dialog-error",
                error.message,
                _("Close"),
                Singularity.Widgets.ConfirmDialog.ActionStyle.DESTRUCTIVE);
            if (window != null) dialog.transient_for = window;
            dialog.response.connect(() => {
                if (window == null) app.quit();
            });
            dialog.present();
        }
    }

    public class Context : Object {
        public GLib.Application app { get; construct; }
        public Request request { get; construct; }
        public Cancellable cancellable { get; construct; }
        public Gtk.Window? window { get; set; default = null; }

        internal Runner runner;
        internal Task? current = null;
        internal int64 slice_start = 0;
        private Gee.HashMap<string, Object> values = new Gee.HashMap<string, Object>();

        internal Context(GLib.Application app, Request request, Cancellable cancellable) {
            Object(app: app, request: request, cancellable: cancellable);
        }

        public void put(string key, Object value) {
            values[key] = value;
        }

        public new Object? get(string key) {
            return values[key];
        }

        public bool cancelled() {
            return cancellable.is_cancelled();
        }

        public Hold hold() {
            return runner.hold(current);
        }

        public void disable(string feature) {
            runner.disable_feature(feature);
        }
    }

    public class Hold : Object {
        private weak Runner runner;
        private Task task;
        private bool released = false;

        internal Hold(Runner runner, Task task) {
            this.runner = runner;
            this.task = task;
        }

        public void release() {
            if (released) return;
            released = true;
            runner.released(task, null);
        }

        public void fail(Error error) {
            if (released) return;
            released = true;
            runner.released(task, error);
        }
    }

    public class Runner : Object {
        public const uint LINGER_MS = 2000;

        public Plan plan { get; construct; }
        public Context context { get; private set; }
        public bool running { get; private set; default = false; }
        public bool failed { get; private set; default = false; }
        public int max_workers { get; set; default = 0; }
        public int64 started_us { get; private set; default = -1; }

        private Gee.HashMap<Milestone, int64?> reached = new Gee.HashMap<Milestone, int64?>();
        private Gee.HashSet<string> critical_path = new Gee.HashSet<string>();
        private Gee.HashSet<string> disabled = new Gee.HashSet<string>();
        private Gee.HashMap<string, int64?> predicted = new Gee.HashMap<string, int64?>();
        private int workers = 0;
        private bool main_busy = false;
        private int64 max_slice = 0;
        private Cancellable cancellable = new Cancellable();
        private Observer observer = Observer.get_default();
        public Policy policies { get; set; default = Policy.active(); }

        public signal void milestone_reached(Milestone milestone, int64 at_us);
        public signal void task_finished(Task task);
        public signal void essential_failure(Task task, Error error);
        public signal void settled();

        public Runner(Plan plan, GLib.Application app, Request request) {
            Object(plan: plan);
            context = new Context(app, request, cancellable);
            context.runner = this;
            int cpus = (int) get_num_processors();
            max_workers = int.max(1, int.min(4, cpus / 2));
        }

        public void predict(string task, int64 duration_us) {
            predicted[task] = duration_us;
        }

        public bool has_reached(Milestone m) {
            return reached.has_key(m);
        }

        public int64 reached_at(Milestone m) {
            return reached.has_key(m) ? reached[m] : -1;
        }

        public string[] disabled_features() {
            return disabled.to_array();
        }

        public int64 longest_slice_us() {
            return max_slice;
        }

        public void start() throws PlanError {
            plan.validate(context.request.kind != RequestKind.SERVICE);
            running = true;
            observer.expect_plan();
            started_us = observer.elapsed_us();
            observer.mark("plan-" + plan.kind.to_id());
            mark_critical();
            pump();
        }

        public void cancel() {
            if (!running) return;
            cancellable.cancel();
            foreach (var t in plan.tasks()) {
                if (t.state == TaskState.WAITING) t.state = TaskState.CANCELLED;
            }
            observer.mark("plan-cancelled");
            maybe_settle();
        }

        internal void disable_feature(string feature) {
            disabled.add(feature);
        }

        private void mark_critical() {
            var queue = new Gee.ArrayList<Task>();
            foreach (var t in plan.tasks()) {
                foreach (var m in t.milestones()) {
                    if (m != Milestone.SETTLED) {
                        queue.add(t);
                        break;
                    }
                }
            }
            while (queue.size > 0) {
                var t = queue.remove_at(queue.size - 1);
                if (critical_path.contains(t.id)) continue;
                critical_path.add(t.id);
                foreach (var d in t.dependencies()) queue.add(plan.get_task(d));
            }
        }

        private int earliest_gate(Task t) {
            int best = 4;
            foreach (var m in t.milestones()) best = int.min(best, (int) m);
            return critical_path.contains(t.id) && best == 4 ? 3 : best;
        }

        private int64 remaining_path(Task t, Gee.HashMap<string, int64?> memo) {
            if (memo.has_key(t.id)) return memo[t.id];
            int64 own = predicted.has_key(t.id) ? predicted[t.id] : (t.budget_ms > 0 ? t.budget_ms * 1000 : 1000);
            int64 longest = 0;
            foreach (var next in plan.dependents_of(t)) longest = int64.max(longest, remaining_path(next, memo));
            memo[t.id] = own + longest;
            return own + longest;
        }

        internal Async.Qos qos_for(Task t) {
            if (t.category == Category.DEFERRED) return (policies & Policy.SCHEDULER) != 0 ? Async.Qos.BACKGROUND : Async.Qos.UTILITY;
            if (!critical_path.contains(t.id)) return Async.Qos.UTILITY;
            foreach (var m in t.milestones()) {
                if (m == Milestone.SHELL_READY || m == Milestone.INTERACTIVE) return Async.Qos.INTERACTIVE;
            }
            return Async.Qos.USER;
        }

        internal int slice_priority(Task? t) {
            if (t == null) return Priority.DEFAULT_IDLE;
            if (t.category == Category.DEFERRED || !critical_path.contains(t.id)) return Priority.LOW;
            return Priority.DEFAULT;
        }

        internal void close_slice(Context c) {
            if (c.current == null || c.slice_start == 0) return;
            int64 slice = GLib.get_monotonic_time() - c.slice_start;
            if (slice > max_slice) max_slice = slice;
            if (c.current.budget_ms > 0 && slice > (int64) c.current.budget_ms * 1000) {
                c.current.overrun_us = int64.max(c.current.overrun_us, slice - (int64) c.current.budget_ms * 1000);
            }
        }

        private bool ready(Task t) {
            if (t.state != TaskState.WAITING) return false;
            foreach (var d in t.dependencies()) {
                if (plan.get_task(d).state != TaskState.DONE) return false;
            }
            return true;
        }

        private bool blocked(Task t) {
            foreach (var d in t.dependencies()) {
                var s = plan.get_task(d).state;
                if (s == TaskState.FAILED || s == TaskState.SKIPPED || s == TaskState.CANCELLED) return true;
            }
            return false;
        }

        private void pump() {
            if (!running) return;
            if (cancellable.is_cancelled()) {
                maybe_settle();
                return;
            }
            bool changed = true;
            while (changed) {
                changed = false;
                foreach (var t in plan.tasks()) {
                    if (t.state == TaskState.WAITING && blocked(t)) {
                        t.state = TaskState.SKIPPED;
                        if (t.feature != null) disabled.add(t.feature);
                        observer.mark("task-skipped", t.id);
                        task_finished(t);
                        changed = true;
                    } else if (t.state == TaskState.WAITING && t.feature != null && disabled.contains(t.feature)) {
                        t.state = TaskState.SKIPPED;
                        observer.mark("task-skipped", t.id);
                        task_finished(t);
                        changed = true;
                    }
                }
            }
            var candidates = new Gee.ArrayList<Task>();
            foreach (var t in plan.tasks()) {
                if (ready(t)) candidates.add(t);
            }
            var memo = new Gee.HashMap<string, int64?>();
            candidates.sort((a, b) => {
                int ga = earliest_gate(a), gb = earliest_gate(b);
                if (ga != gb) return ga - gb;
                int64 pa = remaining_path(a, memo), pb = remaining_path(b, memo);
                if (pa != pb) return pa > pb ? -1 : 1;
                return plan.tasks().index_of(a) - plan.tasks().index_of(b);
            });
            foreach (var t in candidates) {
                if (!running || !ready(t) || t.placement == Placement.MAIN) continue;
                if (workers >= max_workers) break;
                workers++;
                run_worker.begin(t);
            }
            foreach (var t in candidates) {
                if (!running || !ready(t) || t.placement != Placement.MAIN) continue;
                if (main_busy) break;
                main_busy = true;
                run_main(t);
            }
            update_milestones();
            maybe_settle();
        }

        private void begin_task(Task t) {
            t.state = TaskState.RUNNING;
            t.started_us = observer.elapsed_us();
            observer.mark("task-begin", t.id);
        }

        private void end_task(Task t, Error? error) {
            t.finished_us = observer.elapsed_us();
            if (error == null) {
                t.state = TaskState.DONE;
            } else if (error is PlanError.CANCELLED || cancellable.is_cancelled()) {
                t.state = TaskState.CANCELLED;
            } else {
                t.state = TaskState.FAILED;
                t.error = error;
                if (t.failure == Failure.RECOVERABLE) {
                    if (t.feature != null) disabled.add(t.feature);
                    observer.mark("task-degraded", "%s: %s".printf(t.id, error.message));
                } else {
                    failed = true;
                    observer.mark("task-failed", "%s: %s".printf(t.id, error.message));
                    essential_failure(t, error);
                }
            }
            observer.mark("task-end", t.id);
            task_finished(t);
            update_milestones();
        }

        private Gee.HashMap<Task, int> open_holds = new Gee.HashMap<Task, int>();
        private Gee.HashMap<Task, Error> hold_errors = new Gee.HashMap<Task, Error>();

        internal Hold hold(Task? task) {
            if (task == null || task.placement != Placement.MAIN || task.step_work != null) {
                critical("Context.hold() is only valid inside a main task");
                return new Hold(this, task ?? new Task("invalid", Category.PREPARE, Placement.MAIN));
            }
            open_holds[task] = (open_holds.has_key(task) ? open_holds[task] : 0) + 1;
            return new Hold(this, task);
        }

        internal void released(Task task, Error? error) {
            if (!open_holds.has_key(task)) return;
            if (error != null && !hold_errors.has_key(task)) hold_errors[task] = error;
            int left = open_holds[task] - 1;
            if (left > 0) {
                open_holds[task] = left;
                return;
            }
            open_holds.unset(task);
            if (task.state == TaskState.RUNNING && task.finished_us < 0 && !main_running(task)) complete_main(task);
        }

        private Task? main_in_call = null;

        private bool main_running(Task task) {
            return main_in_call == task;
        }

        private void complete_main(Task t) {
            Error? error = hold_errors.has_key(t) ? hold_errors[t] : null;
            hold_errors.unset(t);
            if (error == null && cancellable.is_cancelled()) error = new PlanError.CANCELLED("start-up was cancelled");
            end_task(t, error);
            main_busy = false;
            pump();
        }

        private void run_main(Task t) {
            if (t.category == Category.DEFERRED && t.step_work == null) {
                Idle.add_full(Priority.LOW, () => {
                    if (cancellable.is_cancelled()) {
                        begin_task(t);
                        end_task(t, new PlanError.CANCELLED("start-up was cancelled"));
                        main_busy = false;
                        pump();
                        return Source.REMOVE;
                    }
                    run_main_now(t);
                    return Source.REMOVE;
                });
                return;
            }
            run_main_now(t);
        }

        private void run_main_now(Task t) {
            begin_task(t);
            if (t.step_work != null) {
                run_steps(t);
                return;
            }
            context.current = t;
            context.slice_start = GLib.get_monotonic_time();
            main_in_call = t;
            Error? error = null;
            try {
                t.main_work(context);
            } catch (Error e) {
                error = e;
            }
            main_in_call = null;
            close_slice(context);
            context.current = null;
            context.slice_start = 0;
            if (error != null) {
                open_holds.unset(t);
                hold_errors[t] = error;
            }
            if (!open_holds.has_key(t)) complete_main(t);
        }

        private void run_steps(Task t) {
            Idle.add(() => {
                if (cancellable.is_cancelled()) {
                    end_task(t, new PlanError.CANCELLED("start-up was cancelled"));
                    main_busy = false;
                    pump();
                    return Source.REMOVE;
                }
                context.current = t;
                context.slice_start = GLib.get_monotonic_time();
                bool more = false;
                Error? error = null;
                try {
                    more = t.step_work(context);
                } catch (Error e) {
                    error = e;
                }
                close_slice(context);
                context.current = null;
                context.slice_start = 0;
                if (more && error == null) return Source.CONTINUE;
                end_task(t, error);
                main_busy = false;
                pump();
                return Source.REMOVE;
            }, slice_priority(t));
        }

        private async void run_worker(Task t) {
            begin_task(t);
            Error? error = null;
            Object? result = null;
            bool done = false;
            var timer = new Timer();
            ulong watch = cancellable.cancelled.connect(() => {
                Timeout.add(LINGER_MS, () => {
                    if (!done) {
                        t.lingering = true;
                        observer.mark("task-lingering", t.id);
                    }
                    return Source.REMOVE;
                });
            });
            try {
                result = yield Async.run<Object?>((c) => t.worker_work(c), qos_for(t), t.cancellable ? cancellable : null);
            } catch (Error e) {
                error = e;
            }
            done = true;
            cancellable.disconnect(watch);
            if (t.budget_ms > 0 && timer.elapsed() * 1000 > t.budget_ms) {
                t.overrun_us = (int64) (timer.elapsed() * 1000000) - (int64) t.budget_ms * 1000;
            }
            if (error == null && cancellable.is_cancelled()) error = new PlanError.CANCELLED("start-up was cancelled");
            if (error == null && t.apply != null) {
                context.current = t;
                context.slice_start = GLib.get_monotonic_time();
                try {
                    t.apply(context, result);
                } catch (Error e) {
                    error = e;
                }
                close_slice(context);
                context.current = null;
                context.slice_start = 0;
            }
            end_task(t, error);
            workers--;
            pump();
        }

        private bool satisfied(Milestone m) {
            foreach (var t in plan.tasks()) {
                if (!(m in t.milestones())) continue;
                if (t.state == TaskState.DONE) continue;
                if (t.failure == Failure.RECOVERABLE && t.finished() && t.state != TaskState.CANCELLED) continue;
                return false;
            }
            return true;
        }

        private void update_milestones() {
            foreach (var m in new Milestone[] { Milestone.SHELL_READY, Milestone.CONTENT_READY, Milestone.INTERACTIVE }) {
                if (reached.has_key(m)) continue;
                if (!satisfied(m)) return;
                int64 at = observer.elapsed_us();
                reached[m] = at;
                observer.mark("milestone", m.to_id());
                milestone_reached(m, at);
            }
        }

        [CCode (cname = "malloc_trim", cheader_filename = "malloc.h")]
        private static extern int malloc_trim(size_t pad);

        private void release_startup_memory() {
            Idle.add_full(Priority.LOW, () => {
                malloc_trim(0);
                observer.mark("memory-trimmed");
                return Source.REMOVE;
            });
        }

        private void maybe_settle() {
            if (!running) return;
            foreach (var t in plan.tasks()) {
                if (!t.finished()) return;
            }
            if (workers > 0 || main_busy) return;
            running = false;
            int64 at = observer.elapsed_us();
            reached[Milestone.SETTLED] = at;
            observer.mark("milestone", Milestone.SETTLED.to_id());
            if ((policies & Policy.MEMORY) != 0) release_startup_memory();
            milestone_reached(Milestone.SETTLED, at);
            settled();
        }
    }
}
