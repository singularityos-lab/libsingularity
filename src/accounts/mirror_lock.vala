namespace Singularity.Accounts {

    [CCode (cname = "open", cheader_filename = "fcntl.h")]
    private extern int mirror_lock_open(string path, int flags, int mode);
    [CCode (cname = "close", cheader_filename = "unistd.h")]
    private extern int mirror_lock_close(int fd);
    [CCode (cname = "flock", cheader_filename = "sys/file.h")]
    private extern int mirror_lock_flock(int fd, int operation);
    [CCode (cname = "O_RDWR", cheader_filename = "fcntl.h")]
    private extern const int MIRROR_O_RDWR;
    [CCode (cname = "O_CREAT", cheader_filename = "fcntl.h")]
    private extern const int MIRROR_O_CREAT;
    [CCode (cname = "O_CLOEXEC", cheader_filename = "fcntl.h")]
    private extern const int MIRROR_O_CLOEXEC;
    [CCode (cname = "LOCK_EX", cheader_filename = "sys/file.h")]
    private extern const int MIRROR_LOCK_EX;
    [CCode (cname = "LOCK_NB", cheader_filename = "sys/file.h")]
    private extern const int MIRROR_LOCK_NB;
    [CCode (cname = "LOCK_UN", cheader_filename = "sys/file.h")]
    private extern const int MIRROR_LOCK_UN;

    internal class MirrorLock : Object {
        private static Gee.HashMap<string, MirrorLock>? locks;

        public string path { get; construct; }

        private int fd = -1;
        private int depth = 0;

        private MirrorLock(string path) {
            Object(path: path);
        }

        public static MirrorLock for_path(string path) {
            if (locks == null) locks = new Gee.HashMap<string, MirrorLock>();
            var existing = locks[path];
            if (existing != null) return existing;
            var created = new MirrorLock(path);
            locks[path] = created;
            return created;
        }

        private bool open_file() {
            if (fd >= 0) return true;
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            fd = mirror_lock_open(path, MIRROR_O_RDWR | MIRROR_O_CREAT | MIRROR_O_CLOEXEC, 0600);
            if (fd < 0) warning("accounts: cannot open the lock %s: %s", path, strerror(errno));
            return fd >= 0;
        }

        public void acquire() {
            if (depth++ > 0 || !open_file()) return;
            for (int i = 0; i < 100 && mirror_lock_flock(fd, MIRROR_LOCK_EX) != 0; i++) {
            }
        }

        public bool try_acquire() {
            if (depth > 0) return false;
            if (!open_file()) {
                depth++;
                return true;
            }
            if (mirror_lock_flock(fd, MIRROR_LOCK_EX | MIRROR_LOCK_NB) != 0) return false;
            depth++;
            return true;
        }

        public async bool acquire_async(Cancellable? cancellable = null) {
            while (!try_acquire()) {
                if (cancellable != null && cancellable.is_cancelled()) return false;
                Timeout.add(150, acquire_async.callback);
                yield;
            }
            return true;
        }

        public void release() {
            if (depth == 0) return;
            depth--;
            if (depth == 0 && fd >= 0) mirror_lock_flock(fd, MIRROR_LOCK_UN);
        }

        public void discard() {
            if (fd >= 0) mirror_lock_close(fd);
            fd = -1;
            depth = 0;
            FileUtils.unlink(path);
            if (locks != null) locks.unset(path);
        }
    }
}
