namespace Singularity.Remote {

    public class VncSession : RemoteSession {
        private const int ENC_RAW = 0;
        private const int ENC_COPYRECT = 1;
        private const int ENC_HEXTILE = 5;
        private const int ENC_ZRLE = 16;
        private const int ENC_DESKTOP_SIZE = -223;
        private const int ENC_LAST_RECT = -224;
        private const int ENC_CURSOR = -239;
        private const int ENC_EXT_DESKTOP_SIZE = -308;
        private const int ENC_EXT_CLIPBOARD = -1063131698;
        private const uint32 CLIP_TEXT = 1;
        private const uint32 CLIP_CAPS = 1 << 24;
        private const uint32 CLIP_REQUEST = 1 << 25;
        private const uint32 CLIP_PEEK = 1 << 26;
        private const uint32 CLIP_NOTIFY = 1 << 27;
        private const uint32 CLIP_PROVIDE = 1 << 28;
        private const uint32 CLIP_MAX = 1 << 20;

        private SocketConnection? socket;
        private IOStream? stream;
        private BufferedInputStream? input;
        private OutputStream? output;
        private Cancellable cancel = new Cancellable ();
        private Framebuffer fb = new Framebuffer ();
        private ZlibDecompressor zlib = new ZlibDecompressor (ZlibCompressorFormat.ZLIB);
        private int minor = 8;
        private uint buttons_down;
        private SourceFunc? resume;
        private bool closing;
        private uint32 screen_id;
        private uint32 screen_flags;
        private uint8 hextile_bg[4];
        private uint8 hextile_fg[4];
        private string tls_host;
        private bool frame_pending;
        private SocketConnectable? address;
        private bool ext_clipboard;
        private string local_clipboard = "";

        public bool extended_clipboard {
            get { return ext_clipboard; }
        }

        public VncSession (string host, int port) {
            Object (host: host, port: port);
            tls_host = host;
        }

        public VncSession.with_address (SocketConnectable address, string label) {
            Object (host: label, port: 0);
            tls_host = label;
            this.address = address;
        }

        public override void start () {
            run.begin ();
        }

        public override void stop () {
            if (closing) return;
            closing = true;
            active = false;
            cancel.cancel ();
            if (stream != null) {
                try {
                    stream.close ();
                } catch (Error e) {
                }
            }
            if (resume != null) {
                var r = (owned) resume;
                resume = null;
                r ();
            }
        }

        private void finish (Error? error) {
            bool was_closing = closing;
            stop ();
            if (was_closing && error != null) closed (null);
            else closed (error);
        }

        public override void provide_credentials (string username, string password, string domain) {
            this.username = username;
            this.password = password;
            if (resume != null) {
                var r = (owned) resume;
                resume = null;
                r ();
            }
        }

        private async void wait_credentials (bool want_username, string? reason) throws Error {
            resume = wait_credentials.callback;
            credentials_needed (want_username, reason);
            yield;
            if (closing) throw new IOError.CANCELLED ("cancelled");
        }

        private async void need (size_t n) throws Error {
            if (input.buffer_size < n) input.buffer_size = (uint) (n + 65536);
            while (input.get_available () < n) {
                ssize_t r = yield input.fill_async ((ssize_t) (input.buffer_size - input.get_available ()), Priority.DEFAULT, cancel);
                if (r <= 0) throw new IOError.CONNECTION_CLOSED (_("The remote computer closed the connection."));
            }
        }

        private async uint8 u8 () throws Error {
            yield need (1);
            return (uint8) input.read_byte (null);
        }

        private async uint16 u16 () throws Error {
            yield need (2);
            uint8 a = (uint8) input.read_byte (null);
            uint8 b = (uint8) input.read_byte (null);
            return (uint16) ((a << 8) | b);
        }

        private async uint32 u32 () throws Error {
            yield need (4);
            uint32 v = 0;
            for (int i = 0; i < 4; i++) v = (v << 8) | (uint8) input.read_byte (null);
            return v;
        }

