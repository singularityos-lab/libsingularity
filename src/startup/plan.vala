namespace Singularity.Startup {

    public enum Category {
        PREPARE,
        SHELL,
        CONTENT,
        DEFERRED;

        public string to_id() {
            switch (this) {
                case PREPARE: return "prepare";
                case SHELL: return "shell";
                case CONTENT: return "content";
                default: return "deferred";
            }
        }
    }

    public enum Milestone {
        SHELL_READY,
        CONTENT_READY,
        INTERACTIVE,
        SETTLED;

        public string to_id() {
            switch (this) {
                case SHELL_READY: return "shell-ready";
                case CONTENT_READY: return "content-ready";
                case INTERACTIVE: return "interactive";
                default: return "settled";
            }
        }
    }

    public enum Placement {
        MAIN,
        WORKER
    }

    public enum Failure {
        ESSENTIAL,
        RECOVERABLE
    }

    public enum PlanKind {
        STRUCTURED,
        LEGACY_WRAPPED;

        public string to_id() {
            return this == STRUCTURED ? "structured" : "legacy-wrapped";
        }
    }

    public enum TaskState {
        WAITING,
        RUNNING,
        DONE,
        FAILED,
        SKIPPED,
        CANCELLED
    }

    public delegate void MainWork(Context context) throws Error;

    public delegate bool StepWork(Context context) throws Error;

    public delegate Object? WorkerWork(Cancellable cancellable) throws Error;

    public delegate uint8[] BytesWork(Cancellable cancellable) throws Error;

    public delegate void BytesApply(Context context, uint8[] result) throws Error;

    [Flags]
    public enum Policy {
        COMPUTE,
        SCHEDULER,
        MEMORY;

        public static Policy active() {
            string? env = Environment.get_variable("SINGULARITY_STARTUP_POLICIES");
            if (env == null) return COMPUTE | SCHEDULER | MEMORY;
            Policy p = 0;
            foreach (var name in env.split(",")) {
                switch (name.strip()) {
                    case "compute": p |= COMPUTE; break;
                    case "scheduler": p |= SCHEDULER; break;
                    case "memory": p |= MEMORY; break;
                    case "all": p |= COMPUTE | SCHEDULER | MEMORY; break;
                    default: break;
                }
            }
            return p;
        }
    }

    internal class Reuse : Object {
        public uint8[] bytes;
        public bool reused;

        public Reuse(owned uint8[] bytes, bool reused) {
            this.bytes = (owned) bytes;
            this.reused = reused;
        }
    }

    public delegate void Apply(Context context, Object? result) throws Error;

    public errordomain PlanError {
        INVALID,
        FAILED,
        CANCELLED
    }

    public class Task : Object {
        public string id { get; construct; }
        public Category category { get; construct; }
        public Placement placement { get; construct; }
        public Failure failure { get; set; default = Failure.ESSENTIAL; }
        public bool cancellable { get; set; default = true; }
        public uint budget_ms { get; set; default = 0; }
        public string? cache_key { get; set; default = null; }
        public bool io_heavy { get; set; default = false; }
        public uint64 memory_hint { get; set; default = 0; }
        public string? feature { get; set; default = null; }

        public TaskState state { get; internal set; default = TaskState.WAITING; }
        public int64 started_us { get; internal set; default = -1; }
        public int64 finished_us { get; internal set; default = -1; }
        public int64 overrun_us { get; internal set; default = 0; }
        public Error? error { get; internal set; default = null; }
        public bool cached { get; internal set; default = false; }
        public bool lingering { get; internal set; default = false; }

        internal string[] after = {};
        internal Milestone[] gates = {};
        internal MainWork? main_work = null;
        internal StepWork? step_work = null;
        internal WorkerWork? worker_work = null;
        internal Apply? apply = null;

        internal Task(string id, Category category, Placement placement) {
            Object(id: id, category: category, placement: placement);
        }

        public Task depends_on(string other) {
            after += other;
            return this;
        }

        public Task reaches(Milestone milestone) {
            if (!(milestone in gates)) gates += milestone;
            return this;
        }

        public Task recoverable(string? feature = null) {
            failure = Failure.RECOVERABLE;
            this.feature = feature;
            return this;
        }

        public Task budget(uint ms) {
            budget_ms = ms;
            return this;
        }

        public Task cache(string key) {
            cache_key = key;
            return this;
        }

        public Task heavy_io() {
            io_heavy = true;
            return this;
        }

        public Task memory(uint64 bytes) {
            memory_hint = bytes;
            return this;
        }

        public Task uncancellable() {
            cancellable = false;
            return this;
        }

        public string[] dependencies() {
            return after;
        }

        public Milestone[] milestones() {
            return gates;
        }

        public bool finished() {
            return state == TaskState.DONE || state == TaskState.FAILED || state == TaskState.SKIPPED || state == TaskState.CANCELLED;
        }

        public int64 duration_us() {
            return started_us >= 0 && finished_us >= started_us ? finished_us - started_us : 0;
        }
    }

    public class Plan : Object {
        public const uint32 REUSE_REGION = 11;

        public PlanKind kind { get; construct; }
        public string version { get; set; default = "1"; }

        private Gee.ArrayList<Task> ordered = new Gee.ArrayList<Task>();
        private Gee.HashMap<string, Task> by_id = new Gee.HashMap<string, Task>();
        private Gee.ArrayList<string> problems = new Gee.ArrayList<string>();

        public Plan(PlanKind kind = PlanKind.STRUCTURED) {
            Object(kind: kind);
        }

        public static Plan wrapped(owned MainWork activate) {
            var plan = new Plan(PlanKind.LEGACY_WRAPPED);
            plan.main("activate", Category.SHELL, (owned) activate)
                .reaches(Milestone.SHELL_READY)
                .reaches(Milestone.CONTENT_READY)
                .reaches(Milestone.INTERACTIVE);
            return plan;
        }

        public Task main(string id, Category category, owned MainWork work) {
            var task = new Task(id, category, Placement.MAIN);
            task.main_work = (owned) work;
            add(task);
            return task;
        }

        public Task steps(string id, Category category, owned StepWork work) {
            var task = new Task(id, category, Placement.MAIN);
            task.step_work = (owned) work;
            add(task);
            return task;
        }

        public Task cached(string id, Category category, string key, owned BytesWork work, owned BytesApply apply) {
            string region_key = id + "\n" + key;
            Task? created = null;
            created = worker(id, category, (c) => {
                bool ran = false;
                Error? failure = null;
                uint8[] produce() {
                    ran = true;
                    try {
                        var body = work(c);
                        var tagged = new uint8[body.length + 1];
                        tagged[0] = 1;
                        Memory.copy(&tagged[1], body, body.length);
                        return tagged;
                    } catch (Error e) {
                        failure = e;
                        return { 0 };
                    }
                }
                bool use = (Policy.active() & Policy.COMPUTE) != 0 && Singularity.Compute.available();
                uint8[] tagged = use ? Singularity.Compute.shared().call(REUSE_REGION, Singularity.Compute.key("startup", region_key.data), produce) : produce();
                if (failure != null) throw failure;
                if (tagged.length == 0 || tagged[0] != 1) {
                    ran = false;
                    tagged = produce();
                    if (failure != null) throw failure;
                }
                return new Reuse(tagged[1:tagged.length], use && !ran);
            }, (c, o) => {
                var r = (Reuse) o;
                created.cached = r.reused;
                apply(c, r.bytes);
            });
            created.cache_key = key;
            return created;
        }

        public Task worker(string id, Category category, owned WorkerWork work, owned Apply? apply = null) {
            var task = new Task(id, category, Placement.WORKER);
            task.worker_work = (owned) work;
            task.apply = (owned) apply;
            add(task);
            return task;
        }

        private void add(Task task) {
            if (by_id.has_key(task.id)) problems.add("task \"%s\" is declared twice".printf(task.id));
            else by_id[task.id] = task;
            ordered.add(task);
        }

        public Task? get_task(string id) {
            return by_id[id];
        }

        public Gee.List<Task> tasks() {
            return ordered.read_only_view;
        }

        public void validate(bool require_milestones = true) throws PlanError {
            var errors = new Gee.ArrayList<string>();
            errors.add_all(problems);
            if (ordered.size == 0) errors.add("the plan has no tasks");
            foreach (var t in ordered) {
                if (t.id.strip() == "") errors.add("a task has an empty id");
                foreach (var d in t.after) {
                    if (d == t.id) errors.add("task \"%s\" depends on itself".printf(t.id));
                    else if (!by_id.has_key(d)) errors.add("task \"%s\" depends on unknown task \"%s\"".printf(t.id, d));
                }
            }
            if (errors.size == 0) {
                var cycle = find_cycle();
                if (cycle != null) errors.add("dependency cycle: %s".printf(cycle));
            }
            if (errors.size == 0) {
                foreach (var m in new Milestone[] { Milestone.SHELL_READY, Milestone.CONTENT_READY, Milestone.INTERACTIVE }) {
                    bool gated = false;
                    foreach (var t in ordered) gated |= m in t.gates;
                    if (!gated && require_milestones && kind == PlanKind.STRUCTURED) errors.add("no task reaches milestone %s".printf(m.to_id()));
                }
                foreach (var t in ordered) {
                    if (t.category == Category.DEFERRED && (Milestone.SHELL_READY in t.gates || Milestone.CONTENT_READY in t.gates || Milestone.INTERACTIVE in t.gates)) {
                        errors.add("deferred task \"%s\" cannot gate an early milestone".printf(t.id));
                    }
                    if (t.placement == Placement.MAIN && t.main_work == null && t.step_work == null) errors.add("task \"%s\" has no work".printf(t.id));
                    if (t.placement == Placement.WORKER && t.worker_work == null) errors.add("task \"%s\" has no work".printf(t.id));
                }
                foreach (var t in ordered) {
                    foreach (var d in t.after) {
                        var dep = by_id[d];
                        if (dep.category == Category.DEFERRED && t.category != Category.DEFERRED && t.gates.length > 0) {
                            errors.add("task \"%s\" gates a milestone but waits for deferred task \"%s\"".printf(t.id, d));
                        }
                    }
                }
            }
            if (errors.size > 0) {
                throw new PlanError.INVALID(string.joinv("; ", errors.to_array()));
            }
        }

        private string? find_cycle() {
            var mark = new Gee.HashMap<string, int>();
            var stack = new Gee.ArrayList<string>();
            foreach (var t in ordered) {
                var found = visit(t.id, mark, stack);
                if (found != null) return found;
            }
            return null;
        }

        private string? visit(string id, Gee.HashMap<string, int> mark, Gee.ArrayList<string> stack) {
            int m = mark.has_key(id) ? mark[id] : 0;
            if (m == 2) return null;
            if (m == 1) {
                int from = stack.index_of(id);
                var loop = new Gee.ArrayList<string>();
                for (int i = from; i < stack.size; i++) loop.add(stack[i]);
                loop.add(id);
                return string.joinv(", ", loop.to_array());
            }
            mark[id] = 1;
            stack.add(id);
            foreach (var d in by_id[id].after) {
                var found = visit(d, mark, stack);
                if (found != null) return found;
            }
            stack.remove_at(stack.size - 1);
            mark[id] = 2;
            return null;
        }

        public Gee.List<Task> dependents_of(Task task) {
            var list = new Gee.ArrayList<Task>();
            foreach (var t in ordered) {
                if (task.id in t.after) list.add(t);
            }
            return list;
        }
    }
}
