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
