namespace Singularity {

    public class SystemClipboard : Object {
        private static SintySystem.ClipboardHolder? holder = null;

        public static bool owns() {
            return holder != null && holder.active();
        }

        public static void set_bytes(Bytes data, string[] mime_types, bool primary = false) throws IOError {
            SintySystem.ClipboardHolder h;
            int rc = SintySystem.clipboard_set(data.get_data(), mime_types, primary, out h);
            if (rc < 0) throw new IOError.FAILED(Posix.strerror(-rc));
            holder = (owned) h;
        }

        public static void release() {
            holder = null;
        }
    }
}