        private async uint8[] take (size_t n) throws Error {
            var buf = new uint8[n];
            if (n == 0) return buf;
            yield need (n);
            size_t got;
            input.read_all (buf, out got, null);
            return buf;
        }

        private async void skip (size_t n) throws Error {
            while (n > 0) {
                size_t chunk = size_t.min (n, 1 << 20);
                yield take (chunk);
                n -= chunk;
            }
        }

        private async string text (size_t n) throws Error {
            var raw = yield take (n);
            var sb = new StringBuilder ();
            foreach (uint8 c in raw) {
                if (c < 0x80) sb.append_c ((char) c);
                else sb.append_unichar ((unichar) c);
            }
            return sb.str;
        }

        private void send (uint8[] data) {
            if (output == null || closing) return;
            try {
                size_t written;
                output.write_all (data, out written, cancel);
                output.flush (cancel);
            } catch (Error e) {
                finish (e);
            }
        }

        private static void put16 (ByteArray b, uint16 v) {
            b.append ({ (uint8) (v >> 8), (uint8) v });
        }

        private static void put32 (ByteArray b, uint32 v) {
            b.append ({ (uint8) (v >> 24), (uint8) (v >> 16), (uint8) (v >> 8), (uint8) v });
        }

        private void attach (IOStream s) {
            stream = s;
            input = new BufferedInputStream.sized (s.input_stream, 1 << 16);
            output = s.output_stream;
        }

        private async void run () {
            try {
                var client = new SocketClient ();
                client.timeout = 15;
                if (address != null) {
                    socket = yield client.connect_async (address, cancel);
                } else {
                    socket = yield client.connect_to_host_async (host, (uint16) port, cancel);
                    socket.socket.set_option (6, 1, 1);
                }
                socket.socket.timeout = 0;
                attach (socket);
                yield handshake ();
                yield init ();
                active = true;
                ready ();
                request_update (false);
                while (!closing) yield message ();
            } catch (Error e) {
                if (e is IOError.CANCELLED) finish (null);
                else finish (e);
            }
        }

        private async void handshake () throws Error {
            var version = yield text (12);
            if (!version.has_prefix ("RFB ")) throw new SessionError.UNSUPPORTED (_("This is not a VNC server."));
            int major = int.parse (version.substring (4, 3));
            int server_minor = int.parse (version.substring (8, 3));
            if (major > 3 || server_minor >= 8) minor = 8;
            else if (server_minor == 7) minor = 7;
            else minor = 3;
            send ("RFB 003.%03d\n".printf (minor).data);

            uint8[] types;
            if (minor == 3) {
                uint32 t = yield u32 ();
                if (t == 0) throw new SessionError.FAILED (yield text (yield u32 ()));
                types = { (uint8) t };
            } else {
                uint8 n = yield u8 ();
                if (n == 0) throw new SessionError.FAILED (yield text (yield u32 ()));
                types = yield take (n);
            }

            bool has_none = false, has_vnc = false, has_vencrypt = false;
            foreach (uint8 t in types) {
                if (t == 1) has_none = true;
                if (t == 2) has_vnc = true;
                if (t == 19) has_vencrypt = true;
            }
            uint8 chosen;
            if (has_vencrypt) chosen = 19;
            else if (has_vnc) chosen = 2;
            else if (has_none) chosen = 1;
            else throw new SessionError.UNSUPPORTED (_("The remote computer asks for a kind of security this app does not support."));
            if (minor != 3) send ({ chosen });

            bool check_result = true;
            if (chosen == 1) {
                check_result = minor == 8;
            } else if (chosen == 2) {
                yield vnc_auth ();
            } else {
                yield vencrypt ();
            }
            if (check_result) {
                uint32 result = yield u32 ();
                if (result != 0) {
                    string reason = minor == 8 ? yield text (yield u32 ()) : "";
                    password = "";
                    throw new SessionError.AUTH_FAILED (reason != "" ? reason : _("The password was not accepted."));
                }
            }
        }

