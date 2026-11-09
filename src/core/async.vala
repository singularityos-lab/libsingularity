namespace Singularity.Async {

    /**
     * How urgent background work is. Interactive and user work always run
     * before utility work, and background work runs at idle CPU priority.
     */
    public enum Qos {
        INTERACTIVE,
        USER,
        UTILITY,
        BACKGROUND
    }

    public delegate T Work<T>(Cancellable? cancellable) throws Error;

    public delegate void Producer(Feed feed, Cancellable? cancellable) throws Error;

    private delegate void* NativeWork(Cancellable? cancellable) throws Error;

    [CCode (cname = "singularity_async_native", cheader_filename = "core/async_engine.h")]
    private extern bool native_engine();

    [CCode (cname = "singularity_async_submit", finish_name = "singularity_async_submit_finish", cheader_filename = "core/async_engine.h")]
    private extern async void* submit(int qos, owned NativeWork work, Cancellable? cancellable) throws Error;

    [CCode (cname = "singularity_async_widget_cancellable", cheader_filename = "core/async_engine.h")]
    private extern unowned Cancellable widget_cancellable(Gtk.Widget widget);

    [CCode (cname = "singularity_async_stream_new", cheader_filename = "core/async_engine.h")]
    private extern void* stream_new();

    [CCode (cname = "singularity_async_stream_free", cheader_filename = "core/async_engine.h")]
    private extern void stream_free(void* stream);

    [CCode (cname = "singularity_async_stream_push", cheader_filename = "core/async_engine.h")]
    private extern void stream_push(void* stream, owned Object item);

    [CCode (cname = "singularity_async_stream_close", cheader_filename = "core/async_engine.h")]
    private extern void stream_close(void* stream, Error? error);

    [CCode (cname = "singularity_async_stream_next", finish_name = "singularity_async_stream_next_finish", cheader_filename = "core/async_engine.h")]
    private extern async GenericArray<Object>? stream_next(void* stream, Cancellable? cancellable) throws Error;

    /**
     * Whether work runs on the SIT engine. Without SIT, the same calls run
     * on the GLib thread pool.
     */
    public bool accelerated() {
        return native_engine();
    }

    private class Slot<T> {
        public T value;
        public Error? error;
    }

    /**
     * Runs work on a worker thread and returns its value on the main thread.
     * The work must not touch widgets; it returns data that the caller
     * applies once this method returns.
     */
    public async T run<T>(owned Work<T> work, Qos qos = Qos.USER, Cancellable? cancellable = null) throws Error {
        var slot = new Slot<T>();
        yield submit((int) qos, (c) => {
            try {
                slot.value = work(c);
            } catch (Error e) {
                slot.error = e;
            }
            return null;
        }, cancellable);
        if (slot.error != null) throw slot.error;
        return slot.value;
    }

    public delegate void Apply();

    public delegate Apply? Job(Cancellable? cancellable) throws Error;

    private class Continuation {
        public Apply? apply;
    }

    /**
     * Runs a job on a worker thread, then runs the function it returns on
     * the main thread. When `owner` is a widget, the job is cancelled and
     * its function dropped once the widget is destroyed; pass null for work
     * that must finish anyway, such as writing files. Errors other than
     * cancellation are logged.
     */
    public void dispatch(Object? owner, Qos qos, owned Job job) {
        Cancellable? cancellable = null;
        var widget = owner as Gtk.Widget;
        if (widget != null) cancellable = scope_of(widget);
        run.begin<Continuation>((c) => {
            var continuation = new Continuation();
            continuation.apply = job(c);
            return continuation;
        }, qos, cancellable, (o, r) => {
            try {
                var continuation = run.end<Continuation>(r);
                if (continuation.apply != null) continuation.apply();
            } catch (IOError.CANCELLED e) {
            } catch (Error e) {
                warning("%s", e.message);
            }
        });
    }

    private class Posted : Object {
        public Apply apply;
        public Cancellable? scope;
    }

    private Feed? posted_feed;
    private Mutex posted_lock;

    private async void drain_posted(Feed feed) {
        while (true) {
            GenericArray<Object>? items = null;
            try {
                items = yield feed.next();
            } catch (Error e) {
            }
            if (items == null) return;
            foreach (unowned Object item in items.data) {
                var posted = (Posted) item;
                if (posted.scope == null || !posted.scope.is_cancelled()) posted.apply();
            }
        }
    }

    /**
     * Runs a function on the main thread from any thread, for example to
     * report progress from a job. Calls arrive in the order they were
     * posted, batched once per frame on the SIT engine. When `owner` is a
     * widget, calls posted after it is destroyed are dropped.
     */
    public void post(Object? owner, owned Apply apply) {
        var posted = new Posted();
        posted.apply = (owned) apply;
        var widget = owner as Gtk.Widget;
        if (widget != null) posted.scope = scope_of(widget);
        posted_lock.lock();
        if (posted_feed == null) {
            posted_feed = new Feed();
            var feed = posted_feed;
            MainContext.default().invoke(() => {
                drain_posted.begin(feed);
                return Source.REMOVE;
            });
        }
        var target = posted_feed;
        posted_lock.unlock();
        target.push(posted);
    }

    /**
     * A cancellable that is cancelled when the widget is destroyed, so work
     * started for it never delivers to a disposed widget.
     */
    public unowned Cancellable scope_of(Gtk.Widget widget) {
        return widget_cancellable(widget);
    }

    /**
     * Objects produced on any thread and read on the main thread in batches:
     * each read returns everything pushed since the previous one.
     */
    public class Feed : Object {
        private void* stream;

        public Feed() {
            stream = stream_new();
        }

        ~Feed() {
            stream_free(stream);
        }

        public void push(Object item) {
            stream_push(stream, item);
        }

        public void close(Error? error = null) {
            stream_close(stream, error);
        }

        /**
         * The next batch in push order, or null once the feed is closed.
         */
        public async GenericArray<Object>? next(Cancellable? cancellable = null) throws Error {
            return yield stream_next(stream, cancellable);
        }

        /**
         * Runs the producer on a worker thread and closes the feed when it
         * returns, with its error if it failed.
         */
        public static Feed spawn(owned Producer producer, Qos qos = Qos.UTILITY, Cancellable? cancellable = null) {
            var feed = new Feed();
            submit.begin((int) qos, (c) => {
                try {
                    producer(feed, c);
                    if (c != null && c.is_cancelled()) {
                        feed.close(new IOError.CANCELLED("Operation was cancelled"));
                    } else {
                        feed.close();
                    }
                } catch (Error e) {
                    feed.close(e);
                }
                return null;
            }, cancellable);
            return feed;
        }
    }
}
