namespace Singularity {

    public class ShareContent : Object {
        public File[] files { get; set; default = {}; }
        public string[] uris { get; set; default = {}; }
        public string? text { get; set; default = null; }
        public string title { get; set; default = ""; }
        public Accounts.CloudLocation? location { get; set; default = null; }

        public ShareContent.for_files(File[] files) {
            Object();
            this.files = files;
        }

        public ShareContent.for_uris(string[] uris, string title = "") {
            Object(title: title);
            this.uris = uris;
        }

        public ShareContent.for_text(string text, string title = "") {
            Object(text: text, title: title);
        }

        public ShareContent.for_location(Accounts.CloudLocation location) {
            Object(location: location, title: location.name);
        }

        public bool has_files {
            get { return files.length > 0; }
        }

        public bool has_uris {
            get { return uris.length > 0; }
        }

        public bool has_text {
            get { return text != null && text != ""; }
        }

        public int count {
            get { return has_files ? files.length : (has_uris ? uris.length : (has_text || location != null ? 1 : 0)); }
        }

        public string? link_or_text {
            owned get {
                if (has_uris) return string.joinv("\n", uris);
                return text;
            }
        }

        public string[] content_types() {
            string[] types = {};
            foreach (var f in files) {
                string type = "application/octet-stream";
                try {
                    var info = f.query_info(FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE, null);
                    if (info.get_content_type() != null) type = info.get_content_type();
                } catch (Error e) {
                    bool uncertain;
                    type = ContentType.guess(f.get_basename(), null, out uncertain);
                }
                types += type;
            }
            return types;
        }

        public bool all_match(string[] mime_types) {
            if (mime_types.length == 0) return true;
            foreach (string type in content_types()) {
                bool ok = false;
                foreach (string wanted in mime_types) {
                    if (wanted == "*" || wanted == "*/*") ok = true;
                    else if (wanted.has_suffix("/*") && type.has_prefix(wanted.substring(0, wanted.length - 1))) ok = true;
                    else if (ContentType.is_a(type, wanted) || ContentType.is_mime_type(type, wanted)) ok = true;
                    if (ok) break;
                }
                if (!ok) return false;
            }
            return true;
        }

        public string summary_title {
            owned get {
                if (title != "") return title;
                if (files.length == 1) return files[0].get_basename() ?? files[0].get_uri();
                if (files.length > 1) return ngettext("%d File", "%d Files", files.length).printf(files.length);
                if (uris.length == 1) return uris[0];
                if (uris.length > 1) return ngettext("%d Link", "%d Links", uris.length).printf(uris.length);
                string first = (text ?? "").strip().split("\n")[0];
                return first.char_count() > 60 ? first.substring(0, first.index_of_nth_char(60)) + "…" : first;
            }
        }

        public string summary_subtitle {
            owned get {
                if (files.length == 1) {
                    try {
                        var info = files[0].query_info(FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE, null);
                        string kind = ContentType.get_description(info.get_content_type() ?? "application/octet-stream");
                        return "%s, %s".printf(kind, format_size(info.get_size()));
                    } catch (Error e) {
                        return "";
                    }
                }
                if (files.length > 1) {
                    int64 total = 0;
                    foreach (var f in files) {
                        try {
                            total += f.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE, null).get_size();
                        } catch (Error e) {
                        }
                    }
                    return format_size(total);
                }
                if (has_uris) return title != "" ? uris[0] : _("Link");
                return _("Text");
            }
        }

        public GLib.Icon icon {
            owned get {
                if (files.length == 1) {
                    try {
                        var info = files[0].query_info(FileAttribute.STANDARD_ICON, FileQueryInfoFlags.NONE, null);
                        if (info.get_icon() != null) return info.get_icon();
                    } catch (Error e) {
                    }
                    return new ThemedIcon("text-x-generic");
                }
                if (files.length > 1) return new ThemedIcon("folder-documents");
                if (has_uris) return new ThemedIcon("text-html");
                return new ThemedIcon("text-x-generic");
            }
        }
    }
}
