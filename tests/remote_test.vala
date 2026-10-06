using Singularity.Remote;

void main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/remote/clipboard-roundtrip", () => {
        try {
            var packed = VncSession.pack_clipboard_text ("héllo\nwörld ✓");
            string? back = VncSession.unpack_clipboard_text (packed);
            assert (back == "héllo\nwörld ✓");
        } catch (Error e) {
            assert_not_reached ();
        }
    });

    Test.add_func ("/remote/clipboard-crlf", () => {
        try {
            var raw = new ByteArray ();
            uint8[] text = "a\r\nb\0".data;
            raw.append ({ 0, 0, 0, (uint8) (text.length + 1) });
            raw.append (text);
            raw.append ({ 0 });
            var sink = new MemoryOutputStream.resizable ();
            var conv = new ConverterOutputStream (sink, new ZlibCompressor (ZlibCompressorFormat.ZLIB, -1));
            size_t written;
            conv.write_all (raw.data, out written);
            conv.close ();
            uint8[] packed = sink.steal_data ();
            packed.length = (int) sink.get_data_size ();
            assert (VncSession.unpack_clipboard_text (packed) == "a\nb");
        } catch (Error e) {
            assert_not_reached ();
        }
    });

    Test.add_func ("/remote/clipboard-damaged", () => {
        try {
            VncSession.unpack_clipboard_text ({ 1, 2, 3, 4 });
            assert_not_reached ();
        } catch (Error e) {
        }
    });

    Test.add_func ("/remote/needs-shift", () => {
        assert (RemoteDisplay.needs_shift ('A'));
        assert (RemoteDisplay.needs_shift ('_'));
        assert (RemoteDisplay.needs_shift ('|'));
        assert (RemoteDisplay.needs_shift ('>'));
        assert (!RemoteDisplay.needs_shift ('a'));
        assert (!RemoteDisplay.needs_shift ('-'));
        assert (!RemoteDisplay.needs_shift (Gdk.Key.Return));
    });

    Test.add_func ("/remote/des-vector", () => {
        var des = new Des ({ 0x13, 0x34, 0x57, 0x79, 0x9b, 0xbc, 0xdf, 0xf1 });
        var out_block = des.encrypt_block ({ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
        uint8[] expected = { 0x85, 0xe8, 0x13, 0x54, 0x0f, 0x0a, 0xb4, 0x05 };
        for (int i = 0; i < 8; i++) assert (out_block[i] == expected[i]);
    });

    Test.run ();
}
