[CCode (cheader_filename = "pdf_native.h")]
namespace Singularity.Pdf.Native {
    [Compact]
    [CCode (cname = "SingularityPdfFontFile", free_function = "singularity_pdf_font_file_free")]
    public class FontFile {
        [CCode (cname = "singularity_pdf_font_file_open")]
        public static FontFile? open (string path, int index);
        [CCode (cname = "singularity_pdf_font_file_open_data")]
        public static FontFile? open_data ([CCode (array_length_type = "gsize")] uint8[] data, int index);
        [CCode (cname = "singularity_pdf_font_file_glyph")]
        public uint glyph (unichar c);
        [CCode (cname = "singularity_pdf_font_file_advance")]
        public int advance (uint glyph);
        [CCode (cname = "singularity_pdf_font_file_upem")]
        public int upem ();
        [CCode (cname = "singularity_pdf_font_file_glyph_count")]
        public int glyph_count ();
        [CCode (cname = "singularity_pdf_font_file_metrics")]
        public void metrics (out int ascent, out int descent, out int cap_height, out int x_min, out int y_min, out int x_max, out int y_max);
        [CCode (cname = "singularity_pdf_font_file_postscript_name")]
        public string postscript_name ();
        [CCode (cname = "singularity_pdf_font_file_is_cff")]
        public bool is_cff ();
        [CCode (cname = "singularity_pdf_font_file_data")]
        public GLib.Bytes data ();
        [CCode (cname = "singularity_pdf_font_file_subset")]
        public GLib.Bytes? subset ([CCode (array_length_type = "int")] uint[] glyphs);
    }

    [CCode (cname = "singularity_pdf_font_match")]
    public string? font_match (string pattern, out int index);
    [CCode (cname = "singularity_pdf_font_family")]
    public string? font_family (string path);

    [CCode (cname = "singularity_pdf_srgb_profile")]
    public GLib.Bytes? srgb_profile ();
    [CCode (cname = "singularity_pdf_profile_channels")]
    public int profile_channels ([CCode (array_length_type = "gsize")] uint8[] data);
    [CCode (cname = "singularity_pdf_profile_description")]
    public string? profile_description ([CCode (array_length_type = "gsize")] uint8[] data);
    [CCode (cname = "singularity_pdf_rgb_to_cmyk")]
    public bool rgb_to_cmyk ([CCode (array_length_type = "gsize")] uint8[]? profile, [CCode (array_length = false)] uint8[] rgb, [CCode (array_length = false)] uint8[] cmyk, int pixels);
    [CCode (cname = "singularity_pdf_font_find_family")]
    public string? font_find_family (string compact);
}
