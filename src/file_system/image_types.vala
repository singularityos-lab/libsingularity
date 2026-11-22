namespace Singularity.FileSystem {

    public class ImageTypes : Object {
        public const string IRIDE = "application/vnd.sinty.iride";

        public static bool can_preview(string? content_type) {
            if (content_type == null) return false;
            string mime = ContentType.get_mime_type(content_type) ?? content_type;
            return mime.has_prefix("image/") || mime == IRIDE;
        }
    }
}
