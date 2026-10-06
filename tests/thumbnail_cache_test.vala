using Singularity.FileSystem;

string work_dir;

bool has_elements(string[] names) {
    foreach (string name in names) {
        if (Gst.ElementFactory.find(name) == null) return false;
    }
    return true;
}

string make_video(string name, string encoder) {
    string path = Path.build_filename(work_dir, name);
    string muxer = name.has_suffix(".webm") ? "webmmux" : "mp4mux";
    try {
        var pipeline = Gst.parse_launch(
            "videotestsrc num-buffers=50 pattern=smpte ! video/x-raw,width=320,height=180,framerate=25/1 ! %s ! %s ! filesink location=\"%s\""
                .printf(encoder, muxer, path));
        pipeline.set_state(Gst.State.PLAYING);
        var message = pipeline.get_bus().timed_pop_filtered(30 * Gst.SECOND,
            Gst.MessageType.EOS | Gst.MessageType.ERROR);
        pipeline.set_state(Gst.State.NULL);
        assert(message != null && message.type == Gst.MessageType.EOS);
    } catch (Error e) {
        error("%s", e.message);
    }
    return path;
}

void test_names() {
    string uri = "file:///home/user/a%20b.webm";
    assert(ThumbnailCache.file_name(uri) == Checksum.compute_for_string(ChecksumType.MD5, uri) + ".png");
    assert(ThumbnailCache.path_for(uri, ThumbnailCache.Size.NORMAL)
        == Path.build_filename(Environment.get_user_cache_dir(), "thumbnails", "normal", ThumbnailCache.file_name(uri)));
    assert(ThumbnailCache.path_for(uri, ThumbnailCache.Size.LARGE).contains("/thumbnails/large/"));
    assert(ThumbnailCache.Size.for_pixels(48) == ThumbnailCache.Size.NORMAL);
    assert(ThumbnailCache.Size.for_pixels(200) == ThumbnailCache.Size.LARGE);
}

void test_video_frame() {
    if (!has_elements({ "videotestsrc", "vp8enc", "webmmux", "vp8dec", "matroskademux" })) {
        Test.skip("VP8 elements are not installed");
        return;
    }
    string path = make_video("clip.webm", "vp8enc");
    string uri = File.new_for_path(path).get_uri();
    var frame = VideoThumbnailer.grab_frame(uri);
    assert(frame != null);
    assert(frame.width == 320 && frame.height == 180);

    int64 mtime = 1700000000;
    var thumb = VideoThumbnailer.thumbnail(uri, mtime, 64, "video/webm");
    assert(thumb != null);
    string normal = ThumbnailCache.path_for(uri, ThumbnailCache.Size.NORMAL);
    string large = ThumbnailCache.path_for(uri, ThumbnailCache.Size.LARGE);
    assert(FileUtils.test(normal, FileTest.IS_REGULAR));
    assert(FileUtils.test(large, FileTest.IS_REGULAR));
    try {
        var stored = new Gdk.Pixbuf.from_file(normal);
        assert(stored.width == 128);
        assert(stored.get_option("tEXt::Thumb::URI") == uri);
        assert(stored.get_option("tEXt::Thumb::MTime") == "1700000000");
        assert(stored.get_option("tEXt::Thumb::Mimetype") == "video/webm");
        assert(new Gdk.Pixbuf.from_file(large).width == 256);
    } catch (Error e) {
        error("%s", e.message);
    }
    assert(ThumbnailCache.load(uri, mtime, 100) != null);
    assert(ThumbnailCache.load(uri, mtime, 100).width == 128);
    assert(ThumbnailCache.load(uri, mtime, 200).width == 256);
    assert(ThumbnailCache.load(uri, mtime + 1, 100) == null);
}

void test_undecodable() {
    string path = Path.build_filename(work_dir, "broken.mp4");
    try {
        FileUtils.set_contents(path, "not a video");
    } catch (Error e) {
        error("%s", e.message);
    }
    string uri = File.new_for_path(path).get_uri();
    assert(VideoThumbnailer.thumbnail(uri, 42, 128) == null);
    assert(ThumbnailCache.has_failed(VideoThumbnailer.FAILURE_APP, uri, 42));
    assert(!ThumbnailCache.has_failed(VideoThumbnailer.FAILURE_APP, uri, 43));
    assert(!FileUtils.test(ThumbnailCache.path_for(uri, ThumbnailCache.Size.NORMAL), FileTest.EXISTS));
}

void test_missing_decoder() {
    if (!has_elements({ "x264enc", "mp4mux" })) {
        Test.skip("no H.264 encoder to build the fixture");
        return;
    }
    string uri = File.new_for_path(make_video("clip.mp4", "x264enc")).get_uri();
    foreach (var feature in Gst.Registry.get().get_feature_list(typeof(Gst.ElementFactory))) {
        var factory = (Gst.ElementFactory) feature;
        if (!(factory.get_metadata(Gst.ELEMENT_METADATA_KLASS) ?? "").contains("Decoder")) continue;
        if (factory.can_sink_any_caps(Gst.Caps.from_string("video/x-h264"))) feature.set_rank(Gst.Rank.NONE);
    }
    assert(VideoThumbnailer.thumbnail(uri, 7, 128, "video/mp4") == null);
    assert(ThumbnailCache.has_failed(VideoThumbnailer.FAILURE_APP, uri, 7));
    assert(!FileUtils.test(ThumbnailCache.path_for(uri, ThumbnailCache.Size.NORMAL), FileTest.EXISTS));
}

int main(string[] args) {
    try {
        work_dir = DirUtils.make_tmp("thumbnail-test-XXXXXX");
    } catch (Error e) {
        error("%s", e.message);
    }
    Environment.set_variable("XDG_CACHE_HOME", Path.build_filename(work_dir, "cache"), true);
    Test.init(ref args);
    Gst.init(ref args);
    Test.add_func("/thumbnails/names", test_names);
    Test.add_func("/thumbnails/video-frame", test_video_frame);
    Test.add_func("/thumbnails/undecodable", test_undecodable);
    Test.add_func("/thumbnails/missing-decoder", test_missing_decoder);
    return Test.run();
}