        private async void vnc_auth () throws Error {
            var challenge = yield take (16);
            if (password == "") yield wait_credentials (false, null);
            send (Des.vnc_response (password, challenge));
        }

        private async void vencrypt () throws Error {
            uint8 major = yield u8 ();
            uint8 vminor = yield u8 ();
            if (major != 0 || vminor < 2) throw new SessionError.UNSUPPORTED (_("The remote computer uses an old kind of encryption."));
            send ({ 0, 2 });
            if ((yield u8 ()) != 0) throw new SessionError.UNSUPPORTED (_("The remote computer refused the encryption setup."));
            uint8 n = yield u8 ();
            var subtypes = new uint32[n];
            for (int i = 0; i < n; i++) subtypes[i] = yield u32 ();
            uint32 chosen = 0;
            foreach (uint32 pref in new uint32[] { 262, 261, 260 }) {
                foreach (uint32 s in subtypes) {
                    if (s == pref) {
                        chosen = pref;
                        break;
                    }
                }
                if (chosen != 0) break;
            }
            if (chosen == 0) {
                foreach (uint32 s in subtypes) {
                    if (s == 1) chosen = 1;
                    else if (s == 2 && chosen != 1) chosen = 2;
                }
            }
            if (chosen == 0) throw new SessionError.UNSUPPORTED (_("The remote computer only offers encryption without certificates, which this app does not support."));
            var b = new ByteArray ();
            put32 (b, chosen);
            send (b.data);
            if (chosen == 1) return;
            if (chosen == 2) {
                yield vnc_auth ();
                return;
            }
            if ((yield u8 ()) != 1) throw new SessionError.UNSUPPORTED (_("The remote computer refused the encryption setup."));

            var identity = new NetworkAddress (tls_host, (uint16) port);
            var tls = TlsClientConnection.new (stream, identity);
            tls.accept_certificate.connect ((cert, errors) => {
                string fp = RemoteSession.fingerprint_of (cert.certificate.data);
                if (fp == trusted_fingerprint) return true;
                pending_fingerprint = fp;
                return false;
            });
            try {
                yield tls.handshake_async (Priority.DEFAULT, cancel);
            } catch (Error e) {
                if (pending_fingerprint != "" && pending_fingerprint != trusted_fingerprint) {
                    throw new SessionError.UNTRUSTED (_("The identity of the remote computer could not be verified."));
                }
                throw e;
            }
            attach (tls);

            if (chosen == 261) {
                yield vnc_auth ();
            } else if (chosen == 262) {
                if (password == "" || username == "") yield wait_credentials (true, null);
                var cred = new ByteArray ();
                put32 (cred, username.data.length);
                put32 (cred, password.data.length);
                cred.append (username.data);
                cred.append (password.data);
                send (cred.data);
            }
        }

        private async void init () throws Error {
            send ({ 1 });
            int w = yield u16 ();
            int h = yield u16 ();
            yield take (16);
            desktop_name = yield text (yield u32 ());
            fb.resize (w, h);
            width = w;
            height = h;

            var pf = new ByteArray ();
            pf.append ({ 0, 0, 0, 0 });
            pf.append ({ 32, 24, 0, 1 });
            put16 (pf, 255);
            put16 (pf, 255);
            put16 (pf, 255);
            pf.append ({ 16, 8, 0, 0, 0, 0 });
            send (pf.data);

            int[] encodings = { ENC_ZRLE, ENC_HEXTILE, ENC_COPYRECT, ENC_RAW, ENC_EXT_DESKTOP_SIZE, ENC_DESKTOP_SIZE, ENC_LAST_RECT, ENC_CURSOR, ENC_EXT_CLIPBOARD };
            var enc = new ByteArray ();
            enc.append ({ 2, 0 });
            put16 (enc, (uint16) encodings.length);
            foreach (int e in encodings) put32 (enc, (uint32) e);
            send (enc.data);
            publish ();
        }

