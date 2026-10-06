using Singularity.TextRecognition;

string fixtures;

string read_fixture(string name) {
    string contents;
    try {
        FileUtils.get_contents(Path.build_filename(fixtures, name), out contents);
    } catch (Error e) {
        error("fixture %s: %s", name, e.message);
    }
    return contents;
}

void test_tsv_mapping() {
    var text = RecognizedText.from_tsv(read_fixture("notes.tsv"));
    assert(text.image_width == 900);
    assert(text.image_height == 420);
    assert(text.lines.size == 5);
    assert(text.lines[0].text == "Singularity Desktop");
    assert(text.lines[2].text == "Visit https://sinty.dev/docs today");
    assert(text.words[0].text == "Singularity");
    assert(text.words[0].x >= 38 && text.words[0].x <= 44);
    assert(text.words[0].y >= 45 && text.words[0].y <= 60);
    assert(text.words[0].width > 200);
    assert(text.text.has_prefix("Singularity Desktop\nMeeting notes for Tuesday\n"));
    assert(text.text.has_suffix("Call +39 06 1234 5678"));
}

void test_scaled_mapping() {
    var tsv = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n" +
        "1\t1\t0\t0\t0\t0\t0\t0\t400\t200\t-1\t\n" +
        "5\t1\t1\t1\t1\t1\t20\t40\t100\t30\t96.5\tHello\n" +
        "5\t1\t1\t1\t1\t2\t130\t40\t90\t30\t12.0\tnoise\n" +
        "5\t1\t1\t1\t1\t3\t230\t40\t90\t30\t91.0\tWorld\n";
    var text = RecognizedText.from_tsv(tsv, 2.0, 20);
    assert(text.image_width == 200);
    assert(text.words.size == 2);
    assert(text.words[0].x == 10);
    assert(text.words[0].height == 15);
    assert(text.lines[0].text == "Hello World");
}

void test_selection_and_hit() {
    var text = RecognizedText.from_tsv(read_fixture("notes.tsv"));
    var line = text.lines[1];
    var word = line.words[1];
    int hit = text.word_at(word.x + word.width / 2, word.y + word.height / 2);
    assert(hit == word.index);
    assert(text.word_at(880, 400) == -1);
    int near = text.nearest_word(word.x - 3, word.y + word.height / 2);
    assert(near == word.index || near == line.words[0].index);
    assert(text.text_between(line.words[0].index, line.words[line.words.size - 1].index) == "Meeting notes for Tuesday");
    assert(text.text_between(text.lines[0].words[1].index, line.words[0].index) == "Desktop\nMeeting");
}

void test_search() {
    var text = RecognizedText.from_tsv(read_fixture("notes.tsv"));
    var found = text.find("notes for");
    assert(found.size == 1);
    assert(text.text_between(found[0].first, found[0].last) == "notes for");
    assert(text.find("TUESDAY").size == 1);
    assert(text.find("missing").size == 0);
}

void test_data_detection() {
    var text = RecognizedText.from_tsv(read_fixture("notes.tsv"));
    var data = text.detect_data();
    bool link = false, email = false, phone = false;
    foreach (var item in data) {
        if (item.kind == DataKind.LINK) {
            assert(item.uri == "https://sinty.dev/docs");
            link = true;
        } else if (item.kind == DataKind.EMAIL) {
            assert(item.uri == "mailto:hello@example.com");
            email = true;
        } else if (item.kind == DataKind.PHONE) {
            assert(item.uri == "tel:+390612345678");
            assert(text.text_between(item.first_word, item.last_word) == "+39 06 1234 5678");
            phone = true;
        }
    }
    assert(link && email && phone);
    assert(data.size == 3);
}

void test_uri_for() {
    assert(RecognizedText.uri_for(DataKind.LINK, "www.example.org/a") == "https://www.example.org/a");
    assert(RecognizedText.uri_for(DataKind.PHONE, "(555) 123-4567") == "tel:5551234567");
}

