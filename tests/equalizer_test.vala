using Singularity;

void test_bands () {
    assert (EqualizerBands.COUNT == 10);
    assert (EqualizerBands.frequency (0) == 31);
    assert (EqualizerBands.frequency (9) == 16000);
    assert (EqualizerBands.frequency (42) == 16000);
    assert (EqualizerBands.label (5) == "1k");
    assert (EqualizerBands.label (2) == "125");
    assert (EqualizerBands.filter_label (0) == "bq_lowshelf");
    assert (EqualizerBands.filter_label (4) == "bq_peaking");
    assert (EqualizerBands.filter_label (9) == "bq_highshelf");
    assert (EqualizerBands.clamp_gain (20.0) == 12.0);
    assert (EqualizerBands.clamp_gain (-30.0) == -12.0);
    assert (EqualizerBands.clamp_gain (1.26) == 1.3);
    assert (EqualizerBands.clamp_gain (double.NAN) == 0.0);
    var norm = EqualizerBands.normalize ({ 1.0, 2.0 });
    assert (norm.length == 10 && norm[1] == 2.0 && norm[9] == 0.0);
}

void test_preamp () {
    assert (EqualizerBands.preamp ({ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }) == 0.0);
    assert (EqualizerBands.preamp ({ 6, 5, 4, 2, 0, 0, 0, 0, 0, 0 }) == -6.0);
    assert (EqualizerBands.preamp ({ -3, -2, 0, 0, 0, 0, 0, 0, 0, 0 }) == 0.0);
    assert (EqualizerBands.is_flat ({ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));
    assert (!EqualizerBands.is_flat ({ 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0 }));
}

void test_presets () {
    var presets = EqualizerBands.presets ();
    assert (presets.length == 5);
    foreach (var p in presets) {
        assert (p.gains.length == 10);
        assert (EqualizerBands.match_preset (p.gains) == p.id);
    }
    assert (EqualizerBands.match_preset ({ 1, 0, 0, 0, 0, 0, 0, 0, 0, 7 }) == "custom");
    assert (EqualizerBands.find_preset ("vocal") != null);
    assert (EqualizerBands.find_preset ("nope") == null);
}

void test_numbers () {
    Intl.setlocale (LocaleCategory.ALL, "it_IT.UTF-8");
    assert (EqualizerBands.number (1.5) == "1.5");
    assert (EqualizerBands.number (-3.0) == "-3.0");
    string params = EqualizerBands.control_params ({ 6, 0, 0, 0, 0, 0, 0, 0, 0, -2 });
    assert (params.has_prefix ("{ params = [ \"eq_preamp:Gain\" -6.0 \"eq_band_1:Gain\" 6.0 "));
    assert (params.contains ("\"eq_band_10:Gain\" -2.0 ] }"));
    Intl.setlocale (LocaleCategory.ALL, "C");
}

void test_conf () {
    string node = EqualizerBands.node_name ("alsa_output.pci-0000_00_1f.3.analog-stereo");
    assert (node.has_prefix (EqualizerBands.NODE_PREFIX));
    assert (node.length == EqualizerBands.NODE_PREFIX.length + 12);
    assert (node != EqualizerBands.node_name ("other"));
    string conf = EqualizerBands.filter_chain_conf (node, "Speakers \"A\"", "alsa_output.x", { 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    assert (conf.contains ("libpipewire-module-filter-chain"));
    assert (conf.contains ("node.description = \"Speakers \\\"A\\\"\""));
    assert (conf.contains ("name = eq_preamp label = bq_highshelf control = { \"Freq\" = 0.0 \"Q\" = 1.0 \"Gain\" = -3.0 }"));
    assert (conf.contains ("name = eq_band_1 label = bq_lowshelf control = { \"Freq\" = 31.0 \"Q\" = 0.71 \"Gain\" = 3.0 }"));
    assert (conf.contains ("name = eq_band_10 label = bq_highshelf"));
    assert (conf.contains ("{ output = \"eq_band_9:Out\" input = \"eq_band_10:In\" }"));
    assert (conf.contains ("target.object = \"alsa_output.x\""));
    assert (conf.contains ("media.class = Audio/Sink"));
    int nodes = conf.split ("type = builtin").length - 1;
    assert (nodes == 11);
    int links = conf.split ("output = \"eq_").length - 1;
    assert (links == 10);
    assert (EqualizerBands.quote ("a\nb\\") == "\"ab\\\\\"");
}

void test_parse_node_id () {
    string listing = "\tid 31, type PipeWire:Interface:Node/3\n \t\tfactory.id = \"11\"\n \t\tnode.name = \"alsa_output.x\"\n\tid 57, type PipeWire:Interface:Node/3\n \t\tnode.description = \"EQ\"\n \t\tnode.name = \"singularity-eq-abc\"\n";
    assert (PipeWireEqualizerBackend.parse_node_id (listing, "singularity-eq-abc") == "57");
    assert (PipeWireEqualizerBackend.parse_node_id (listing, "alsa_output.x") == "31");
    assert (PipeWireEqualizerBackend.parse_node_id (listing, "missing") == "");
}

void test_store () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "eq-store-%d.ini".printf ((int) Posix.getpid ()));
    FileUtils.unlink (path);
    var store = new EqualizerStore (path);
    var fresh = store.get_profile ("dev-a");
    assert (!fresh.enabled && fresh.preset == "flat" && EqualizerBands.is_flat (fresh.gains));
    var p = new EqualizerProfile ("dev-a");
    p.enabled = true;
    p.preset = "custom";
    p.gains = { 1.5, -2, 0, 0, 0, 0, 0, 0, 0, 12 };
    store.put_profile (p);
    try {
        store.save ();
    } catch (Error e) {
        assert_not_reached ();
    }
    var again = new EqualizerStore (path).get_profile ("dev-a");
    assert (again.enabled && again.preset == "custom");
    assert (again.gains[0] == 1.5 && again.gains[1] == -2.0 && again.gains[9] == 12.0);
    assert (!new EqualizerStore (path).get_profile ("dev-b").enabled);
    FileUtils.unlink (path);
}

void test_backends () {
    assert (EqualizerManager.backend_for ("none", "") == null);
    assert (EqualizerManager.backend_for ("command", "") == null);
    assert (EqualizerManager.backend_for ("command", "/bin/true").name == "command");
    assert (EqualizerManager.backend_for ("auto", "").name == "pipewire");
    var pw = new PipeWireEqualizerBackend ();
    assert (pw.owns_sink (EqualizerBands.node_name ("x")));
    assert (!pw.owns_sink ("alsa_output.x"));
    assert (pw.sink_for ("x") == EqualizerBands.node_name ("x"));
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/equalizer/bands", test_bands);
    Test.add_func ("/equalizer/preamp", test_preamp);
    Test.add_func ("/equalizer/presets", test_presets);
    Test.add_func ("/equalizer/numbers", test_numbers);
    Test.add_func ("/equalizer/conf", test_conf);
    Test.add_func ("/equalizer/node-id", test_parse_node_id);
    Test.add_func ("/equalizer/store", test_store);
    Test.add_func ("/equalizer/backends", test_backends);
    return Test.run ();
}
