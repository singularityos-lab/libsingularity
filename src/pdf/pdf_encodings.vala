namespace Singularity.Pdf.Encodings {

    private const uint16[] WIN_HIGH = {
        0x20ac, 0, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017d, 0,
        0, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0, 0x017e, 0x0178
    };

    private const uint16[] PDFDOC_LOW = {
        0x02d8, 0x02c7, 0x02c6, 0x02d9, 0x02dd, 0x02db, 0x02da, 0x02dc
    };

    private const uint16[] PDFDOC_HIGH = {
        0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044, 0x2039, 0x203a, 0x2212, 0x2030, 0x201e, 0x201c, 0x201d, 0x2018,
        0x2019, 0x201a, 0x2122, 0xfb01, 0xfb02, 0x0141, 0x0152, 0x0160, 0x0178, 0x017d, 0x0131, 0x0142, 0x0153, 0x0161, 0x017e, 0
    };

    private const uint16[] MAC_HIGH = {
        0xc4, 0xc5, 0xc7, 0xc9, 0xd1, 0xd6, 0xdc, 0xe1, 0xe0, 0xe2, 0xe4, 0xe3, 0xe5, 0xe7, 0xe9, 0xe8,
        0xea, 0xeb, 0xed, 0xec, 0xee, 0xef, 0xf1, 0xf3, 0xf2, 0xf4, 0xf6, 0xf5, 0xfa, 0xf9, 0xfb, 0xfc,
        0x2020, 0xb0, 0xa2, 0xa3, 0xa7, 0x2022, 0xb6, 0xdf, 0xae, 0xa9, 0x2122, 0xb4, 0xa8, 0x2260, 0xc6, 0xd8,
        0x221e, 0xb1, 0x2264, 0x2265, 0xa5, 0xb5, 0x2202, 0x2211, 0x220f, 0x3c0, 0x222b, 0xaa, 0xba, 0x3a9, 0xe6, 0xf8,
        0xbf, 0xa1, 0xac, 0x221a, 0x192, 0x2248, 0x2206, 0xab, 0xbb, 0x2026, 0xa0, 0xc0, 0xc3, 0xd5, 0x152, 0x153,
        0x2013, 0x2014, 0x201c, 0x201d, 0x2018, 0x2019, 0xf7, 0x25ca, 0xff, 0x178, 0x2044, 0x20ac, 0x2039, 0x203a, 0xfb01, 0xfb02,
        0x2021, 0xb7, 0x201a, 0x201e, 0x2030, 0xc2, 0xca, 0xc1, 0xcb, 0xc8, 0xcd, 0xce, 0xcf, 0xcc, 0xd3, 0xd4,
        0xf8ff, 0xd2, 0xda, 0xdb, 0xd9, 0x131, 0x2c6, 0x2dc, 0xaf, 0x2d8, 0x2d9, 0x2da, 0xb8, 0x2dd, 0x2db, 0x2c7
    };

    private const string[] GLYPHS = {
        "space", "exclam", "quotedbl", "numbersign", "dollar", "percent", "ampersand", "quotesingle", "parenleft", "parenright",
        "asterisk", "plus", "comma", "hyphen", "period", "slash", "zero", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "colon", "semicolon", "less", "equal", "greater", "question", "at", "A", "B", "C", "D", "E", "F", "G",
        "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "bracketleft", "backslash",
        "bracketright", "asciicircum", "underscore", "grave", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n",
        "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "braceleft", "bar", "braceright", "asciitilde", "",
        "Euro", "", "quotesinglbase", "florin", "quotedblbase", "ellipsis", "dagger", "daggerdbl", "circumflex", "perthousand",
        "Scaron", "guilsinglleft", "OE", "", "Zcaron", "", "", "quoteleft", "quoteright", "quotedblleft", "quotedblright", "bullet",
        "endash", "emdash", "tilde", "trademark", "scaron", "guilsinglright", "oe", "", "zcaron", "Ydieresis", "space", "exclamdown",
        "cent", "sterling", "currency", "yen", "brokenbar", "section", "dieresis", "copyright", "ordfeminine", "guillemotleft",
        "logicalnot", "hyphen", "registered", "macron", "degree", "plusminus", "twosuperior", "threesuperior", "acute", "mu",
        "paragraph", "periodcentered", "cedilla", "onesuperior", "ordmasculine", "guillemotright", "onequarter", "onehalf",
        "threequarters", "questiondown", "Agrave", "Aacute", "Acircumflex", "Atilde", "Adieresis", "Aring", "AE", "Ccedilla",
        "Egrave", "Eacute", "Ecircumflex", "Edieresis", "Igrave", "Iacute", "Icircumflex", "Idieresis", "Eth", "Ntilde", "Ograve",
        "Oacute", "Ocircumflex", "Otilde", "Odieresis", "multiply", "Oslash", "Ugrave", "Uacute", "Ucircumflex", "Udieresis",
        "Yacute", "Thorn", "germandbls", "agrave", "aacute", "acircumflex", "atilde", "adieresis", "aring", "ae", "ccedilla",
        "egrave", "eacute", "ecircumflex", "edieresis", "igrave", "iacute", "icircumflex", "idieresis", "eth", "ntilde", "ograve",
        "oacute", "ocircumflex", "otilde", "odieresis", "divide", "oslash", "ugrave", "uacute", "ucircumflex", "udieresis",
        "yacute", "thorn", "ydieresis"
    };

    private const string[] EXTRA_GLYPHS = {
        "fi", "fb01", "fl", "fb02", "ff", "fb00", "ffi", "fb03", "ffl", "fb04", "minus", "2212", "fraction", "2044",
        "dotlessi", "0131", "Lslash", "0141", "lslash", "0142", "quotesingle", "0027", "grave", "0060", "nbspace", "00a0",
        "sfthyphen", "00ad", "periodcentered", "00b7", "middot", "00b7", "breve", "02d8", "caron", "02c7", "ring", "02da",
        "ogonek", "02db", "hungarumlaut", "02dd", "dotaccent", "02d9", "Omega", "03a9", "pi", "03c0", "mu", "00b5",
        "arrowright", "2192", "arrowleft", "2190", "arrowup", "2191", "arrowdown", "2193", "checkmark", "2713", "lozenge", "25ca",
        "notequal", "2260", "lessequal", "2264", "greaterequal", "2265", "infinity", "221e", "summation", "2211", "radical", "221a"
    };

    private static Gee.HashMap<string, unichar>? names = null;

    public unichar pdfdoc_to_unicode(uint8 c) {
        if (c >= 0x18 && c <= 0x1f) return PDFDOC_LOW[c - 0x18];
        if (c >= 0x80 && c <= 0x9f) return PDFDOC_HIGH[c - 0x80];
        if (c == 0xad) return 0;
        return c;
    }

    public unichar win_to_unicode(uint8 c) {
        if (c >= 0x80 && c <= 0x9f) return WIN_HIGH[c - 0x80];
        return c;
    }

    public unichar mac_to_unicode(uint8 c) {
        if (c >= 0x80) return MAC_HIGH[c - 0x80];
        return c;
    }

    public unichar standard_to_unicode(uint8 c) {
        switch (c) {
            case 0x27: return 0x2019;
            case 0x60: return 0x2018;
            case 0xa4: return 0x2044;
            case 0xa9: return 0x27;
            case 0xaa: return 0x201c;
            case 0xae: return 0xfb01;
            case 0xaf: return 0xfb02;
            case 0xb1: return 0x2013;
            case 0xb2: return 0x2020;
            case 0xb3: return 0x2021;
            case 0xb4: return 0xb7;
            case 0xb7: return 0x2022;
            case 0xb8: return 0x201a;
            case 0xb9: return 0x201e;
            case 0xba: return 0x201d;
            case 0xbc: return 0x2026;
            case 0xbd: return 0x2030;
            case 0xd0: return 0x2014;
            case 0xe1: return 0xc6;
            case 0xe8: return 0x141;
            case 0xe9: return 0xd8;
            case 0xea: return 0x152;
            case 0xf1: return 0xe6;
            case 0xf5: return 0x131;
            case 0xf8: return 0x142;
            case 0xf9: return 0xf8;
            case 0xfa: return 0x153;
            case 0xfb: return 0xdf;
            default: return c < 0x80 ? c : 0;
        }
    }

    public int unicode_to_win(unichar u) {
        if (u < 0x80 || (u >= 0xa0 && u <= 0xff)) return (int) u;
        for (int i = 0; i < WIN_HIGH.length; i++) {
            if (WIN_HIGH[i] == u && u != 0) return 0x80 + i;
        }
        return -1;
    }

    private static void ensure_names() {
        if (names != null) return;
        names = new Gee.HashMap<string, unichar>();
        for (int i = 0; i < GLYPHS.length; i++) {
            if (GLYPHS[i] == "" || names.has_key(GLYPHS[i])) continue;
            names[GLYPHS[i]] = win_to_unicode((uint8) (32 + i));
        }
        for (int i = 0; i + 1 < EXTRA_GLYPHS.length; i += 2) {
            uint64 v = 0;
            if (uint64.try_parse(EXTRA_GLYPHS[i + 1], out v, null, 16)) names[EXTRA_GLYPHS[i]] = (unichar) v;
        }
    }

    public unichar glyph_to_unicode(string glyph) {
        ensure_names();
        string g = glyph;
        int dot = g.index_of_char('.');
        if (dot > 0) g = g.substring(0, dot);
        if (names.has_key(g)) return names[g];
        uint64 v = 0;
        if (g.has_prefix("uni") && g.length >= 7 && uint64.try_parse(g.substring(3, 4), out v, null, 16)) return (unichar) v;
        if (g.has_prefix("u") && g.length >= 5 && g.length <= 7 && uint64.try_parse(g.substring(1), out v, null, 16)) return (unichar) v;
        return 0;
    }

    public string? win_glyph_name(int code) {
        if (code < 32 || code > 255) return null;
        string n = GLYPHS[code - 32];
        return n != "" ? n : null;
    }

    public uint8[] encode_pdfdoc(string s, out bool lossless) {
        var b = new ByteArray();
        lossless = true;
        int i = 0;
        unichar c;
        while (s.get_next_char(ref i, out c)) {
            int code = -1;
            if (c < 0x80 && c >= 0x20 || c == '\n' || c == '\r' || c == '\t') code = (int) c;
            else if (c >= 0xa1 && c <= 0xff && c != 0xad) code = (int) c;
            else {
                for (int k = 0; k < PDFDOC_HIGH.length; k++) {
                    if (PDFDOC_HIGH[k] == c && c != 0) code = 0x80 + k;
                }
            }
            if (code < 0) {
                lossless = false;
                code = '?';
            }
            b.append({ (uint8) code });
        }
        return b.data;
    }
}
