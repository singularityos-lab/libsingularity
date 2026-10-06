namespace Singularity.Pdf.Filters {

    public uint8[] inflate(uint8[] input) throws Error {
        try {
            return run_inflate(input, ZlibCompressorFormat.ZLIB);
        } catch (Error e) {
            return run_inflate(input, ZlibCompressorFormat.RAW);
        }
    }

    private uint8[] run_inflate(uint8[] input, ZlibCompressorFormat format) throws Error {
        var conv = new ZlibDecompressor(format);
        var output = new ByteArray();
        uint8[] buf = new uint8[65536];
        size_t in_pos = 0;
        while (true) {
            size_t read, written;
            ConverterResult r;
            try {
                r = conv.convert(input[in_pos : input.length], buf, ConverterFlags.INPUT_AT_END, out read, out written);
            } catch (IOError.PARTIAL_INPUT e) {
                break;
            } catch (Error e) {
                if (output.len > 0) break;
                throw e;
            }
            in_pos += read;
            if (written > 0) output.append(buf[0 : written]);
            if (r == ConverterResult.FINISHED) break;
            if (read == 0 && written == 0) break;
        }
        return output.steal();
    }

    public uint8[] deflate(uint8[] input, int level = 6) throws Error {
        var conv = new ZlibCompressor(ZlibCompressorFormat.ZLIB, level);
        var output = new ByteArray();
        uint8[] buf = new uint8[65536];
        size_t in_pos = 0;
        while (true) {
            size_t read, written;
            var r = conv.convert(input[in_pos : input.length], buf, ConverterFlags.INPUT_AT_END, out read, out written);
            in_pos += read;
            if (written > 0) output.append(buf[0 : written]);
            if (r == ConverterResult.FINISHED) break;
        }
        return output.steal();
    }

    public uint8[] unpredict(uint8[] data, Obj? parms) {
        if (parms == null || !parms.is_dict()) return data;
        int predictor = parms.get("Predictor") != null ? parms.get("Predictor").as_int(1) : 1;
        if (predictor < 2) return data;
        int colors = parms.get("Colors") != null ? parms.get("Colors").as_int(1) : 1;
        int bpc = parms.get("BitsPerComponent") != null ? parms.get("BitsPerComponent").as_int(8) : 8;
        int columns = parms.get("Columns") != null ? parms.get("Columns").as_int(1) : 1;
        int bpp = int.max(1, (colors * bpc + 7) / 8);
        int row = (colors * bpc * columns + 7) / 8;
        if (row <= 0) return data;
        var output = new ByteArray();
        if (predictor == 2) {
            if (bpc != 8) return data;
            for (int start = 0; start + row <= data.length; start += row) {
                var line = data[start : start + row];
                for (int i = bpp; i < row; i++) line[i] = (uint8) (line[i] + line[i - bpp]);
                output.append(line);
            }
            return output.steal();
        }
        uint8[] prev = new uint8[row];
        int pos = 0;
        while (pos < data.length) {
            int type = data[pos++];
            int len = int.min(row, data.length - pos);
            uint8[] line = new uint8[row];
            for (int i = 0; i < len; i++) line[i] = data[pos + i];
            pos += len;
            for (int i = 0; i < row; i++) {
                int left = i >= bpp ? line[i - bpp] : 0;
                int up = prev[i];
                int upleft = i >= bpp ? prev[i - bpp] : 0;
                switch (type) {
                    case 1: line[i] = (uint8) (line[i] + left); break;
                    case 2: line[i] = (uint8) (line[i] + up); break;
                    case 3: line[i] = (uint8) (line[i] + (left + up) / 2); break;
                    case 4:
                        int p = left + up - upleft;
                        int pa = (p - left).abs(), pb = (p - up).abs(), pc = (p - upleft).abs();
                        int pred = pa <= pb && pa <= pc ? left : (pb <= pc ? up : upleft);
                        line[i] = (uint8) (line[i] + pred);
                        break;
                    default: break;
                }
            }
            output.append(line);
            prev = line;
        }
        return output.steal();
    }

    public uint8[] ascii_hex(uint8[] data) {
        var b = new ByteArray();
        int hi = -1;
        foreach (uint8 c in data) {
            if (c == '>') break;
            int v = Lexer.hexval(c);
            if (v < 0) continue;
            if (hi < 0) {
                hi = v;
            } else {
                b.append({ (uint8) (hi * 16 + v) });
                hi = -1;
            }
        }
        if (hi >= 0) b.append({ (uint8) (hi * 16) });
        return b.steal();
    }

    public uint8[] ascii85(uint8[] data) {
        var b = new ByteArray();
        uint32 acc = 0;
        int count = 0;
        int i = 0;
        if (data.length >= 2 && data[0] == '<' && data[1] == '~') i = 2;
        for (; i < data.length; i++) {
            uint8 c = data[i];
            if (c == '~') break;
            if (Lexer.is_space(c)) continue;
            if (c == 'z' && count == 0) {
                b.append({ 0, 0, 0, 0 });
                continue;
            }
            if (c < '!' || c > 'u') continue;
            acc = acc * 85 + (c - '!');
            count++;
            if (count == 5) {
                b.append({ (uint8) (acc >> 24), (uint8) (acc >> 16), (uint8) (acc >> 8), (uint8) acc });
                acc = 0;
                count = 0;
            }
        }
        if (count > 1) {
            for (int k = count; k < 5; k++) acc = acc * 85 + 84;
            uint8[] tail = { (uint8) (acc >> 24), (uint8) (acc >> 16), (uint8) (acc >> 8), (uint8) acc };
            b.append(tail[0 : count - 1]);
        }
        return b.steal();
    }

    public uint8[] run_length(uint8[] data) {
        var b = new ByteArray();
        int i = 0;
        while (i < data.length) {
            int n = data[i++];
            if (n == 128) break;
            if (n < 128) {
                int len = int.min(n + 1, data.length - i);
                b.append(data[i : i + len]);
                i += len;
            } else if (i < data.length) {
                uint8 c = data[i++];
                for (int k = 0; k < 257 - n; k++) b.append({ c });
            }
        }
        return b.steal();
    }

    public uint8[] lzw(uint8[] data, int early = 1) {
        var output = new ByteArray();
        var table = new Gee.ArrayList<Bytes>();
        for (int i = 0; i < 256; i++) table.add(new Bytes({ (uint8) i }));
        table.add(new Bytes({}));
        table.add(new Bytes({}));
        int code_len = 9;
        uint32 bitbuf = 0;
        int bits = 0;
        int pos = 0;
        Bytes? prev = null;
        while (true) {
            while (bits < code_len && pos < data.length) {
                bitbuf = (bitbuf << 8) | data[pos++];
                bits += 8;
            }
            if (bits < code_len) break;
            int code = (int) ((bitbuf >> (bits - code_len)) & ((1 << code_len) - 1));
            bits -= code_len;
            if (code == 256) {
                while (table.size > 258) table.remove_at(table.size - 1);
                code_len = 9;
                prev = null;
                continue;
            }
            if (code == 257) break;
            Bytes entry;
            if (code < table.size) {
                entry = table[code];
                if (prev != null) {
                    var ne = new ByteArray();
                    ne.append(prev.get_data());
                    ne.append({ entry.get_data()[0] });
                    table.add(ByteArray.free_to_bytes(ne));
                }
            } else if (prev != null) {
                var ne = new ByteArray();
                ne.append(prev.get_data());
                ne.append({ prev.get_data()[0] });
                entry = ByteArray.free_to_bytes(ne);
                table.add(entry);
            } else {
                break;
            }
            output.append(entry.get_data());
            prev = entry;
            int size = table.size + early;
            if (size >= 4096) code_len = 12;
            else if (size >= 2048) code_len = 12;
            else if (size >= 1024) code_len = 11;
            else if (size >= 512) code_len = 10;
        }
        return output.steal();
    }

    public bool is_image_codec(string filter) {
        return filter == "DCTDecode" || filter == "DCT" || filter == "JPXDecode" || filter == "CCITTFaxDecode" || filter == "CCF"
            || filter == "JBIG2Decode";
    }

    public uint8[] decode(Obj stream, Obj? filter, Obj? parms, bool stop_at_image = true) throws Error {
        uint8[] data = stream.bytes;
        if (filter == null || filter.is_none()) return data;
        Obj[] filters = {};
        Obj[] params = {};
        if (filter.is_name()) {
            filters += filter;
            params += parms;
        } else if (filter.is_array()) {
            for (int i = 0; i < filter.length; i++) {
                filters += filter.at(i);
                params += parms != null && parms.is_array() ? parms.at(i) : parms;
            }
        }
        for (int i = 0; i < filters.length; i++) {
            if (!filters[i].is_name()) continue;
            string f = filters[i].name;
            var p = params[i];
            switch (f) {
                case "FlateDecode":
                case "Fl":
                    data = unpredict(inflate(data), p);
                    break;
                case "LZWDecode":
                case "LZW":
                    int early = p != null && p.is_dict() && p.get("EarlyChange") != null ? p.get("EarlyChange").as_int(1) : 1;
                    data = unpredict(lzw(data, early), p);
                    break;
                case "ASCIIHexDecode":
                case "AHx":
                    data = ascii_hex(data);
                    break;
                case "ASCII85Decode":
                case "A85":
                    data = ascii85(data);
                    break;
                case "RunLengthDecode":
                case "RL":
                    data = run_length(data);
                    break;
                case "Crypt":
                    break;
                default:
                    if (is_image_codec(f) && stop_at_image) return data;
                    throw new PdfError.UNSUPPORTED("filter %s is not supported", f);
            }
        }
        return data;
    }
}