        private void request_update (bool incremental) {
            var b = new ByteArray ();
            b.append ({ 3, incremental ? 1 : 0 });
            put16 (b, 0);
            put16 (b, 0);
            put16 (b, (uint16) fb.width);
            put16 (b, (uint16) fb.height);
            send (b.data);
        }

        private void publish () {
            var t = fb.commit ();
            if (t == null) return;
            texture = t;
            width = fb.width;
            height = fb.height;
            if (!frame_pending) {
                frame_pending = true;
                Idle.add_full (Priority.HIGH_IDLE, () => {
                    frame_pending = false;
                    frame ();
                    return Source.REMOVE;
                });
            }
        }

        private async void message () throws Error {
            uint8 type = yield u8 ();
            switch (type) {
                case 0:
                    yield update ();
                    publish ();
                    request_update (true);
                    break;
                case 1:
                    yield take (3);
                    int n = yield u16 ();
                    yield skip (n * 6);
                    break;
                case 2:
                    bell ();
                    break;
                case 3:
                    yield take (3);
                    uint32 len = yield u32 ();
                    if ((len & 0x80000000) != 0) {
                        var payload = yield take ((size_t) (-(int32) len));
                        clipboard_message (payload);
                    } else {
                        var t = yield text (len);
                        remote_clipboard (t.replace ("\r\n", "\n"));
                    }
                    break;
                case 150:
                    break;
                default:
                    throw new SessionError.UNSUPPORTED (_("The remote computer sent a message this app does not understand."));
            }
        }

        private async void update () throws Error {
            yield take (1);
            int n = yield u16 ();
            for (int i = 0; i < n; i++) {
                int x = yield u16 ();
                int y = yield u16 ();
                int w = yield u16 ();
                int h = yield u16 ();
                int enc = (int) (int32) (yield u32 ());
                switch (enc) {
                    case ENC_RAW:
                        yield raw (x, y, w, h);
                        break;
                    case ENC_COPYRECT:
                        int sx = yield u16 ();
                        int sy = yield u16 ();
                        fb.copy_rect (sx, sy, x, y, w, h);
                        fb.add_damage (x, y, w, h);
                        break;
                    case ENC_HEXTILE:
                        yield hextile (x, y, w, h);
                        break;
                    case ENC_ZRLE:
                        yield zrle (x, y, w, h);
                        break;
                    case ENC_DESKTOP_SIZE:
                        resize_to (w, h);
                        break;
                    case ENC_EXT_DESKTOP_SIZE:
                        int screens = yield u8 ();
                        yield take (3);
                        for (int s = 0; s < screens; s++) {
                            uint32 id = yield u32 ();
                            yield take (8);
                            uint32 flags = yield u32 ();
                            if (s == 0) {
                                screen_id = id;
                                screen_flags = flags;
                            }
                        }
                        can_resize = true;
                        if (y == 0 && (w != fb.width || h != fb.height)) resize_to (w, h);
                        break;
                    case ENC_LAST_RECT:
                        return;
                    case ENC_CURSOR:
                        yield cursor (x, y, w, h);
                        break;
                    default:
                        throw new SessionError.UNSUPPORTED (_("The remote computer sent a picture format this app does not understand."));
                }
            }
        }

        private void resize_to (int w, int h) {
            fb.resize (w, h);
            width = w;
            height = h;
        }

        private bool fits (int x, int y, int w, int h) {
            return x >= 0 && y >= 0 && x + w <= fb.width && y + h <= fb.height;
        }

