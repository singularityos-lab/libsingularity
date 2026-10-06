namespace Singularity.Pdf {

    public class Aes {
        private const uint8[] SBOX = {
            0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
            0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
            0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
            0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
            0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
            0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
            0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
            0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
            0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
            0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
            0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
            0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
            0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
            0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
            0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
            0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
        };

        private static uint8[]? inv = null;

        private uint8[] round_keys;
        private int rounds;

        public Aes(uint8[] key) {
            if (inv == null) {
                inv = new uint8[256];
                for (int i = 0; i < 256; i++) inv[SBOX[i]] = (uint8) i;
            }
            int nk = key.length / 4;
            rounds = nk + 6;
            int total = 4 * (rounds + 1);
            round_keys = new uint8[total * 4];
            for (int i = 0; i < key.length; i++) round_keys[i] = key[i];
            uint8 rcon = 1;
            for (int i = nk; i < total; i++) {
                uint8 t0 = round_keys[(i - 1) * 4], t1 = round_keys[(i - 1) * 4 + 1], t2 = round_keys[(i - 1) * 4 + 2], t3 = round_keys[(i - 1) * 4 + 3];
                if (i % nk == 0) {
                    uint8 tmp = t0;
                    t0 = SBOX[t1] ^ rcon;
                    t1 = SBOX[t2];
                    t2 = SBOX[t3];
                    t3 = SBOX[tmp];
                    rcon = xtime(rcon);
                } else if (nk > 6 && i % nk == 4) {
                    t0 = SBOX[t0];
                    t1 = SBOX[t1];
                    t2 = SBOX[t2];
                    t3 = SBOX[t3];
                }
                round_keys[i * 4] = round_keys[(i - nk) * 4] ^ t0;
                round_keys[i * 4 + 1] = round_keys[(i - nk) * 4 + 1] ^ t1;
                round_keys[i * 4 + 2] = round_keys[(i - nk) * 4 + 2] ^ t2;
                round_keys[i * 4 + 3] = round_keys[(i - nk) * 4 + 3] ^ t3;
            }
        }

        private static uint8 xtime(uint8 x) {
            return (uint8) ((x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0));
        }

        private static uint8 mul(uint8 a, uint8 b) {
            uint8 r = 0;
            while (b != 0) {
                if ((b & 1) != 0) r ^= a;
                a = xtime(a);
                b >>= 1;
            }
            return r;
        }

        private void add_round_key(uint8[] s, int round) {
            for (int i = 0; i < 16; i++) s[i] ^= round_keys[round * 16 + i];
        }

        public void encrypt_block(uint8[] s) {
            add_round_key(s, 0);
            for (int round = 1; round <= rounds; round++) {
                for (int i = 0; i < 16; i++) s[i] = SBOX[s[i]];
                uint8 t = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t;
                t = s[2]; s[2] = s[10]; s[10] = t; t = s[6]; s[6] = s[14]; s[14] = t;
                t = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t;
                if (round != rounds) {
                    for (int c = 0; c < 4; c++) {
                        uint8 a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3];
                        s[c * 4] = mul(a0, 2) ^ mul(a1, 3) ^ a2 ^ a3;
                        s[c * 4 + 1] = a0 ^ mul(a1, 2) ^ mul(a2, 3) ^ a3;
                        s[c * 4 + 2] = a0 ^ a1 ^ mul(a2, 2) ^ mul(a3, 3);
                        s[c * 4 + 3] = mul(a0, 3) ^ a1 ^ a2 ^ mul(a3, 2);
                    }
                }
                add_round_key(s, round);
            }
        }

        public void decrypt_block(uint8[] s) {
            add_round_key(s, rounds);
            for (int round = rounds - 1; round >= 0; round--) {
                uint8 t = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t;
                t = s[2]; s[2] = s[10]; s[10] = t; t = s[6]; s[6] = s[14]; s[14] = t;
                t = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t;
                for (int i = 0; i < 16; i++) s[i] = inv[s[i]];
                add_round_key(s, round);
                if (round != 0) {
                    for (int c = 0; c < 4; c++) {
                        uint8 a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3];
                        s[c * 4] = mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9);
                        s[c * 4 + 1] = mul(a0, 9) ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13);
                        s[c * 4 + 2] = mul(a0, 13) ^ mul(a1, 9) ^ mul(a2, 14) ^ mul(a3, 11);
                        s[c * 4 + 3] = mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9) ^ mul(a3, 14);
                    }
                }
            }
        }

        public uint8[] cbc_encrypt(uint8[] iv, uint8[] data, bool pad = true) {
            int padding = pad ? 16 - data.length % 16 : 0;
            var output = new uint8[data.length + padding];
            for (int i = 0; i < data.length; i++) output[i] = data[i];
            for (int i = data.length; i < output.length; i++) output[i] = (uint8) padding;
            uint8[] prev = iv[0 : 16];
            uint8[] block = new uint8[16];
            for (int off = 0; off < output.length; off += 16) {
                for (int i = 0; i < 16; i++) block[i] = output[off + i] ^ prev[i];
                encrypt_block(block);
                for (int i = 0; i < 16; i++) output[off + i] = block[i];
                prev = block[0 : 16];
            }
            return output;
        }

        public uint8[] cbc_decrypt(uint8[] iv, uint8[] data, bool unpad = true) {
            int len = data.length - data.length % 16;
            var output = new uint8[len];
            uint8[] prev = iv[0 : 16];
            uint8[] block = new uint8[16];
            for (int off = 0; off < len; off += 16) {
                for (int i = 0; i < 16; i++) block[i] = data[off + i];
                uint8[] cipher = block[0 : 16];
                decrypt_block(block);
                for (int i = 0; i < 16; i++) output[off + i] = block[i] ^ prev[i];
                prev = cipher;
            }
            if (unpad && len > 0) {
                int p = output[len - 1];
                if (p >= 1 && p <= 16 && p <= len) {
                    bool valid = true;
                    for (int i = len - p; i < len; i++) if (output[i] != p) valid = false;
                    if (valid) output.resize(len - p);
                }
            }
            return output;
        }
    }

    public class Crypto {
        public static uint8[] rc4(uint8[] key, uint8[] data) {
            uint8[] s = new uint8[256];
            for (int i = 0; i < 256; i++) s[i] = (uint8) i;
            int j = 0;
            for (int i = 0; i < 256; i++) {
                j = (j + s[i] + key[i % key.length]) & 0xff;
                uint8 t = s[i]; s[i] = s[j]; s[j] = t;
            }
            var output = new uint8[data.length];
            int a = 0, b = 0;
            for (int k = 0; k < data.length; k++) {
                a = (a + 1) & 0xff;
                b = (b + s[a]) & 0xff;
                uint8 t = s[a]; s[a] = s[b]; s[b] = t;
                output[k] = data[k] ^ s[(s[a] + s[b]) & 0xff];
            }
            return output;
        }

        public static uint8[] digest(ChecksumType type, uint8[] data) {
            var c = new Checksum(type);
            c.update(data, data.length);
            size_t len = 64;
            uint8[] out_buf = new uint8[64];
            c.get_digest(out_buf, ref len);
            out_buf.resize((int) len);
            return out_buf;
        }

        public static uint8[] random_bytes(int n) {
            var b = new uint8[n];
            try {
                var f = File.new_for_path("/dev/urandom");
                var s = f.read();
                size_t got;
                s.read_all(b, out got);
                s.close();
                if (got == n) return b;
            } catch (Error e) {
            }
            for (int i = 0; i < n; i++) b[i] = (uint8) Random.int_range(0, 256);
            return b;
        }

        public static uint8[] concat(uint8[] a, uint8[] b) {
            var r = new uint8[a.length + b.length];
            for (int i = 0; i < a.length; i++) r[i] = a[i];
            for (int i = 0; i < b.length; i++) r[a.length + i] = b[i];
            return r;
        }
    }

    public enum CryptMethod {
        NONE,
        RC4,
        AESV2,
        AESV3
    }

    public class Permissions {
        public const int PRINT = 1 << 2;
        public const int MODIFY = 1 << 3;
        public const int COPY = 1 << 4;
        public const int ANNOTATE = 1 << 5;
        public const int FILL_FORMS = 1 << 8;
        public const int ACCESSIBILITY = 1 << 9;
        public const int ASSEMBLE = 1 << 10;
        public const int PRINT_HIGH = 1 << 11;
        public const int ALL = PRINT | MODIFY | COPY | ANNOTATE | FILL_FORMS | ACCESSIBILITY | ASSEMBLE | PRINT_HIGH;

        public static int to_p(int flags) {
            return (int) ((uint32) 0xfffff0c0 | (uint32) flags);
        }
    }

    public delegate uint8[] PubSecUnlock(Gee.List<Bytes> recipients) throws Error;

    public class SecurityHandler {
        public static PubSecUnlock? pubsec_unlocker = null;
        public bool public_key = false;
        public Gee.ArrayList<Bytes> recipients = new Gee.ArrayList<Bytes>();
        private const uint8[] PAD = {
            0x28, 0xbf, 0x4e, 0x5e, 0x4e, 0x75, 0x8a, 0x41, 0x64, 0x00, 0x4e, 0x56, 0xff, 0xfa, 0x01, 0x08,
            0x2e, 0x2e, 0x00, 0xb6, 0xd0, 0x68, 0x3e, 0x80, 0x2f, 0x0c, 0xa9, 0xfe, 0x64, 0x53, 0x69, 0x7a
        };

        public int revision;
        public int version;
        public int key_length;
        public uint8[] file_key;
        public uint8[] o;
        public uint8[] u;
        public uint8[] oe;
        public uint8[] ue;
        public uint8[] perms;
        public int p;
        public bool encrypt_metadata = true;
        public CryptMethod stream_method = CryptMethod.RC4;
        public CryptMethod string_method = CryptMethod.RC4;
        public bool owner_access = false;
        public uint8[] id0;

        public static SecurityHandler? open(Obj encrypt, uint8[] id0, string password) throws PdfError {
            var filter = encrypt.get("Filter");
            if (filter != null && filter.is_name("Adobe.PubSec")) return open_pubsec(encrypt);
            if (filter == null || !filter.is_name("Standard")) {
                throw new PdfError.UNSUPPORTED("encryption with %s is not supported", filter != null ? filter.to_pdf_string() : "an unknown handler");
            }
            var h = new SecurityHandler();
            h.id0 = id0;
            h.version = encrypt.get("V") != null ? encrypt.get("V").as_int(0) : 0;
            h.revision = encrypt.get("R") != null ? encrypt.get("R").as_int(2) : 2;
            h.key_length = encrypt.get("Length") != null ? encrypt.get("Length").as_int(40) / 8 : 5;
            if (h.version == 1) h.key_length = 5;
            h.o = encrypt.get("O") != null ? encrypt.get("O").bytes : new uint8[0];
            h.u = encrypt.get("U") != null ? encrypt.get("U").bytes : new uint8[0];
            h.oe = encrypt.get("OE") != null ? encrypt.get("OE").bytes : new uint8[0];
            h.ue = encrypt.get("UE") != null ? encrypt.get("UE").bytes : new uint8[0];
            h.perms = encrypt.get("Perms") != null ? encrypt.get("Perms").bytes : new uint8[0];
            h.p = encrypt.get("P") != null ? encrypt.get("P").as_int(-1) : -1;
            if (encrypt.get("EncryptMetadata") != null) h.encrypt_metadata = encrypt.get("EncryptMetadata").as_bool(true);
            if (h.version >= 4) {
                h.stream_method = method_for(encrypt, "StmF");
                h.string_method = method_for(encrypt, "StrF");
                if (h.version == 5) h.key_length = 32;
            } else {
                h.stream_method = CryptMethod.RC4;
                h.string_method = CryptMethod.RC4;
            }
            if (!h.authenticate(password)) {
                throw new PdfError.PASSWORD("the password is not correct");
            }
            return h;
        }

        private static CryptMethod method_for(Obj encrypt, string key) {
            var name = encrypt.get(key);
            if (name == null || !name.is_name() || name.name == "Identity") return CryptMethod.NONE;
            var cf = encrypt.get("CF");
            if (cf == null || !cf.is_dict()) return CryptMethod.RC4;
            var filter = cf.get(name.name);
            if (filter == null || !filter.is_dict()) return CryptMethod.RC4;
            var cfm = filter.get("CFM");
            if (cfm == null || !cfm.is_name()) return CryptMethod.NONE;
            switch (cfm.name) {
                case "V2": return CryptMethod.RC4;
                case "AESV2": return CryptMethod.AESV2;
                case "AESV3": return CryptMethod.AESV3;
                default: return CryptMethod.NONE;
            }
        }

        private static uint8[] pad_password(uint8[] pw) {
            var r = new uint8[32];
            int n = int.min(32, pw.length);
            for (int i = 0; i < n; i++) r[i] = pw[i];
            for (int i = n; i < 32; i++) r[i] = PAD[i - n];
            return r;
        }

        private static uint8[] le32(int v) {
            return { (uint8) v, (uint8) (v >> 8), (uint8) (v >> 16), (uint8) (v >> 24) };
        }

        private uint8[] compute_key(uint8[] password) {
            var buf = new ByteArray();
            buf.append(pad_password(password));
            buf.append(o[0 : int.min(32, o.length)]);
            buf.append(le32(p));
            buf.append(id0);
            if (revision >= 4 && !encrypt_metadata) buf.append({ 0xff, 0xff, 0xff, 0xff });
            uint8[] hash = Crypto.digest(ChecksumType.MD5, buf.data);
            if (revision >= 3) {
                for (int i = 0; i < 50; i++) hash = Crypto.digest(ChecksumType.MD5, hash[0 : key_length]);
            }
            return hash[0 : key_length];
        }

        private uint8[] compute_u(uint8[] key) {
            if (revision == 2) return Crypto.rc4(key, PAD);
            var buf = new ByteArray();
            buf.append(PAD);
            buf.append(id0);
            uint8[] hash = Crypto.digest(ChecksumType.MD5, buf.data);
            uint8[] x = Crypto.rc4(key, hash);
            for (int i = 1; i <= 19; i++) {
                var k = new uint8[key.length];
                for (int j = 0; j < key.length; j++) k[j] = key[j] ^ (uint8) i;
                x = Crypto.rc4(k, x);
            }
            var result = new uint8[32];
            for (int i = 0; i < 16; i++) result[i] = x[i];
            return result;
        }

        private bool check_user_legacy(uint8[] password) {
            uint8[] key = compute_key(password);
            uint8[] expected = compute_u(key);
            int n = revision == 2 ? 32 : 16;
            if (u.length < n) return false;
            for (int i = 0; i < n; i++) if (expected[i] != u[i]) return false;
            file_key = key;
            return true;
        }

        private uint8[] owner_rc4_key(uint8[] owner_password) {
            uint8[] hash = Crypto.digest(ChecksumType.MD5, pad_password(owner_password));
            if (revision >= 3) {
                for (int i = 0; i < 50; i++) hash = Crypto.digest(ChecksumType.MD5, hash);
            }
            return hash[0 : key_length];
        }

        private bool check_owner_legacy(uint8[] password) {
            uint8[] key = owner_rc4_key(password);
            uint8[] user;
            if (revision == 2) {
                user = Crypto.rc4(key, o[0 : int.min(32, o.length)]);
            } else {
                user = o[0 : int.min(32, o.length)];
                for (int i = 19; i >= 0; i--) {
                    var k = new uint8[key.length];
                    for (int j = 0; j < key.length; j++) k[j] = key[j] ^ (uint8) i;
                    user = Crypto.rc4(k, user);
                }
            }
            return check_user_legacy(user);
        }

        public static uint8[] hash_r6(uint8[] password, uint8[] salt, uint8[] user_key, int revision) {
            var start = new ByteArray();
            start.append(password);
            start.append(salt);
            start.append(user_key);
            uint8[] k = Crypto.digest(ChecksumType.SHA256, start.data);
            if (revision < 6) return k;
            int round = 0;
            while (true) {
                var k1 = new ByteArray();
                for (int i = 0; i < 64; i++) {
                    k1.append(password);
                    k1.append(k);
                    k1.append(user_key);
                }
                var aes = new Aes(k[0 : 16]);
                uint8[] e = aes.cbc_encrypt(k[16 : 32], k1.data, false);
                int sum = 0;
                for (int i = 0; i < 16; i++) sum += e[i];
                switch (sum % 3) {
                    case 0: k = Crypto.digest(ChecksumType.SHA256, e); break;
                    case 1: k = Crypto.digest(ChecksumType.SHA384, e); break;
                    default: k = Crypto.digest(ChecksumType.SHA512, e); break;
                }
                round++;
                if (round >= 64 && e[e.length - 1] <= round - 32) break;
            }
            return k[0 : 32];
        }

        private static bool equal_prefix(uint8[] a, uint8[] b, int n) {
            if (a.length < n || b.length < n) return false;
            for (int i = 0; i < n; i++) if (a[i] != b[i]) return false;
            return true;
        }

        private bool authenticate_r6(uint8[] password) {
            uint8[] pw = password.length > 127 ? password[0 : 127] : password;
            if (o.length >= 48 && u.length >= 48) {
                uint8[] h = hash_r6(pw, o[32 : 40], u[0 : 48], revision);
                if (equal_prefix(h, o, 32)) {
                    uint8[] ik = hash_r6(pw, o[40 : 48], u[0 : 48], revision);
                    var aes = new Aes(ik);
                    file_key = aes.cbc_decrypt(new uint8[16], oe[0 : 32], false);
                    owner_access = true;
                    return true;
                }
            }
            if (u.length >= 48) {
                uint8[] h = hash_r6(pw, u[32 : 40], {}, revision);
                if (equal_prefix(h, u, 32)) {
                    uint8[] ik = hash_r6(pw, u[40 : 48], {}, revision);
                    var aes = new Aes(ik);
                    file_key = aes.cbc_decrypt(new uint8[16], ue[0 : 32], false);
                    return true;
                }
            }
            return false;
        }

        public bool authenticate(string password) {
            uint8[] pw = password.data;
            if (revision >= 5) return authenticate_r6(pw);
            if (check_owner_legacy(pw)) {
                owner_access = true;
                return true;
            }
            return check_user_legacy(pw);
        }

        private uint8[] object_key(int num, int gen, CryptMethod method) {
            if (method == CryptMethod.AESV3) return file_key;
            var buf = new ByteArray();
            buf.append(file_key);
            buf.append({ (uint8) num, (uint8) (num >> 8), (uint8) (num >> 16), (uint8) gen, (uint8) (gen >> 8) });
            if (method == CryptMethod.AESV2) buf.append({ 0x73, 0x41, 0x6c, 0x54 });
            uint8[] hash = Crypto.digest(ChecksumType.MD5, buf.data);
            return hash[0 : int.min(16, file_key.length + 5)];
        }

        public uint8[] decrypt(uint8[] data, int num, int gen, bool is_string) {
            var method = is_string ? string_method : stream_method;
            if (method == CryptMethod.NONE) return data;
            uint8[] key = object_key(num, gen, method);
            if (method == CryptMethod.RC4) return Crypto.rc4(key, data);
            if (data.length < 16) return new uint8[0];
            var aes = new Aes(key);
            return aes.cbc_decrypt(data[0 : 16], data[16 : data.length]);
        }

        public uint8[] encrypt(uint8[] data, int num, int gen, bool is_string) {
            var method = is_string ? string_method : stream_method;
            if (method == CryptMethod.NONE) return data;
            uint8[] key = object_key(num, gen, method);
            if (method == CryptMethod.RC4) return Crypto.rc4(key, data);
            uint8[] iv = Crypto.random_bytes(16);
            var aes = new Aes(key);
            return Crypto.concat(iv, aes.cbc_encrypt(iv, data));
        }

        public static SecurityHandler create_aes256(string user_password, string owner_password, int permissions) {
            var h = new SecurityHandler();
            h.version = 5;
            h.revision = 6;
            h.key_length = 32;
            h.stream_method = CryptMethod.AESV3;
            h.string_method = CryptMethod.AESV3;
            h.p = Permissions.to_p(permissions);
            h.file_key = Crypto.random_bytes(32);
            uint8[] upw = user_password.data.length > 127 ? user_password.data[0 : 127] : user_password.data;
            string owner = owner_password != "" ? owner_password : user_password;
            uint8[] opw = owner.data.length > 127 ? owner.data[0 : 127] : owner.data;
            uint8[] uvs = Crypto.random_bytes(8), uks = Crypto.random_bytes(8);
            h.u = Crypto.concat(Crypto.concat(hash_r6(upw, uvs, {}, 6), uvs), uks);
            var aes_u = new Aes(hash_r6(upw, uks, {}, 6));
            h.ue = aes_u.cbc_encrypt(new uint8[16], h.file_key, false);
            uint8[] ovs = Crypto.random_bytes(8), oks = Crypto.random_bytes(8);
            h.o = Crypto.concat(Crypto.concat(hash_r6(opw, ovs, h.u[0 : 48], 6), ovs), oks);
            var aes_o = new Aes(hash_r6(opw, oks, h.u[0 : 48], 6));
            h.oe = aes_o.cbc_encrypt(new uint8[16], h.file_key, false);
            uint8[] pb = new uint8[16];
            uint32 pv = (uint32) h.p;
            pb[0] = (uint8) pv; pb[1] = (uint8) (pv >> 8); pb[2] = (uint8) (pv >> 16); pb[3] = (uint8) (pv >> 24);
            pb[4] = 0xff; pb[5] = 0xff; pb[6] = 0xff; pb[7] = 0xff;
            pb[8] = 'T';
            pb[9] = 'a'; pb[10] = 'd'; pb[11] = 'b';
            uint8[] rnd = Crypto.random_bytes(4);
            for (int i = 0; i < 4; i++) pb[12 + i] = rnd[i];
            var aes_p = new Aes(h.file_key);
            aes_p.encrypt_block(pb);
            h.perms = pb;
            h.owner_access = true;
            return h;
        }

        private static SecurityHandler open_pubsec(Obj encrypt) throws PdfError {
            var h = new SecurityHandler();
            h.public_key = true;
            h.version = encrypt.get("V") != null ? encrypt.get("V").as_int(0) : 0;
            h.revision = h.version >= 5 ? 6 : 4;
            h.key_length = encrypt.get("Length") != null ? encrypt.get("Length").as_int(128) / 8 : 16;
            if (encrypt.get("EncryptMetadata") != null) h.encrypt_metadata = encrypt.get("EncryptMetadata").as_bool(true);
            Obj? list = null;
            if (h.version >= 4) {
                h.stream_method = method_for(encrypt, "StmF");
                h.string_method = method_for(encrypt, "StrF");
                var cf = encrypt.get("CF");
                var sf = encrypt.get("StmF");
                if (cf != null && cf.is_dict() && sf != null && sf.is_name()) {
                    var filter = cf.get(sf.name);
                    if (filter != null && filter.is_dict()) {
                        list = filter.get("Recipients");
                        var len = filter.get("Length");
                        if (len != null) h.key_length = len.as_int(16) > 32 ? len.as_int(128) / 8 : len.as_int(16);
                        var em = filter.get("EncryptMetadata");
                        if (em != null) h.encrypt_metadata = em.as_bool(true);
                    }
                }
                if (h.stream_method == CryptMethod.AESV3) h.key_length = 32;
            } else {
                list = encrypt.get("Recipients");
                h.stream_method = CryptMethod.RC4;
                h.string_method = CryptMethod.RC4;
            }
            if (list != null && list.is_string()) h.recipients.add(new Bytes(list.bytes));
            else if (list != null && list.is_array()) foreach (var r in list.items) if (r.is_string()) h.recipients.add(new Bytes(r.bytes));
            if (h.recipients.size == 0) throw new PdfError.MALFORMED("the certificate security handler lists no recipients");
            if (pubsec_unlocker == null) throw new PdfError.PASSWORD("this document is encrypted for a certificate; open it with your certificate");
            uint8[] content;
            try {
                content = pubsec_unlocker(h.recipients);
            } catch (Error e) {
                throw new PdfError.PASSWORD("%s", e.message);
            }
            if (content.length < 20) throw new PdfError.PASSWORD("none of your certificates can open this document");
            h.derive_pubsec_key(content[0 : 20]);
            if (content.length >= 24) h.p = (int) ((uint32) content[20] << 24 | (uint32) content[21] << 16 | (uint32) content[22] << 8 | content[23]);
            h.owner_access = true;
            return h;
        }

        private void derive_pubsec_key(uint8[] seed) {
            var b = new ByteArray();
            b.append(seed);
            foreach (var r in recipients) b.append(r.get_data());
            if (!encrypt_metadata) b.append({ 0xff, 0xff, 0xff, 0xff });
            uint8[] digest = Crypto.digest(stream_method == CryptMethod.AESV3 ? ChecksumType.SHA256 : ChecksumType.SHA1, b.data);
            file_key = digest[0 : int.min(key_length, digest.length)];
        }

        public static SecurityHandler create_pubsec(uint8[] seed, Gee.List<Bytes> envelopes, int permissions) {
            var h = new SecurityHandler();
            h.public_key = true;
            h.version = 5;
            h.revision = 6;
            h.key_length = 32;
            h.stream_method = CryptMethod.AESV3;
            h.string_method = CryptMethod.AESV3;
            h.p = Permissions.to_p(permissions);
            h.recipients.add_all(envelopes);
            h.derive_pubsec_key(seed);
            h.owner_access = true;
            return h;
        }

        public Obj to_dict() {
            if (public_key) {
                var pd = Obj.dictionary();
                pd.set("Filter", Obj.name_obj("Adobe.PubSec"));
                pd.set("SubFilter", Obj.name_obj("adbe.pkcs7.s5"));
                pd.set("V", Obj.integer(version));
                pd.set("R", Obj.integer(revision));
                pd.set("Length", Obj.integer(key_length * 8));
                var cf = Obj.dictionary();
                var dcf = Obj.dictionary();
                dcf.set("Type", Obj.name_obj("CryptFilter"));
                dcf.set("CFM", Obj.name_obj(stream_method == CryptMethod.AESV3 ? "AESV3" : (stream_method == CryptMethod.AESV2 ? "AESV2" : "V2")));
                dcf.set("Length", Obj.integer(key_length * 8));
                dcf.set("AuthEvent", Obj.name_obj("DocOpen"));
                var rl = Obj.array();
                foreach (var r in recipients) rl.add(Obj.str(r.get_data(), true));
                dcf.set("Recipients", rl);
                if (!encrypt_metadata) dcf.set("EncryptMetadata", Obj.boolean(false));
                cf.set("DefaultCryptFilter", dcf);
                pd.set("CF", cf);
                pd.set("StmF", Obj.name_obj("DefaultCryptFilter"));
                pd.set("StrF", Obj.name_obj("DefaultCryptFilter"));
                pd.set("P", Obj.integer(p));
                return pd;
            }
            var d = Obj.dictionary();
            d.set("Filter", Obj.name_obj("Standard"));
            d.set("V", Obj.integer(version));
            d.set("R", Obj.integer(revision));
            d.set("Length", Obj.integer(key_length * 8));
            if (version >= 4) {
                var cf = Obj.dictionary();
                var std = Obj.dictionary();
                std.set("Type", Obj.name_obj("CryptFilter"));
                std.set("CFM", Obj.name_obj(stream_method == CryptMethod.AESV3 ? "AESV3" : (stream_method == CryptMethod.AESV2 ? "AESV2" : "V2")));
                std.set("AuthEvent", Obj.name_obj("DocOpen"));
                std.set("Length", Obj.integer(key_length));
                cf.set("StdCF", std);
                d.set("CF", cf);
                d.set("StmF", Obj.name_obj("StdCF"));
                d.set("StrF", Obj.name_obj("StdCF"));
                if (!encrypt_metadata) d.set("EncryptMetadata", Obj.boolean(false));
            }
            d.set("O", Obj.str(o, true));
            d.set("U", Obj.str(u, true));
            if (revision >= 5) {
                d.set("OE", Obj.str(oe, true));
                d.set("UE", Obj.str(ue, true));
                d.set("Perms", Obj.str(perms, true));
            }
            d.set("P", Obj.integer(p));
            return d;
        }

        public int permission_flags() {
            return p & Permissions.ALL;
        }
    }
}
