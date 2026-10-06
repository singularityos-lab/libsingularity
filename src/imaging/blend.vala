namespace Singularity.Imaging {

    public enum BlendMode {
        NORMAL,
        DISSOLVE,
        DARKEN,
        MULTIPLY,
        COLOR_BURN,
        LINEAR_BURN,
        DARKER_COLOR,
        LIGHTEN,
        SCREEN,
        COLOR_DODGE,
        LINEAR_DODGE,
        LIGHTER_COLOR,
        OVERLAY,
        SOFT_LIGHT,
        HARD_LIGHT,
        VIVID_LIGHT,
        LINEAR_LIGHT,
        PIN_LIGHT,
        HARD_MIX,
        DIFFERENCE,
        EXCLUSION,
        SUBTRACT,
        DIVIDE,
        HUE,
        SATURATION,
        COLOR,
        LUMINOSITY;

        public const int COUNT = 27;

        public string key() {
            switch (this) {
                case DISSOLVE: return "dissolve";
                case DARKEN: return "darken";
                case MULTIPLY: return "multiply";
                case COLOR_BURN: return "color-burn";
                case LINEAR_BURN: return "linear-burn";
                case DARKER_COLOR: return "darker-color";
                case LIGHTEN: return "lighten";
                case SCREEN: return "screen";
                case COLOR_DODGE: return "color-dodge";
                case LINEAR_DODGE: return "linear-dodge";
                case LIGHTER_COLOR: return "lighter-color";
                case OVERLAY: return "overlay";
                case SOFT_LIGHT: return "soft-light";
                case HARD_LIGHT: return "hard-light";
                case VIVID_LIGHT: return "vivid-light";
                case LINEAR_LIGHT: return "linear-light";
                case PIN_LIGHT: return "pin-light";
                case HARD_MIX: return "hard-mix";
                case DIFFERENCE: return "difference";
                case EXCLUSION: return "exclusion";
                case SUBTRACT: return "subtract";
                case DIVIDE: return "divide";
                case HUE: return "hue";
                case SATURATION: return "saturation";
                case COLOR: return "color";
                case LUMINOSITY: return "luminosity";
                default: return "normal";
            }
        }

        public string label() {
            switch (this) {
                case DISSOLVE: return _("Dissolve");
                case DARKEN: return _("Darken");
                case MULTIPLY: return _("Multiply");
                case COLOR_BURN: return _("Color Burn");
                case LINEAR_BURN: return _("Linear Burn");
                case DARKER_COLOR: return _("Darker Color");
                case LIGHTEN: return _("Lighten");
                case SCREEN: return _("Screen");
                case COLOR_DODGE: return _("Color Dodge");
                case LINEAR_DODGE: return _("Linear Dodge");
                case LIGHTER_COLOR: return _("Lighter Color");
                case OVERLAY: return _("Overlay");
                case SOFT_LIGHT: return _("Soft Light");
                case HARD_LIGHT: return _("Hard Light");
                case VIVID_LIGHT: return _("Vivid Light");
                case LINEAR_LIGHT: return _("Linear Light");
                case PIN_LIGHT: return _("Pin Light");
                case HARD_MIX: return _("Hard Mix");
                case DIFFERENCE: return _("Difference");
                case EXCLUSION: return _("Exclusion");
                case SUBTRACT: return _("Subtract");
                case DIVIDE: return _("Divide");
                case HUE: return _("Hue");
                case SATURATION: return _("Saturation");
                case COLOR: return _("Color");
                case LUMINOSITY: return _("Luminosity");
                default: return _("Normal");
            }
        }

        public string psd_key() {
            switch (this) {
                case DISSOLVE: return "diss";
                case DARKEN: return "dark";
                case MULTIPLY: return "mul ";
                case COLOR_BURN: return "idiv";
                case LINEAR_BURN: return "lbrn";
                case DARKER_COLOR: return "dkCl";
                case LIGHTEN: return "lite";
                case SCREEN: return "scrn";
                case COLOR_DODGE: return "div ";
                case LINEAR_DODGE: return "lddg";
                case LIGHTER_COLOR: return "lgCl";
                case OVERLAY: return "over";
                case SOFT_LIGHT: return "sLit";
                case HARD_LIGHT: return "hLit";
                case VIVID_LIGHT: return "vLit";
                case LINEAR_LIGHT: return "lLit";
                case PIN_LIGHT: return "pLit";
                case HARD_MIX: return "hMix";
                case DIFFERENCE: return "diff";
                case EXCLUSION: return "smud";
                case SUBTRACT: return "fsub";
                case DIVIDE: return "fdiv";
                case HUE: return "hue ";
                case SATURATION: return "sat ";
                case COLOR: return "colr";
                case LUMINOSITY: return "lum ";
                default: return "norm";
            }
        }

        public string ora_key() {
            switch (this) {
                case DARKEN: return "svg:darken";
                case MULTIPLY: return "svg:multiply";
                case COLOR_BURN: return "svg:color-burn";
                case LIGHTEN: return "svg:lighten";
                case SCREEN: return "svg:screen";
                case COLOR_DODGE: return "svg:color-dodge";
                case LINEAR_DODGE: return "svg:plus";
                case OVERLAY: return "svg:overlay";
                case SOFT_LIGHT: return "svg:soft-light";
                case HARD_LIGHT: return "svg:hard-light";
                case DIFFERENCE: return "svg:difference";
                case EXCLUSION: return "svg:exclusion";
                case HUE: return "svg:hue";
                case SATURATION: return "svg:saturation";
                case COLOR: return "svg:color";
                case LUMINOSITY: return "svg:luminosity";
                default: return "svg:src-over";
            }
        }

        public static BlendMode from_key(string key) {
            for (int i = 0; i < COUNT; i++) {
                var m = (BlendMode) i;
                if (m.key() == key || m.psd_key() == key || m.ora_key() == key) return m;
            }
            return NORMAL;
        }
    }

    namespace Blend {

        private float lum(float r, float g, float b) {
            return 0.3f * r + 0.59f * g + 0.11f * b;
        }

        private void clip_color(ref float r, ref float g, ref float b) {
            float l = lum(r, g, b);
            float n = float.min(r, float.min(g, b));
            float x = float.max(r, float.max(g, b));
            if (n < 0) {
                r = l + (r - l) * l / (l - n);
                g = l + (g - l) * l / (l - n);
                b = l + (b - l) * l / (l - n);
            }
            if (x > 1) {
                r = l + (r - l) * (1 - l) / (x - l);
                g = l + (g - l) * (1 - l) / (x - l);
                b = l + (b - l) * (1 - l) / (x - l);
            }
        }

        private void set_lum(ref float r, ref float g, ref float b, float l) {
            float d = l - lum(r, g, b);
            r += d;
            g += d;
            b += d;
            clip_color(ref r, ref g, ref b);
        }

        private float sat(float r, float g, float b) {
            return float.max(r, float.max(g, b)) - float.min(r, float.min(g, b));
        }

        private void set_sat(ref float r, ref float g, ref float b, float s) {
            float mx = float.max(r, float.max(g, b));
            float mn = float.min(r, float.min(g, b));
            float range = mx - mn;
            if (range <= 1e-6f) {
                r = g = b = 0;
                return;
            }
            r = (r - mn) * s / range;
            g = (g - mn) * s / range;
            b = (b - mn) * s / range;
        }

        private float channel(BlendMode mode, float cb, float cs) {
            switch (mode) {
                case BlendMode.DARKEN: return float.min(cb, cs);
                case BlendMode.MULTIPLY: return cb * cs;
                case BlendMode.COLOR_BURN:
                    if (cb >= 1) return 1;
                    if (cs <= 0) return 0;
                    return 1 - float.min(1, (1 - cb) / cs);
                case BlendMode.LINEAR_BURN: return float.max(0, cb + cs - 1);
                case BlendMode.LIGHTEN: return float.max(cb, cs);
                case BlendMode.SCREEN: return cb + cs - cb * cs;
                case BlendMode.COLOR_DODGE:
                    if (cb <= 0) return 0;
                    if (cs >= 1) return 1;
                    return float.min(1, cb / (1 - cs));
                case BlendMode.LINEAR_DODGE: return float.min(1, cb + cs);
                case BlendMode.OVERLAY: return channel(BlendMode.HARD_LIGHT, cs, cb);
                case BlendMode.SOFT_LIGHT:
                    if (cs <= 0.5f) return cb - (1 - 2 * cs) * cb * (1 - cb);
                    float d = cb <= 0.25f ? ((16 * cb - 12) * cb + 4) * cb : Math.sqrtf(cb);
                    return cb + (2 * cs - 1) * (d - cb);
                case BlendMode.HARD_LIGHT:
                    if (cs <= 0.5f) return cb * 2 * cs;
                    return channel(BlendMode.SCREEN, cb, 2 * cs - 1);
                case BlendMode.VIVID_LIGHT:
                    if (cs <= 0.5f) return channel(BlendMode.COLOR_BURN, cb, 2 * cs);
                    return channel(BlendMode.COLOR_DODGE, cb, 2 * cs - 1);
                case BlendMode.LINEAR_LIGHT: return (cb + 2 * cs - 1).clamp(0, 1);
                case BlendMode.PIN_LIGHT:
                    if (cs <= 0.5f) return float.min(cb, 2 * cs);
                    return float.max(cb, 2 * cs - 1);
                case BlendMode.HARD_MIX: return cb + cs >= 1 ? 1 : 0;
                case BlendMode.DIFFERENCE: return (cb - cs).abs();
                case BlendMode.EXCLUSION: return cb + cs - 2 * cb * cs;
                case BlendMode.SUBTRACT: return float.max(0, cb - cs);
                case BlendMode.DIVIDE:
                    if (cs <= 0) return cb > 0 ? 1 : 0;
                    return float.min(1, cb / cs);
                default: return cs;
            }
        }

        public void mix(BlendMode mode, float br, float bg, float bb, float sr, float sg, float sb, out float rr, out float rg, out float rb) {
            switch (mode) {
                case BlendMode.HUE:
                    rr = sr; rg = sg; rb = sb;
                    set_sat(ref rr, ref rg, ref rb, sat(br, bg, bb));
                    set_lum(ref rr, ref rg, ref rb, lum(br, bg, bb));
                    return;
                case BlendMode.SATURATION:
                    rr = br; rg = bg; rb = bb;
                    set_sat(ref rr, ref rg, ref rb, sat(sr, sg, sb));
                    set_lum(ref rr, ref rg, ref rb, lum(br, bg, bb));
                    return;
                case BlendMode.COLOR:
                    rr = sr; rg = sg; rb = sb;
                    set_lum(ref rr, ref rg, ref rb, lum(br, bg, bb));
                    return;
                case BlendMode.LUMINOSITY:
                    rr = br; rg = bg; rb = bb;
                    set_lum(ref rr, ref rg, ref rb, lum(sr, sg, sb));
                    return;
                case BlendMode.DARKER_COLOR:
                    bool darker = lum(sr, sg, sb) < lum(br, bg, bb);
                    rr = darker ? sr : br; rg = darker ? sg : bg; rb = darker ? sb : bb;
                    return;
                case BlendMode.LIGHTER_COLOR:
                    bool lighter = lum(sr, sg, sb) > lum(br, bg, bb);
                    rr = lighter ? sr : br; rg = lighter ? sg : bg; rb = lighter ? sb : bb;
                    return;
                default:
                    rr = channel(mode, br, sr);
                    rg = channel(mode, bg, sg);
                    rb = channel(mode, bb, sb);
                    return;
            }
        }

        private float noise(int x, int y) {
            uint h = (uint) x * 374761393u + (uint) y * 668265263u;
            h = (h ^ (h >> 13)) * 1274126177u;
            return (h ^ (h >> 16)) / 4294967295.0f;
        }

        public void composite(FloatImage dst, FloatImage src, int ox, int oy, BlendMode mode, float opacity, float[]? mask = null, bool perceptual = true) {
            int x0 = int.max(0, ox), y0 = int.max(0, oy);
            int x1 = int.min(dst.width, ox + src.width), y1 = int.min(dst.height, oy + src.height);
            if (x0 >= x1 || y0 >= y1) return;
            Parallel.range(y1 - y0, (start, end) => {
                for (int y = y0 + start; y < y0 + end; y++) {
                    for (int x = x0; x < x1; x++) {
                        int sx = x - ox, sy = y - oy;
                        size_t s = src.offset(sx, sy), d = dst.offset(x, y);
                        float sa = src.data[s + 3] * opacity;
                        if (mask != null) sa *= mask[(size_t) sy * src.width + sx];
                        if (mode == BlendMode.DISSOLVE) {
                            sa = noise(x, y) < sa ? 1.0f : 0.0f;
                        }
                        if (sa <= 0) continue;
                        float ba = dst.data[d + 3];
                        float br = dst.data[d], bg = dst.data[d + 1], bb = dst.data[d + 2];
                        float sr = src.data[s], sg = src.data[s + 1], sb = src.data[s + 2];
                        if (perceptual) {
                            br = Transfer.linear_to_srgb(br); bg = Transfer.linear_to_srgb(bg); bb = Transfer.linear_to_srgb(bb);
                            sr = Transfer.linear_to_srgb(sr); sg = Transfer.linear_to_srgb(sg); sb = Transfer.linear_to_srgb(sb);
                        }
                        float mr, mg, mb;
                        if (mode == BlendMode.NORMAL || mode == BlendMode.DISSOLVE) {
                            mr = sr; mg = sg; mb = sb;
                        } else {
                            mix(mode, br.clamp(0, 1), bg.clamp(0, 1), bb.clamp(0, 1), sr.clamp(0, 1), sg.clamp(0, 1), sb.clamp(0, 1), out mr, out mg, out mb);
                            mr = sr + (mr - sr) * ba;
                            mg = sg + (mg - sg) * ba;
                            mb = sb + (mb - sb) * ba;
                        }
                        float oa = sa + ba * (1 - sa);
                        float rr, rg, rb;
                        if (oa <= 1e-6f) {
                            rr = rg = rb = 0;
                        } else {
                            rr = (mr * sa + br * ba * (1 - sa)) / oa;
                            rg = (mg * sa + bg * ba * (1 - sa)) / oa;
                            rb = (mb * sa + bb * ba * (1 - sa)) / oa;
                        }
                        if (perceptual) {
                            rr = Transfer.srgb_to_linear(rr); rg = Transfer.srgb_to_linear(rg); rb = Transfer.srgb_to_linear(rb);
                        }
                        dst.data[d] = rr;
                        dst.data[d + 1] = rg;
                        dst.data[d + 2] = rb;
                        dst.data[d + 3] = oa;
                    }
                }
            });
        }
    }
}