void test_languages() {
    assert(Languages.code_for_locale("it_IT.UTF-8") == "ita");
    assert(Languages.code_for_locale("pt_BR") == "por");
    assert(Languages.code_for_locale("zh_TW") == "chi_tra");
    assert(Languages.code_for_locale("xx") == null);
    var auto = Languages.automatic({ "ita", "deu" });
    foreach (var code in auto) assert(code == "ita" || code == "deu");
    assert(auto.length >= 1);
    assert(Languages.display_name("ita") == "Italian");
}

void test_config_seam() {
    string dir = DirUtils.make_tmp("text-recognition-XXXXXX");
    string path = Path.build_filename(dir, "text-recognition.conf");
    FileUtils.set_contents(path, "[Text Recognition]\nEngine=command\nCommand=/bin/cat %f\nInstallHint=Install the ocr package\n");
    var config = new Config();
    config.merge(path);
    assert(config.engine == "command");
    assert(config.install_hint == "Install the ocr package");
    var engine = config.create_engine();
    assert(engine is CommandEngine);
    assert(engine.available);
    var none = new Config();
    none.engine = "none";
    assert(none.create_engine() == null);
    var recognizer = new Recognizer.with_engine(null);
    assert(!recognizer.available);
    assert(recognizer.install_hint != "");
    FileUtils.unlink(path);
    DirUtils.remove(dir);
}

void test_fake_engine() {
    var loop = new MainLoop();
    string tsv_path = Path.build_filename(fixtures, "notes.tsv");
    var engine = new CommandEngine("/bin/cat " + tsv_path + " %f");
    string output = "";
    string image;
    FileUtils.close(FileUtils.open_tmp("fake-ocr-XXXXXX.png", out image));
    engine.recognize_tsv.begin(image, { "eng" }, null, (obj, res) => {
        try {
            output = engine.recognize_tsv.end(res);
        } catch (Error e) {
            error("fake engine: %s", e.message);
        }
        loop.quit();
    });
    loop.run();
    FileUtils.unlink(image);
    var text = RecognizedText.from_tsv(output);
    assert(text.lines.size == 5);
}

void test_real_tesseract() {
    string? program = Environment.get_variable("SINGULARITY_TEST_TESSERACT") ?? Environment.find_program_in_path("tesseract");
    if (program == null) {
        Test.skip("Tesseract is not installed; real OCR NOT verified");
        return;
    }
    var engine = new TesseractEngine(program, Environment.get_variable("SINGULARITY_TEST_TESSDATA"));
    assert(engine.available);
    var recognizer = new Recognizer.with_engine(engine);
    var loop = new MainLoop();
    RecognizedText? result = null;
    recognizer.recognize_file.begin(File.new_for_path(Path.build_filename(fixtures, "notes.png")), null, (obj, res) => {
        try {
            result = recognizer.recognize_file.end(res);
        } catch (Error e) {
            error("tesseract: %s", e.message);
        }
        loop.quit();
    });
    loop.run();
    assert(result != null);
    assert(result.image_width == 900);
    string all = result.text;
    assert("Meeting notes for Tuesday" in all);
    assert("hello@example.com" in all);
    var first = result.words[0];
    assert(first.text == "Singularity");
    assert(first.x > 30 && first.x < 50);
    assert(result.detect_data().size == 3);
}

int main(string[] args) {
    Test.init(ref args);
    fixtures = args.length > 1 ? args[1] : "tests/fixtures/text-recognition";
    Test.add_func("/text-recognition/tsv-mapping", test_tsv_mapping);
    Test.add_func("/text-recognition/scaled-mapping", test_scaled_mapping);
    Test.add_func("/text-recognition/selection", test_selection_and_hit);
    Test.add_func("/text-recognition/search", test_search);
    Test.add_func("/text-recognition/data-detection", test_data_detection);
    Test.add_func("/text-recognition/uri", test_uri_for);
    Test.add_func("/text-recognition/languages", test_languages);
    Test.add_func("/text-recognition/config", test_config_seam);
    Test.add_func("/text-recognition/fake-engine", test_fake_engine);
    Test.add_func("/text-recognition/tesseract", test_real_tesseract);
    return Test.run();
}
