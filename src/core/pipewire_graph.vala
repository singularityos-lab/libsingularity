using GLib;

namespace Singularity {

    [CCode (has_type_id = false)]
    private struct PipeWireObjectView {
        uint32 id;
        int32 kind;
        uint32 output_node;
        uint32 input_node;
        size_t n_props;
        char** keys;
        char** values;
    }

    /**
     * Reads the PipeWire graph through libsinty-system-core, which speaks the
     * PipeWire protocol itself, and returns it in the shape `pw-dump` prints:
     * nodes, clients and links with their properties. Without the library
     * the graph is empty.
     */
    public class PipeWireGraph : Object {
        [CCode (has_target = false)]
        private delegate int GraphFn(out void* graph);
        [CCode (has_target = false)]
        private delegate size_t CountFn(void* graph);
        [CCode (has_target = false)]
        private delegate void* AtFn(void* graph, size_t index);
        [CCode (has_target = false)]
        private delegate void FreeFn(void* graph);

        private static bool probed = false;
        private static Module? library = null;
        private static GraphFn graph_fn;
        private static CountFn count_fn;
        private static AtFn at_fn;
        private static FreeFn free_fn;
        private static Mutex guard;

        public static bool available() {
            guard.lock();
            bool ok = load();
            guard.unlock();
            return ok;
        }

        private static bool load() {
            if (probed) return library != null;
            probed = true;
            var module = Module.open("libsinty-system-core.so.1", ModuleFlags.LAZY | ModuleFlags.LOCAL);
            if (module == null) return false;
            void* a = null;
            void* b = null;
            void* c = null;
            void* d = null;
            if (!module.symbol("sinty_audio_graph", out a)
                    || !module.symbol("sinty_audio_graph_count", out b)
                    || !module.symbol("sinty_audio_graph_at", out c)
                    || !module.symbol("sinty_audio_graph_free", out d))
                return false;
            graph_fn = (GraphFn) a;
            count_fn = (CountFn) b;
            at_fn = (AtFn) c;
            free_fn = (FreeFn) d;
            library = (owned) module;
            return true;
        }

        private static string type_name(int32 kind) {
            switch (kind) {
                case 1: return "PipeWire:Interface:Node";
                case 2: return "PipeWire:Interface:Client";
                default: return "PipeWire:Interface:Link";
            }
        }

        /** Reads the graph now, blocking for at most a few seconds. */
        public static string? dump_sync() {
            if (!available()) return null;
            void* graph = null;
            if (graph_fn(out graph) < 0 || graph == null) return null;
            var b = new Json.Builder();
            b.begin_array();
            size_t n = count_fn(graph);
            for (size_t i = 0; i < n; i++) {
                PipeWireObjectView* o = (PipeWireObjectView*) at_fn(graph, i);
                if (o == null) continue;
                b.begin_object();
                b.set_member_name("id");
                b.add_int_value(o->id);
                b.set_member_name("type");
                b.add_string_value(type_name(o->kind));
                b.set_member_name("info");
                b.begin_object();
                if (o->kind == 3) {
                    b.set_member_name("output-node-id");
                    b.add_int_value(o->output_node);
                    b.set_member_name("input-node-id");
                    b.add_int_value(o->input_node);
                }
                b.set_member_name("props");
                b.begin_object();
                for (size_t j = 0; j < o->n_props; j++) {
                    b.set_member_name((string) o->keys[j]);
                    b.add_string_value((string) o->values[j]);
                }
                b.end_object();
                b.end_object();
                b.end_object();
            }
            b.end_array();
            free_fn(graph);
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        /** Reads the graph on a worker thread. */
        public static async string? dump(Cancellable? cancellable = null) {
            string? result = null;
            SourceFunc resume = dump.callback;
            new Thread<void>("pipewire-graph", () => {
                result = dump_sync();
                Idle.add((owned) resume);
            });
            yield;
            if (cancellable != null && cancellable.is_cancelled()) return null;
            return result;
        }
    }
}
