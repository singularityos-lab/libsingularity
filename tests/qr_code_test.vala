using Singularity;

string fixtures;

class Reference {
    public QrEcLevel level;
    public int version;
    public int mask;
    public uint8[] data;
    public string[] rows = {};
}

uint8[] from_hex (string hex) {
    var out_bytes = new uint8[hex.length / 2];
    for (int i = 0; i < out_bytes.length; i++) {
        out_bytes[i] = (uint8) ((hex[2 * i].xdigit_value () << 4) | hex[2 * i + 1].xdigit_value ());
    }
    return out_bytes;
}

Gee.ArrayList<Reference> load_references () {
    var list = new Gee.ArrayList<Reference> ();
    string text;
    try {
        FileUtils.get_contents (Path.build_filename (fixtures, "reference.txt"), out text);
    } catch (Error e) {
        error ("reference.txt: %s", e.message);
    }
    Reference? cur = null;
    foreach (string line in text.split ("\n")) {
        if (line == "") {
            cur = null;
            continue;
        }
        if (cur == null) {
            string[] parts = line.split (" ");
            cur = new Reference ();
            cur.level = QrEcLevel.from_id (parts[0]);
            cur.version = int.parse (parts[1]);
            cur.mask = int.parse (parts[2]);
            cur.data = from_hex (parts[3]);
            list.add (cur);
        } else {
            cur.rows += line;
        }
    }
    return list;
}

bool matches (QrCode qr, Reference r) {
    if (qr.size != r.rows.length) return false;
    for (int y = 0; y < qr.size; y++) {
        for (int x = 0; x < qr.size; x++) {
            if (qr.get_module (x, y) != (r.rows[y][x] == '1')) return false;
        }
    }
    return true;
}

void main (string[] args) {
    Test.init (ref args);
    fixtures = args.length > 1 ? args[1] : "tests/fixtures/qr";

    Test.add_func ("/qr-code/reed-solomon", () => {
        uint8[] data = { 0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11 };
        uint8[] want = { 0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55 };
        var ecc = QrReedSolomon.remainder (data, QrReedSolomon.divisor (10));
        assert (ecc.length == want.length);
        for (int i = 0; i < want.length; i++) assert (ecc[i] == want[i]);
    });

    Test.add_func ("/qr-code/format-word", () => {
        assert (QrCode.format_word (QrEcLevel.MEDIUM, 0) == 0x5412);
        assert (QrCode.format_word (QrEcLevel.LOW, 0) == 0x77C4);
        assert (QrCode.format_word (QrEcLevel.HIGH, 7) == 0x083B);
    });

    Test.add_func ("/qr-code/alignment", () => {
        assert (QrCode.alignment_positions (1).length == 0);
        var v2 = QrCode.alignment_positions (2);
        assert (v2.length == 2 && v2[0] == 6 && v2[1] == 18);
        var v7 = QrCode.alignment_positions (7);
        assert (v7.length == 3 && v7[1] == 22 && v7[2] == 38);
        int[] v32 = { 6, 34, 60, 86, 112, 138 };
        var got32 = QrCode.alignment_positions (32);
        assert (got32.length == v32.length);
        for (int i = 0; i < v32.length; i++) assert (got32[i] == v32[i]);
        int[] v40 = { 6, 30, 58, 86, 114, 142, 170 };
        var got40 = QrCode.alignment_positions (40);
        for (int i = 0; i < v40.length; i++) assert (got40[i] == v40[i]);
    });

    Test.add_func ("/qr-code/capacity", () => {
        assert (QrCode.max_bytes (1, QrEcLevel.LOW) == 17);
        assert (QrCode.max_bytes (1, QrEcLevel.MEDIUM) == 14);
        assert (QrCode.max_bytes (1, QrEcLevel.HIGH) == 7);
        assert (QrCode.max_bytes (10, QrEcLevel.MEDIUM) == 213);
        assert (QrCode.max_bytes (40, QrEcLevel.LOW) == 2953);
        assert (QrCode.max_bytes (40, QrEcLevel.HIGH) == 1273);
    });

    Test.add_func ("/qr-code/version-selection", () => {
        try {
            foreach (var level in QrEcLevel.all ()) {
                for (int v = 1; v <= 40; v++) {
                    int n = QrCode.max_bytes (v, level);
                    var data = new uint8[n];
                    for (int i = 0; i < n; i++) data[i] = 'a';
                    assert (QrCode.encode_bytes (data, level).version == v);
                    if (v < 40) {
                        data += 'a';
                        assert (QrCode.encode_bytes (data, level).version == v + 1);
                    }
                }
            }
        } catch (QrEncodeError e) {
            error ("%s", e.message);
        }
    });

    Test.add_func ("/qr-code/too-long", () => {
        var data = new uint8[2954];
        try {
            QrCode.encode_bytes (data, QrEcLevel.LOW);
            error ("2954 bytes encoded");
        } catch (QrEncodeError e) {
            assert (e is QrEncodeError.TOO_LONG);
        }
        try {
            QrCode.encode_bytes (new uint8[1274], QrEcLevel.HIGH);
            error ("1274 bytes encoded at H");
        } catch (QrEncodeError e) {
            assert (e is QrEncodeError.TOO_LONG);
        }
    });

    Test.add_func ("/qr-code/reference-matrices", () => {
        var refs = load_references ();
        assert (refs.size >= 10);
        foreach (var r in refs) {
            try {
                var forced = QrCode.encode_bytes (r.data, r.level, 1, 40, r.mask);
                assert (forced.version == r.version);
                if (!matches (forced, r)) error ("matrix differs for version %d level %s mask %d", r.version, r.level.id (), r.mask);
            } catch (QrEncodeError e) {
                error ("%s", e.message);
            }
        }
    });

    Test.add_func ("/qr-code/mask-choice", () => {
        foreach (var r in load_references ()) {
            try {
                var auto = QrCode.encode_bytes (r.data, r.level);
                int best = int.MAX;
                int best_mask = -1;
                for (int m = 0; m < 8; m++) {
                    int p = QrCode.encode_bytes (r.data, r.level, 1, 40, m).penalty_score ();
                    if (p < best) {
                        best = p;
                        best_mask = m;
                    }
                }
                assert (auto.mask == best_mask);
                assert (auto.penalty_score () == best);
                if (auto.mask == r.mask) assert (matches (auto, r));
            } catch (QrEncodeError e) {
                error ("%s", e.message);
            }
        }
    });

    Test.add_func ("/qr-code/png", () => {
        try {
            var qr = QrCode.encode_text ("HELLO WORLD", QrEcLevel.LOW, 4);
            var png = qr.to_png (3);
            assert (png.length > 8 && png[1] == 'P' && png[2] == 'N' && png[3] == 'G');
            var surface = qr.to_surface (3);
            assert (surface.get_width () == (qr.size + QrCode.QUIET * 2) * 3);
        } catch (Error e) {
            error ("%s", e.message);
        }
    });

    Test.run ();
}
