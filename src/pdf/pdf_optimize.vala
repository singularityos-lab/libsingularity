namespace Singularity.Pdf {

    public class OptimizeOptions {
        public int color_dpi = 150;
        public int jpeg_quality = 75;
        public bool downsample = true;
        public bool deduplicate = true;
        public bool compress = true;
        public bool object_streams = true;
        public bool remove_metadata = false;
        public bool remove_thumbnails = true;
        public bool recompress_lzw = true;
    }

    public class OptimizeReport {
        public int64 before = 0;
        public int64 after = 0;
        public int images_resampled = 0;
        public int duplicates_merged = 0;
        public int streams_compressed = 0;
    }

    public class Optimizer {
        public static uint8[] run(Document doc, OptimizeOptions opts, OptimizeReport report) throws Error {
            report.before = doc.data.length;
            if (opts.downsample) report.images_resampled = downsample(doc, opts);
            if (opts.remove_thumbnails) {
                for (int p = 0; p < doc.page_count(); p++) doc.page(p).remove("Thumb");
            }
            if (opts.remove_metadata) Sanitizer.apply(doc, HiddenInfo.METADATA | HiddenInfo.PRIVATE_DATA);
            doc.load_all();
            if (opts.recompress_lzw || opts.compress) report.streams_compressed = recompress(doc, opts);
            if (opts.deduplicate) report.duplicates_merged = deduplicate(doc);
            var so = new SaveOptions();
            so.mode = opts.object_streams ? SaveMode.COMPACT : SaveMode.FULL;
            so.garbage_collect = true;
            so.compress_streams = opts.compress;
            so.deflate_level = 9;
            var bytes = doc.save(so);
            report.after = bytes.length;
            return bytes;
        }

        private static int recompress(Document doc, OptimizeOptions opts) {
            int n = 0;
            foreach (var e in doc.entries.values) {
                if (e.obj == null || !e.obj.is_stream() || e.deleted) continue;
                var f = doc.lookup(e.obj, "Filter");
                bool lzw = f.is_name("LZWDecode") || (f.is_array() && f.length == 1 && doc.resolve(f.at(0)).is_name("LZWDecode"));
                bool plain_or_ascii = f.is_none() || f.is_name("ASCIIHexDecode") || f.is_name("ASCII85Decode") || f.is_name("RunLengthDecode");
                if (!(lzw && opts.recompress_lzw) && !(plain_or_ascii && opts.compress)) continue;
                if (e.obj.bytes.length < 64 && f.is_none()) continue;
                try {
                    var data = doc.decode_stream(e.obj);
                    doc.set_stream_data(e.obj, data, true);
                    n++;
                } catch (Error err) {
                }
            }
            return n;
        }

        private static void replace_refs(Obj o, Gee.HashMap<int, int> map) {
            switch (o.kind) {
                case ObjKind.ARRAY:
                    for (int i = 0; i < o.items.size; i++) {
                        var v = o.items[i];
                        if (v.is_ref() && map.has_key(v.num)) o.items[i] = Obj.reference(map[v.num]);
                        else replace_refs(v, map);
                    }
                    break;
                case ObjKind.DICT:
                case ObjKind.STREAM:
                    foreach (var k in o.dict.keys) {
                        var v = o.dict.get(k);
                        if (v.is_ref() && map.has_key(v.num)) o.dict.set(k, Obj.reference(map[v.num]));
                        else replace_refs(v, map);
                    }
                    break;
                default:
                    break;
            }
        }

        public static int deduplicate(Document doc) {
            var seen = new Gee.HashMap<string, int>();
            var map = new Gee.HashMap<int, int>();
            var nums = new Gee.ArrayList<int>();
            nums.add_all(doc.entries.keys);
            nums.sort((a, b) => a - b);
            foreach (int n in nums) {
                var e = doc.entries[n];
                if (e.obj == null || e.deleted || !e.obj.is_stream()) continue;
                var type = e.obj.get("Type");
                if (type != null && (type.is_name("XRef") || type.is_name("ObjStm") || type.is_name("Metadata"))) continue;
                string key = e.obj.to_pdf_string() + Checksum.compute_for_data(ChecksumType.SHA256, e.obj.bytes);
                if (seen.has_key(key)) map[n] = seen[key];
                else seen[key] = n;
            }
            if (map.size == 0) return 0;
            foreach (var e in doc.entries.values) if (e.obj != null) replace_refs(e.obj, map);
            replace_refs(doc.trailer, map);
            foreach (int n in map.keys) doc.delete_object(n);
            doc.invalidate_pages();
            return map.size;
        }

        public static int downsample(Document doc, OptimizeOptions opts) {
            var max_dpi = new Gee.HashMap<int, double?>();
            for (int p = 0; p < doc.page_count(); p++) {
                foreach (var info in Images.list(doc, p)) {
                    if (info.xobject == null || !info.xobject.is_ref()) continue;
                    double dpi = double.min(info.dpi_x, info.dpi_y);
                    if (dpi <= 0) continue;
                    double current = max_dpi.has_key(info.xobject.num) ? max_dpi[info.xobject.num] : double.MAX;
                    max_dpi[info.xobject.num] = double.min(current, dpi);
                }
            }
            int count = 0;
            foreach (var e in max_dpi.entries) {
                double dpi = e.value;
                if (dpi < opts.color_dpi * 1.4) continue;
                var x = doc.resolve(Obj.reference(e.key));
                if (!x.is_stream()) continue;
                if (doc.lookup(x, "ImageMask").as_bool(false)) continue;
                int bpc = doc.lookup(x, "BitsPerComponent").as_int(8);
                if (bpc < 8) continue;
                var pb = Images.decode(doc, x);
                if (pb == null) continue;
                double scale = opts.color_dpi / dpi;
                int nw = int.max(1, (int) (pb.width * scale)), nh = int.max(1, (int) (pb.height * scale));
                var scaled = pb.scale_simple(nw, nh, Gdk.InterpType.HYPER);
                if (scaled == null) continue;
                try {
                    var fresh_ref = Images.pixbuf_xobject(doc, scaled, opts.jpeg_quality);
                    var fresh = doc.resolve(fresh_ref);
                    var smask = doc.lookup(x, "SMask");
                    if (smask.is_stream()) {
                        var mask_pb = Images.decode(doc, smask);
                        if (mask_pb != null) {
                            var mask_scaled = mask_pb.scale_simple(nw, nh, Gdk.InterpType.BILINEAR);
                            var gray = new uint8[nw * nh];
                            unowned uint8[] px = mask_scaled.get_pixels_with_length();
                            for (int y = 0; y < nh; y++) for (int xx = 0; xx < nw; xx++) gray[y * nw + xx] = px[y * mask_scaled.rowstride + xx * mask_scaled.n_channels];
                            var md = new Dict();
                            md.set("Type", Obj.name_obj("XObject"));
                            md.set("Subtype", Obj.name_obj("Image"));
                            md.set("Width", Obj.integer(nw));
                            md.set("Height", Obj.integer(nh));
                            md.set("BitsPerComponent", Obj.integer(8));
                            md.set("ColorSpace", Obj.name_obj("DeviceGray"));
                            fresh.set("SMask", doc.add_ref(doc.make_stream(gray, true, md)));
                        }
                    }
                    var interp = doc.lookup(x, "Interpolate");
                    if (!interp.is_none()) fresh.set("Interpolate", interp);
                    if (fresh.bytes.length >= x.bytes.length) {
                        doc.delete_object(fresh_ref.num);
                        continue;
                    }
                    doc.replace(e.key, fresh);
                    doc.delete_object(fresh_ref.num);
                    count++;
                } catch (Error err) {
                }
            }
            return count;
        }
    }
}