        private async void raw (int x, int y, int w, int h) throws Error {
            var px = yield take ((size_t) w * h * 4);
            if (!fits (x, y, w, h)) return;
            for (int row = 0; row < h; row++) {
                Memory.copy (&fb.data[(y + row) * fb.stride + x * 4], &px[row * w * 4], w * 4);
            }
            for (int row = 0; row < h; row++) {
                int o = (y + row) * fb.stride + x * 4 + 3;
                for (int col = 0; col < w; col++) {
                    fb.data[o] = 255;
                    o += 4;
                }
            }
            fb.add_damage (x, y, w, h);
        }

        private async void hextile (int x, int y, int w, int h) throws Error {
            bool ok = fits (x, y, w, h);
            for (int ty = y; ty < y + h; ty += 16) {
                int th = int.min (16, y + h - ty);
                for (int tx = x; tx < x + w; tx += 16) {
                    int tw = int.min (16, x + w - tx);
                    uint8 mask = yield u8 ();
                    if ((mask & 1) != 0) {
                        var px = yield take ((size_t) tw * th * 4);
                        if (ok) {
                            for (int row = 0; row < th; row++) {
                                int o = (ty + row) * fb.stride + tx * 4;
                                for (int col = 0; col < tw; col++) {
                                    int s = (row * tw + col) * 4;
                                    fb.data[o] = px[s];
                                    fb.data[o + 1] = px[s + 1];
                                    fb.data[o + 2] = px[s + 2];
                                    fb.data[o + 3] = 255;
                                    o += 4;
                                }
                            }
                        }
                        continue;
                    }
                    if ((mask & 2) != 0) {
                        var p = yield take (4);
                        for (int k = 0; k < 4; k++) hextile_bg[k] = p[k];
                    }
                    if ((mask & 4) != 0) {
                        var p = yield take (4);
                        for (int k = 0; k < 4; k++) hextile_fg[k] = p[k];
                    }
                    if (ok) fb.fill (tx, ty, tw, th, hextile_bg[0], hextile_bg[1], hextile_bg[2]);
                    if ((mask & 8) != 0) {
                        int count = yield u8 ();
                        bool coloured = (mask & 16) != 0;
                        var data = yield take ((size_t) count * (coloured ? 6 : 2));
                        int p = 0;
                        for (int s = 0; s < count; s++) {
                            uint8 b = hextile_fg[0], g = hextile_fg[1], r = hextile_fg[2];
                            if (coloured) {
                                b = data[p];
                                g = data[p + 1];
                                r = data[p + 2];
                                p += 4;
                            }
                            int xy = data[p], wh = data[p + 1];
                            p += 2;
                            int sx = tx + (xy >> 4), sy = ty + (xy & 15);
                            int sw = (wh >> 4) + 1, sh = (wh & 15) + 1;
                            if (ok && sx + sw <= tx + tw && sy + sh <= ty + th) fb.fill (sx, sy, sw, sh, b, g, r);
                        }
                    }
                }
            }
            if (ok) fb.add_damage (x, y, w, h);
        }

        private uint8[] inflate (uint8[] data) throws Error {
            var result = new ByteArray.sized ((uint) data.length * 4);
            var buf = new uint8[1 << 16];
            size_t pos = 0;
            while (true) {
                size_t read, written;
                var res = zlib.convert (data[pos:data.length], buf, ConverterFlags.NONE, out read, out written);
                pos += read;
                if (written > 0) result.append (buf[0:written]);
                if (res == ConverterResult.FINISHED) break;
                if (pos >= data.length && written < buf.length) break;
            }
            return result.steal ();
        }

