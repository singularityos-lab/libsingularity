namespace Singularity.Pdf {

    public class ImageInfo {
        public int page;
        public Item item;
        public string name;
        public Obj? xobject;
        public int pixel_width;
        public int pixel_height;
        public string filter = "";
        public double dpi_x;
        public double dpi_y;
    }

    public class Images {
        public static bool jpeg_info(uint8[] data, out int width, out int height, out int components, out bool adobe) {
            width = 0;
            height = 0;
            components = 0;
            adobe = false;
            if (data.length < 4 || data[0] != 0xff || data[1] != 0xd8) return false;
            int pos = 2;
            while (pos + 4 < data.length) {
                if (data[pos] != 0xff) {
                    pos++;
                    continue;
                }
                uint8 marker = data[pos + 1];
                if (marker == 0xd8 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
                    pos += 2;
                    continue;
                }
                int len = (data[pos + 2] << 8) | data[pos + 3];
                if (marker == 0xee && pos + 9 < data.length && data[pos + 4] == 'A' && data[pos + 5] == 'd' && data[pos + 6] == 'o') adobe = true;
                if ((marker >= 0xc0 && marker <= 0xc3) || (marker >= 0xc5 && marker <= 0xc7) || (marker >= 0xc9 && marker <= 0xcb) || (marker >= 0xcd && marker <= 0xcf)) {
                    if (pos + 9 >= data.length) return false;
                    height = (data[pos + 5] << 8) | data[pos + 6];
                    width = (data[pos + 7] << 8) | data[pos + 8];
                    components = data[pos + 9];
                    return width > 0 && height > 0;
                }
                pos += 2 + len;
            }
            return false;
        }

        public static Obj jpeg_xobject(Document doc, uint8[] data) throws Error {
            int w, h, comps;
            bool adobe;
            if (!jpeg_info(data, out w, out h, out comps, out adobe)) throw new PdfError.MALFORMED("the JPEG image could not be read");
            var d = new Dict();
            d.set("Type", Obj.name_obj("XObject"));
            d.set("Subtype", Obj.name_obj("Image"));
            d.set("Width", Obj.integer(w));
            d.set("Height", Obj.integer(h));
            d.set("BitsPerComponent", Obj.integer(8));
            d.set("ColorSpace", Obj.name_obj(comps == 1 ? "DeviceGray" : (comps == 4 ? "DeviceCMYK" : "DeviceRGB")));
            if (comps == 4 && adobe) d.set("Decode", Obj.numbers({ 1, 0, 1, 0, 1, 0, 1, 0 }));
            d.set("Filter", Obj.name_obj("DCTDecode"));
            var s = Obj.stream(d, data);
            s.set("Length", Obj.integer(data.length));
            return doc.add_ref(s);
        }

        public static Obj pixbuf_xobject(Document doc, Gdk.Pixbuf pixbuf, int jpeg_quality = -1) throws Error {
            int w = pixbuf.width, h = pixbuf.height;
            bool alpha = pixbuf.has_alpha;
            bool has_transparency = false;
            unowned uint8[] px = pixbuf.get_pixels_with_length();
            int stride = pixbuf.rowstride;
            int n = pixbuf.n_channels;
            var rgb = new uint8[w * h * 3];
            var mask = alpha ? new uint8[w * h] : null;
            bool gray = true;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int o = y * stride + x * n;
                    int t = (y * w + x) * 3;
                    rgb[t] = px[o];
                    rgb[t + 1] = px[o + 1];
                    rgb[t + 2] = px[o + 2];
                    if (px[o] != px[o + 1] || px[o] != px[o + 2]) gray = false;
                    if (alpha) {
                        mask[y * w + x] = px[o + 3];
                        if (px[o + 3] != 255) has_transparency = true;
                    }
                }
            }
            var d = new Dict();
            d.set("Type", Obj.name_obj("XObject"));
            d.set("Subtype", Obj.name_obj("Image"));
            d.set("Width", Obj.integer(w));
            d.set("Height", Obj.integer(h));
            d.set("BitsPerComponent", Obj.integer(8));
            Obj s;
            if (jpeg_quality > 0) {
                var plain = pixbuf;
                if (alpha) plain = new Gdk.Pixbuf.from_data(rgb, Gdk.Colorspace.RGB, false, 8, w, h, w * 3);
                uint8[] jpeg;
                plain.save_to_buffer(out jpeg, "jpeg", "quality", jpeg_quality.to_string());
                d.set("ColorSpace", Obj.name_obj("DeviceRGB"));
                d.set("Filter", Obj.name_obj("DCTDecode"));
                s = Obj.stream(d, jpeg);
                s.set("Length", Obj.integer(jpeg.length));
            } else if (gray) {
                var g = new uint8[w * h];
                for (int i = 0; i < w * h; i++) g[i] = rgb[i * 3];
                d.set("ColorSpace", Obj.name_obj("DeviceGray"));
                s = doc.make_stream(g, true, d);
            } else {
                d.set("ColorSpace", Obj.name_obj("DeviceRGB"));
                s = doc.make_stream(rgb, true, d);
            }
            if (alpha && has_transparency) {
                var md = new Dict();
                md.set("Type", Obj.name_obj("XObject"));
                md.set("Subtype", Obj.name_obj("Image"));
                md.set("Width", Obj.integer(w));
                md.set("Height", Obj.integer(h));
                md.set("BitsPerComponent", Obj.integer(8));
                md.set("ColorSpace", Obj.name_obj("DeviceGray"));
                s.set("SMask", doc.add_ref(doc.make_stream(mask, true, md)));
            }
            return doc.add_ref(s);
        }

        public static Obj from_file(Document doc, string path, out int width, out int height) throws Error {
            uint8[] data;
            FileUtils.get_data(path, out data);
            int comps;
            bool adobe;
            if (jpeg_info(data, out width, out height, out comps, out adobe)) return jpeg_xobject(doc, data);
            var pixbuf = new Gdk.Pixbuf.from_file(path);
            var oriented = pixbuf.apply_embedded_orientation() ?? pixbuf;
            width = oriented.width;
            height = oriented.height;
            return pixbuf_xobject(doc, oriented);
        }

        private static string filter_name(Document doc, Obj x) {
            var f = doc.lookup(x, "Filter");
            if (f.is_name()) return f.name;
            if (f.is_array() && f.length > 0) return doc.resolve(f.at(f.length - 1)).name ?? "";
            return "";
        }

        public static Gdk.Pixbuf? decode(Document doc, Obj xobject) {
            var x = doc.resolve(xobject);
            if (!x.is_stream()) return null;
            int w = doc.lookup(x, "Width").as_int(0), h = doc.lookup(x, "Height").as_int(0);
            if (w <= 0 || h <= 0 || (int64) w * h > 80000000) return null;
            string filter = filter_name(doc, x);
            try {
                if (filter == "DCTDecode" || filter == "DCT") {
                    uint8[] raw = doc.decode_stream(x);
                    var loader = new Gdk.PixbufLoader.with_type("jpeg");
                    loader.write(raw);
                    loader.close();
                    var pb = loader.get_pixbuf();
                    var cs = doc.lookup(x, "ColorSpace");
                    if (pb != null && cs.is_name("DeviceCMYK")) return pb;
                    return pb;
                }
                if (Filters.is_image_codec(filter)) return null;
                uint8[] data = doc.decode_stream(x);
                int bpc = doc.lookup(x, "BitsPerComponent").as_int(8);
                var cs = doc.lookup(x, "ColorSpace");
                bool mask = doc.lookup(x, "ImageMask").as_bool(false);
                int comps = 1;
                Obj? palette = null;
                int palette_comps = 3;
                string base_name = "DeviceGray";
                if (mask) {
                    comps = 1;
                    bpc = 1;
                } else if (cs.is_name()) {
                    base_name = cs.name;
                    comps = cs.name == "DeviceRGB" || cs.name == "CalRGB" ? 3 : (cs.name == "DeviceCMYK" ? 4 : 1);
                } else if (cs.is_array() && cs.length > 0) {
                    string kind = doc.resolve(cs.at(0)).name ?? "";
                    if (kind == "ICCBased") {
                        comps = doc.lookup(doc.resolve(cs.at(1)), "N").as_int(3);
                        base_name = comps == 4 ? "DeviceCMYK" : (comps == 3 ? "DeviceRGB" : "DeviceGray");
                    } else if (kind == "Indexed" && cs.length >= 4) {
                        comps = 1;
                        var basecs = doc.resolve(cs.at(1));
                        if (basecs.is_name()) palette_comps = basecs.name == "DeviceCMYK" ? 4 : (basecs.name == "DeviceGray" ? 1 : 3);
                        else if (basecs.is_array()) palette_comps = doc.lookup(doc.resolve(basecs.at(1)), "N").as_int(3);
                        var lookup = doc.resolve(cs.at(3));
                        palette = lookup.is_stream() ? Obj.str(doc.stream_data(lookup)) : lookup;
                        base_name = "Indexed";
                    } else if (kind == "CalRGB" || kind == "Lab") {
                        comps = 3;
                        base_name = "DeviceRGB";
                    } else if (kind == "CalGray") {
                        comps = 1;
                    } else {
                        return null;
                    }
                }
                int row_bits = w * comps * bpc;
                int stride = (row_bits + 7) / 8;
                if (data.length < stride * h) return null;
                var pb = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, w, h);
                unowned uint8[] out_px = pb.get_pixels_with_length();
                int ostride = pb.rowstride;
                int maxv = (1 << bpc) - 1;
                var decode_arr = doc.lookup(x, "Decode");
                bool invert = decode_arr.is_array() && decode_arr.length >= 2 && decode_arr.at(0).as_number() > decode_arr.at(1).as_number();
                if (mask) invert = !invert;
                for (int y = 0; y < h; y++) {
                    for (int xx = 0; xx < w; xx++) {
                        int[] c = new int[4];
                        for (int k = 0; k < comps; k++) {
                            int bit = (xx * comps + k) * bpc;
                            int v;
                            if (bpc == 8) v = data[y * stride + xx * comps + k];
                            else if (bpc == 16) v = data[y * stride + (xx * comps + k) * 2];
                            else v = (data[y * stride + bit / 8] >> (8 - bpc - bit % 8)) & maxv;
                            c[k] = v;
                        }
                        uint8 r, g, b;
                        if (base_name == "Indexed" && palette != null) {
                            int idx = c[0] * palette_comps;
                            uint8[] pal = palette.bytes;
                            if (idx + palette_comps - 1 < pal.length) {
                                if (palette_comps == 1) {
                                    r = g = b = pal[idx];
                                } else if (palette_comps == 4) {
                                    r = (uint8) (255 - int.min(255, pal[idx] + pal[idx + 3]));
                                    g = (uint8) (255 - int.min(255, pal[idx + 1] + pal[idx + 3]));
                                    b = (uint8) (255 - int.min(255, pal[idx + 2] + pal[idx + 3]));
                                } else {
                                    r = pal[idx];
                                    g = pal[idx + 1];
                                    b = pal[idx + 2];
                                }
                            } else {
                                r = g = b = 0;
                            }
                        } else {
                            int scale_max = bpc == 16 ? 255 : maxv;
                            double[] f = new double[4];
                            for (int k = 0; k < comps; k++) {
                                f[k] = c[k] / (double) scale_max;
                                if (invert) f[k] = 1 - f[k];
                            }
                            if (comps == 3) {
                                r = (uint8) (f[0] * 255);
                                g = (uint8) (f[1] * 255);
                                b = (uint8) (f[2] * 255);
                            } else if (comps == 4) {
                                r = (uint8) ((1 - f[0]) * (1 - f[3]) * 255);
                                g = (uint8) ((1 - f[1]) * (1 - f[3]) * 255);
                                b = (uint8) ((1 - f[2]) * (1 - f[3]) * 255);
                            } else {
                                r = g = b = (uint8) (f[0] * 255);
                            }
                        }
                        int o = y * ostride + xx * 3;
                        out_px[o] = r;
                        out_px[o + 1] = g;
                        out_px[o + 2] = b;
                    }
                }
                return pb;
            } catch (Error e) {
                return null;
            }
        }

        public static Gee.ArrayList<ImageInfo> list(Document doc, int page) {
            var result = new Gee.ArrayList<ImageInfo>();
            var it = new Interpreter(doc);
            it.run_page(page);
            foreach (var item in it.items) {
                if (item.kind != ItemKind.IMAGE) continue;
                var info = new ImageInfo();
                info.page = page;
                info.item = item;
                info.name = item.xobject;
                if (item.xobject != "") {
                    var res = item.form != null ? item.form.resources : it.resources;
                    var xo = doc.lookup(res, "XObject");
                    info.xobject = xo.is_dict() ? xo.get(item.xobject) : null;
                    var x = doc.resolve(info.xobject);
                    info.pixel_width = doc.lookup(x, "Width").as_int(0);
                    info.pixel_height = doc.lookup(x, "Height").as_int(0);
                    info.filter = filter_name(doc, x);
                } else if (item.op_index < it.ops_for(item).size) {
                    var op = it.ops_for(item)[item.op_index];
                    if (op.args.size > 0) {
                        var d = op.args[0];
                        var wv = d.get("W") ?? d.get("Width");
                        var hv = d.get("H") ?? d.get("Height");
                        info.pixel_width = wv != null ? wv.as_int() : 0;
                        info.pixel_height = hv != null ? hv.as_int() : 0;
                    }
                }
                double wpt = item.ctm.scale_x(), hpt = item.ctm.scale_y();
                info.dpi_x = wpt > 0 ? info.pixel_width / (wpt / 72) : 0;
                info.dpi_y = hpt > 0 ? info.pixel_height / (hpt / 72) : 0;
                result.add(info);
            }
            return result;
        }

        public static uint8[] original(Document doc, ImageInfo info, out string extension) throws Error {
            extension = "png";
            var x = doc.resolve(info.xobject);
            if (!x.is_stream()) throw new PdfError.UNSUPPORTED("inline images cannot be extracted");
            string filter = filter_name(doc, x);
            if (filter == "DCTDecode" || filter == "DCT") {
                extension = "jpg";
                return doc.decode_stream(x);
            }
            if (filter == "JPXDecode") {
                extension = "jp2";
                return doc.decode_stream(x);
            }
            var pb = decode(doc, x);
            if (pb == null) throw new PdfError.UNSUPPORTED("this image format cannot be decoded");
            var smask = doc.lookup(x, "SMask");
            if (smask.is_stream()) {
                var mask_pb = decode(doc, smask);
                if (mask_pb != null && mask_pb.width == pb.width && mask_pb.height == pb.height) {
                    var with_alpha = pb.add_alpha(false, 0, 0, 0);
                    unowned uint8[] a = with_alpha.get_pixels_with_length();
                    unowned uint8[] m = mask_pb.get_pixels_with_length();
                    for (int y = 0; y < pb.height; y++) {
                        for (int xx = 0; xx < pb.width; xx++) a[y * with_alpha.rowstride + xx * 4 + 3] = m[y * mask_pb.rowstride + xx * 3];
                    }
                    pb = with_alpha;
                }
            }
            uint8[] png;
            pb.save_to_buffer(out png, "png");
            return png;
        }
    }
}
