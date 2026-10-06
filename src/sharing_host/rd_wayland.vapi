[CCode (cheader_filename = "rd_wayland.h")]
namespace Rd {
    [CCode (has_target = true, instance_pos = 0, cname = "RdFrameFunc")]
    public delegate void FrameFunc ([CCode (array_length = false)] uint8[] data, int width, int height, int stride,
                                    [CCode (array_length_type = "gint")] int[] damage);
    [CCode (has_target = true, instance_pos = 0, cname = "RdStoppedFunc")]
    public delegate void StoppedFunc ();
    [CCode (has_target = true, instance_pos = 0, cname = "RdOutputsFunc")]
    public delegate void OutputsFunc ();
    [CCode (has_target = true, instance_pos = 0, cname = "RdClipboardFunc")]
    public delegate void ClipboardFunc ([CCode (array_length = false, array_null_terminated = true)] string[] mime_types, bool own);
    [CCode (has_target = true, instance_pos = 0, cname = "RdSendFunc")]
    public delegate void SendFunc (string mime_type, int fd);

    [Compact]
    [CCode (cname = "RdDisplay", free_function = "rd_display_free", lower_case_cprefix = "rd_display_")]
    public class Display {
        [CCode (cname = "rd_display_new")]
        public Display () throws GLib.Error;
        public bool can_capture ();
        public bool can_inject ();
        public bool can_clipboard ();
        [CCode (array_length = false, array_null_terminated = true)]
        public string[] get_outputs ();
        public bool get_output_info (string name, out string description, out int x, out int y, out int width,
                                     out int height, out double scale);
        public void watch_outputs (OutputsFunc func);
        public void pointer_motion_output (string? output, double x, double y);
        public void pointer_motion (double dx, double dy);
        public void pointer_button (uint32 button, bool pressed);
        public void pointer_axis (uint32 axis, double value);
        public void pointer_axis_discrete (uint32 axis, int steps);
        public bool keysym (uint32 keysym, bool pressed);
        public void keycode (uint32 keycode, bool pressed);
        public void release_all ();
        public string get_keymap_layouts ();
        public void watch_clipboard (ClipboardFunc func);
        public void offer_clipboard ([CCode (array_length = false, array_null_terminated = true)] string[]? mime_types, SendFunc? func);
        public void set_clipboard_text (string text);
        public bool receive_clipboard (string mime_type, int fd);
        public string? text_mime_type ();
    }

    [Compact]
    [CCode (cname = "RdScreen", free_function = "rd_screen_free", lower_case_cprefix = "rd_screen_")]
    public class Screen {
        [CCode (cname = "rd_screen_new")]
        public static Screen? create (Display display, string? output, bool paint_cursor, FrameFunc frame_func,
                                      StoppedFunc stopped_func);
        public int get_width ();
        public int get_height ();
        public void pointer_motion (double x, double y);
    }

    [Compact]
    [CCode (cname = "RdEncoder", free_function = "rd_encoder_free", lower_case_cprefix = "rd_encoder_",
            cheader_filename = "rd_encode.h")]
    public class Encoder {
        [CCode (cname = "rd_encoder_new")]
        public Encoder ();
        public void set_format (int bits_per_pixel, int depth, bool big_endian, uint16 red_max, uint16 green_max,
                                uint16 blue_max, uint8 red_shift, uint8 green_shift, uint8 blue_shift);
        public void set_encodings (int preferred, bool copy_rect);
        public void invalidate ();
        public GLib.Bytes? encode ([CCode (array_length = false)] uint8[] framebuffer, int width, int height, int stride,
                                   [CCode (array_length_type = "gint")] int[] rects);
        public uint get_copy_count ();
    }

    [CCode (cname = "RD_ENCODING_RAW", cheader_filename = "rd_encode.h")]
    public const int ENCODING_RAW;
    [CCode (cname = "RD_ENCODING_COPYRECT", cheader_filename = "rd_encode.h")]
    public const int ENCODING_COPYRECT;
    [CCode (cname = "RD_ENCODING_ZRLE", cheader_filename = "rd_encode.h")]
    public const int ENCODING_ZRLE;

    [CCode (cname = "rd_convert_pixels", cheader_filename = "rd_encode.h")]
    public void convert_pixels ([CCode (array_length = false)] uint8[] src, int src_stride, int x, int y, int width,
                                int height, [CCode (array_length = false)] uint8[] dst, int bits_per_pixel,
                                bool big_endian, uint16 red_max, uint16 green_max, uint16 blue_max, uint8 red_shift,
                                uint8 green_shift, uint8 blue_shift);

    [CCode (cname = "rd_keymap_type_text", cheader_filename = "rd_keymap.h")]
    public string keymap_type_text (string keymap, string text);

    [CCode (cname = "rd_tls_generate", cheader_filename = "rd_tls.h")]
    public bool tls_generate (string cert_path, string key_path, string common_name) throws GLib.Error;
}