        private async void zrle (int x, int y, int w, int h) throws Error {
            uint32 len = yield u32 ();
            var packed = yield take (len);
            var z = inflate (packed);
            if (!fits (x, y, w, h)) return;
            int p = 0;
            uint8 pal[128 * 3];
            for (int ty = y; ty < y + h; ty += 64) {
                int th = int.min (64, y + h - ty);
                for (int tx = x; tx < x + w; tx += 64) {
                    int tw = int.min (64, x + w - tx);
                    if (p >= z.length) throw new SessionError.FAILED (_("The picture data from the remote computer is damaged."));
                    int sub = z[p++];
                    bool rle = (sub & 128) != 0;
                    int palsize = sub & 127;
                    if (p + palsize * 3 > z.length) throw new SessionError.FAILED (_("The picture data from the remote computer is damaged."));
                    for (int i = 0; i < palsize * 3; i++) pal[i] = z[p + i];
                    p += palsize * 3;
                    if (sub == 0) {
                        if (p + tw * th * 3 > z.length) throw new SessionError.FAILED (_("The picture data from the remote computer is damaged."));
                        for (int row = 0; row < th; row++) {
                            int o = (ty + row) * fb.stride + tx * 4;
                            for (int col = 0; col < tw; col++) {
                                fb.data[o] = z[p];
                                fb.data[o + 1] = z[p + 1];
                                fb.data[o + 2] = z[p + 2];
                                fb.data[o + 3] = 255;
                                o += 4;
                                p += 3;
                            }
                        }
                    } else if (sub == 1) {
                        fb.fill (tx, ty, tw, th, pal[0], pal[1], pal[2]);
                    } else if (!rle) {
                        int bits = palsize == 2 ? 1 : (palsize <= 4 ? 2 : 4);
                        int per_row = (tw * bits + 7) / 8;
                        if (p + per_row * th > z.length) throw new SessionError.FAILED (_("The picture data from the remote computer is damaged."));
                        for (int row = 0; row < th; row++) {
                            int o = (ty + row) * fb.stride + tx * 4;
                            int bitpos = 0;
                            int rowstart = p + row * per_row;
                            for (int col = 0; col < tw; col++) {
                                int byte_val = z[rowstart + bitpos / 8];
                                int shift = 8 - bits - (bitpos % 8);
                                int idx = (byte_val >> shift) & ((1 << bits) - 1);
                                bitpos += bits;
                                if (idx >= palsize) idx = 0;
                                fb.data[o] = pal[idx * 3];
                                fb.data[o + 1] = pal[idx * 3 + 1];
                                fb.data[o + 2] = pal[idx * 3 + 2];
                                fb.data[o + 3] = 255;
                                o += 4;
                            }
                        }
                        p += per_row * th;
                    } else {
                        int total = tw * th;
                        int done = 0;
                        while (done < total) {
                            uint8 b, g, r;
                            int run = 1;
                            if (palsize == 0) {
                                if (p + 3 > z.length) throw new SessionError.FAILED (_("The picture data from the remote computer is damaged."));
                                b = z[p];
                                g = z[p + 1];
                                r = z[p + 2];
                                p += 3;
                                run = 0;
                                int more = 0;
                                do {
                                    if (p >= z.length) throw new SessionError.FAILED (_("The picture data from the remote computer is damaged."));
                                    more = z[p++];
                                    run += more;
                                } while (more == 255);
                                run += 1;
                            } else {
                                if (p >= z.length) throw new SessionError.FAILED (_("The picture data from the remote computer is damaged."));
                                int idx = z[p++];
                                if ((idx & 128) != 0) {
                                    run = 0;
                                    int more = 0;
                                    do {
                                        if (p >= z.length) throw new SessionError.FAILED (_("The picture data from the remote computer is damaged."));
                                        more = z[p++];
                                        run += more;
                                    } while (more == 255);
                                    run += 1;
                                }
                                idx &= 127;
                                if (idx >= palsize) idx = 0;
                                b = pal[idx * 3];
                                g = pal[idx * 3 + 1];
                                r = pal[idx * 3 + 2];
                            }
                            for (int k = 0; k < run && done < total; k++) {
                                int o = (ty + done / tw) * fb.stride + (tx + done % tw) * 4;
                                fb.data[o] = b;
                                fb.data[o + 1] = g;
                                fb.data[o + 2] = r;
                                fb.data[o + 3] = 255;
                                done++;
                            }
                        }
                    }
                }
            }
            fb.add_damage (x, y, w, h);
        }

