namespace Singularity {

    public class DurableFile : Object {
        public string path { get; construct; }
        public int mode { get; construct; }

        private Mutex mutex = Mutex();
        private Cond settled = Cond();
        private string? pending = null;
        private bool busy = false;

        public DurableFile(string path, int mode = 0600) {
            Object(path: path, mode: mode);
        }

        public void write(owned string contents) {
            mutex.lock();
            pending = (owned) contents;
            if (!busy) {
                busy = true;
                new Thread<void*>("durable-file", drain);
            }
            mutex.unlock();
        }

        public void flush() {
            mutex.lock();
            while (busy) settled.wait(mutex);
            mutex.unlock();
        }

        private void* drain() {
            while (true) {
                mutex.lock();
                string? contents = (owned) pending;
                pending = null;
                if (contents == null) {
                    busy = false;
                    settled.broadcast();
                    mutex.unlock();
                    return null;
                }
                mutex.unlock();
                store(contents);
            }
        }

        private void store(string contents) {
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            try {
                FileUtils.set_contents_full(path, contents, -1, FileSetContentsFlags.CONSISTENT, mode);
            } catch (Error e) {
                warning("%s: %s", path, e.message);
            }
        }
    }
}
