namespace Singularity {

    public class LedDevice : Object {
        public const string SOCKET_PATH = "/run/sinty-matrix/socket";

        private const uint8 KIND_HELLO = 0x01;
        private const uint8 KIND_FRAME = 0x10;
        private const uint8 KIND_BRIGHTNESS = 0x11;
        private const uint8 KIND_CLEAR = 0x12;
        private const uint8 KIND_HOLD = 0x13;
        private const uint8 KIND_INFO = 0x81;

        public int width { get; private set; default = 0; }
        public int height { get; private set; default = 0; }
        public int levels { get; private set; default = 8; }
        public uint firmware { get; private set; default = 0; }

        private Socket socket;

        public signal void lost();

        private LedDevice(Socket socket) {
            this.socket = socket;
        }

        public static bool present() {
            return FileUtils.test(SOCKET_PATH, FileTest.EXISTS);
        }

        public static LedDevice? open() {
            if (!present()) return null;
            try {
                var s = new Socket(SocketFamily.UNIX, SocketType.SEQPACKET, SocketProtocol.DEFAULT);
                s.timeout = 2;
                s.connect(new UnixSocketAddress(SOCKET_PATH));
                var d = new LedDevice(s);
                if (!d.hello()) {
                    s.close();
                    return null;
                }
                s.timeout = 0;
                s.blocking = false;
                return d;
            } catch (Error e) {
                debug("LedDevice: %s", e.message);
                return null;
            }
        }

        private bool hello() throws Error {
            socket.send({ KIND_HELLO });
            var buf = new uint8[64];
            ssize_t n = socket.receive(buf);
            if (n < 7 || buf[0] != KIND_INFO) return false;
            width = buf[2];
            height = buf[3];
            levels = buf[4];
            firmware = buf[5] | (buf[6] << 8);
            return width > 0 && height > 0;
        }

        private bool send(uint8 kind, uint8[] payload) {
            if (socket.is_closed()) return false;
            var msg = new uint8[payload.length + 1];
            msg[0] = kind;
            Memory.copy(&msg[1], payload, payload.length);
            try {
                socket.send(msg);
                return true;
            } catch (IOError.WOULD_BLOCK e) {
                return true;
            } catch (Error e) {
                close();
                lost();
                return false;
            }
        }

        public bool frame(uint8[] pixels) {
            if (pixels.length != width * height) return false;
            return send(KIND_FRAME, pixels);
        }

        public bool brightness(int level) {
            return send(KIND_BRIGHTNESS, { (uint8) level.clamp(0, 7) });
        }

        public bool clear() {
            return send(KIND_CLEAR, {});
        }

        public bool hold(bool held) {
            return send(KIND_HOLD, { held ? (uint8) 1 : (uint8) 0 });
        }

        public void close() {
            try {
                if (!socket.is_closed()) socket.close();
            } catch (Error e) {
            }
        }
    }
}