        private async void cursor (int hx, int hy, int w, int h) throws Error {
            var px = yield take ((size_t) w * h * 4);
            int mask_stride = (w + 7) / 8;
            var mask = yield take ((size_t) mask_stride * h);
            if (w == 0 || h == 0) {
                cursor_changed (new Gdk.Cursor.from_name ("none", null));
                return;
            }
            var rgba = new uint8[w * h * 4];
            for (int row = 0; row < h; row++) {
                for (int col = 0; col < w; col++) {
                    int s = (row * w + col) * 4;
                    bool on = ((mask[row * mask_stride + col / 8] >> (7 - col % 8)) & 1) != 0;
                    rgba[s] = px[s + 2];
                    rgba[s + 1] = px[s + 1];
                    rgba[s + 2] = px[s];
                    rgba[s + 3] = on ? 255 : 0;
                }
            }
            var tex = new Gdk.MemoryTexture (w, h, Gdk.MemoryFormat.R8G8B8A8, new Bytes (rgba), w * 4);
            cursor_changed (new Gdk.Cursor.from_texture (tex, int.min (hx, w - 1), int.min (hy, h - 1), null));
        }

        public override void send_pointer (int x, int y, uint buttons) {
            if (!active || view_only) return;
            buttons_down = buttons;
            var b = new ByteArray ();
            b.append ({ 5, (uint8) buttons });
            put16 (b, (uint16) x.clamp (0, fb.width - 1));
            put16 (b, (uint16) y.clamp (0, fb.height - 1));
            send (b.data);
        }

        public override void send_scroll (int x, int y, double dx, double dy) {
            if (!active || view_only) return;
            uint bit = 0;
            if (dy < 0) bit = 8;
            else if (dy > 0) bit = 16;
            else if (dx < 0) bit = 32;
            else if (dx > 0) bit = 64;
            if (bit == 0) return;
            uint saved = buttons_down;
            send_pointer (x, y, saved | bit);
            send_pointer (x, y, saved);
        }

        public override void send_key (uint keyval, uint keycode, bool pressed) {
            if (!active || view_only) return;
            var b = new ByteArray ();
            b.append ({ 4, pressed ? 1 : 0, 0, 0 });
            put32 (b, keyval);
            send (b.data);
        }

        private static uint32 read32 (uint8[] p, int at) {
            return ((uint32) p[at] << 24) | ((uint32) p[at + 1] << 16) | ((uint32) p[at + 2] << 8) | (uint32) p[at + 3];
        }

        private void send_clipboard_ext (uint32 flags, uint8[]? body) {
            var b = new ByteArray ();
            b.append ({ 6, 0, 0, 0 });
            int n = 4 + (body != null ? body.length : 0);
            put32 (b, (uint32) (-n));
            put32 (b, flags);
            if (body != null) b.append (body);
            send (b.data);
        }

        private static uint8[] zlib_pack (uint8[] data) throws Error {
            var sink = new MemoryOutputStream.resizable ();
            var conv = new ConverterOutputStream (sink, new ZlibCompressor (ZlibCompressorFormat.ZLIB, -1));
            size_t written;
            conv.write_all (data, out written);
            conv.close ();
            var result = sink.steal_data ();
            result.length = (int) sink.get_data_size ();
            return result;
        }

        private static uint8[] zlib_unpack (uint8[] data) throws Error {
            var src = new MemoryInputStream.from_data (data);
            var conv = new ConverterInputStream (src, new ZlibDecompressor (ZlibCompressorFormat.ZLIB));
            var sink = new MemoryOutputStream.resizable ();
            sink.splice (conv, OutputStreamSpliceFlags.CLOSE_SOURCE | OutputStreamSpliceFlags.CLOSE_TARGET);
            var result = sink.steal_data ();
            result.length = (int) sink.get_data_size ();
            return result;
        }

        public static uint8[] pack_clipboard_text (string text) throws Error {
            var raw = new ByteArray ();
            string crlf = text.replace ("\r\n", "\n").replace ("\n", "\r\n");
            put32 (raw, crlf.data.length + 1);
            raw.append (crlf.data);
            raw.append ({ 0 });
            return zlib_pack (raw.data);
        }

        public static string? unpack_clipboard_text (uint8[] packed) throws Error {
            var raw = zlib_unpack (packed);
            if (raw.length < 4) return null;
            uint32 n = read32 (raw, 0);
            if (n > raw.length - 4) return null;
            var sb = new StringBuilder ();
            for (int i = 4; i < 4 + n; i++) {
                if (raw[i] == 0) break;
                sb.append_c ((char) raw[i]);
            }
            string text = sb.str;
            if (!text.validate ()) text = text.make_valid ();
            return text.replace ("\r\n", "\n");
        }

        private void clipboard_message (uint8[] payload) {
            if (payload.length < 4) return;
            uint32 flags = read32 (payload, 0);
            if ((flags & CLIP_CAPS) != 0) {
                ext_clipboard = true;
                var sizes = new ByteArray ();
                put32 (sizes, CLIP_MAX);
                send_clipboard_ext (CLIP_CAPS | CLIP_REQUEST | CLIP_PEEK | CLIP_NOTIFY | CLIP_PROVIDE | CLIP_TEXT, sizes.data);
                return;
            }
            if ((flags & CLIP_REQUEST) != 0 && (flags & CLIP_TEXT) != 0) {
                try {
                    send_clipboard_ext (CLIP_PROVIDE | CLIP_TEXT, pack_clipboard_text (local_clipboard));
                } catch (Error e) {
                }
            }
            if ((flags & CLIP_PEEK) != 0) {
                send_clipboard_ext (CLIP_NOTIFY | (local_clipboard != "" ? CLIP_TEXT : 0), null);
            }
            if ((flags & CLIP_NOTIFY) != 0 && (flags & CLIP_TEXT) != 0 && !view_only) {
                send_clipboard_ext (CLIP_REQUEST | CLIP_TEXT, null);
            }
            if ((flags & CLIP_PROVIDE) != 0 && (flags & CLIP_TEXT) != 0) {
                try {
                    string? text = unpack_clipboard_text (payload[4:payload.length]);
                    if (text != null) remote_clipboard (text);
                } catch (Error e) {
                }
            }
        }

        public override void send_clipboard (string text) {
            if (!active || view_only) return;
            local_clipboard = text;
            if (ext_clipboard) {
                send_clipboard_ext (CLIP_NOTIFY | CLIP_TEXT, null);
                return;
            }
            var latin = new ByteArray ();
            unichar c;
            int i = 0;
            while (text.get_next_char (ref i, out c)) {
                if (c == '\n') latin.append ({ '\n' });
                else latin.append ({ c < 256 ? (uint8) c : (uint8) '?' });
            }
            var b = new ByteArray ();
            b.append ({ 6, 0, 0, 0 });
            put32 (b, latin.len);
            b.append (latin.data);
            send (b.data);
        }

        public override void request_size (int w, int h) {
            if (!active || !can_resize || w < 64 || h < 64) return;
            if (w == fb.width && h == fb.height) return;
            var b = new ByteArray ();
            b.append ({ 251, 0 });
            put16 (b, (uint16) w);
            put16 (b, (uint16) h);
            b.append ({ 1, 0 });
            put32 (b, screen_id);
            put16 (b, 0);
            put16 (b, 0);
            put16 (b, (uint16) w);
            put16 (b, (uint16) h);
            put32 (b, screen_flags);
            send (b.data);
        }
    }
}
