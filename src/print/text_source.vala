namespace Singularity.Print {

    /**
     * Prints a Gtk.TextBuffer with the formatting of its tags: weight,
     * style, underline, strikethrough, size, scale, family, colours,
     * justification, indents and paragraph spacing. Paragraphs flow
     * across pages line by line.
     */
    public class TextBufferSource : PageSource {
        public Gtk.TextBuffer buffer { get; construct; }
        public string font { get; set; default = "Serif 11"; }

        private struct Slice {
            public int paragraph;
            public int first_line;
            public int last_line;
            public double y;
        }

        private class Paragraph {
            public Pango.Layout layout;
            public double above;
            public double below;
            public double left;
        }

        private Gee.ArrayList<Paragraph> paragraphs = new Gee.ArrayList<Paragraph>();
        private Gee.ArrayList<Gee.ArrayList<Slice?>> pages = new Gee.ArrayList<Gee.ArrayList<Slice?>>();
        private PageFormat format = new PageFormat();

        public TextBufferSource(Gtk.TextBuffer buffer, string title) {
            Object(buffer: buffer);
            this.title = title;
        }

        public override async int paginate(PageFormat format) throws Error {
            this.format = format;
            page_width = format.width;
            page_height = format.height;
            paragraphs.clear();
            pages.clear();
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, 1, 1);
            var cr = new Cairo.Context(surface);
            var ctx = Pango.cairo_create_context(cr);
            Pango.cairo_context_set_resolution(ctx, 72);
            double width = format.content_width;
            Gtk.TextIter start;
            buffer.get_start_iter(out start);
            bool selection = print_selection && buffer.has_selection;
            Gtk.TextIter sel_start, sel_end;
            buffer.get_selection_bounds(out sel_start, out sel_end);
            if (selection) start = sel_start;
            int count = 0;
            while (true) {
                var line_end = start;
                if (!line_end.ends_line()) line_end.forward_to_line_end();
                if (selection && line_end.compare(sel_end) > 0) line_end = sel_end;
                paragraphs.add(build_paragraph(ctx, start, line_end, width));
                count++;
                if (count % 200 == 0) {
                    Idle.add(paginate.callback);
                    yield;
                }
                var next = start;
                if (!next.forward_line()) break;
                if (selection && next.compare(sel_end) >= 0) break;
                start = next;
            }
            flow();
            return pages.size;
        }

        private Paragraph build_paragraph(Pango.Context ctx, Gtk.TextIter start, Gtk.TextIter end, double width) {
            var p = new Paragraph();
            var layout = new Pango.Layout(ctx);
            layout.set_font_description(Pango.FontDescription.from_string(font));
            layout.set_wrap(Pango.WrapMode.WORD_CHAR);
            string text = buffer.get_slice(start, end, true).replace("\xef\xbf\xbc", "\xe2\x80\x8b");
            layout.set_text(text, -1);
            var attrs = new Pango.AttrList();
            double left = 0;
            double indent = 0;
            foreach (var tag in start.get_tags()) {
                if (tag.pixels_above_lines_set) p.above = double.max(p.above, tag.pixels_above_lines * 0.75);
                if (tag.pixels_below_lines_set) p.below = double.max(p.below, tag.pixels_below_lines * 0.75);
                if (tag.left_margin_set) left = double.max(left, tag.left_margin * 0.75);
                if (tag.indent_set) indent = tag.indent * 0.75;
                if (tag.justification_set) {
                    switch (tag.justification) {
                        case Gtk.Justification.CENTER: layout.set_alignment(Pango.Alignment.CENTER); break;
                        case Gtk.Justification.RIGHT: layout.set_alignment(Pango.Alignment.RIGHT); break;
                        case Gtk.Justification.FILL: layout.set_justify(true); break;
                        default: break;
                    }
                }
            }
            p.left = left;
            layout.set_width((int) ((width - left) * Pango.SCALE));
            layout.set_indent((int) (indent * Pango.SCALE));
            var it = start;
            int offset = 0;
            while (it.compare(end) < 0) {
                var seg_end = it;
                seg_end.forward_to_tag_toggle(null);
                if (seg_end.compare(end) > 0) seg_end = end;
                int seg_len = buffer.get_slice(it, seg_end, true).length;
                uint a = (uint) offset;
                uint b = (uint) (offset + seg_len);
                foreach (var tag in it.get_tags()) add_tag_attrs(attrs, tag, a, b);
                offset += seg_len;
                if (seg_end.equal(it)) break;
                it = seg_end;
            }
            layout.set_attributes(attrs);
            p.layout = layout;
            return p;
        }

        private void add_tag_attrs(Pango.AttrList list, Gtk.TextTag tag, uint a, uint b) {
            Pango.Attribute? attr;
            if (tag.weight_set) { attr = Pango.attr_weight_new((Pango.Weight) tag.weight); insert(list, attr, a, b); }
            if (tag.style_set) { attr = Pango.attr_style_new(tag.style); insert(list, attr, a, b); }
            if (tag.underline_set && tag.underline != Pango.Underline.ERROR && tag.underline != Pango.Underline.ERROR_LINE) {
                attr = Pango.attr_underline_new(tag.underline);
                insert(list, attr, a, b);
            }
            if (tag.strikethrough_set) { attr = Pango.attr_strikethrough_new(tag.strikethrough); insert(list, attr, a, b); }
            if (tag.family_set && tag.family != null) { attr = Pango.attr_family_new(tag.family); insert(list, attr, a, b); }
            if (tag.size_set) { attr = new Pango.AttrSize.with_absolute((int) (tag.size_points * Pango.SCALE)); insert(list, attr, a, b); }
            if (tag.scale_set) { attr = Pango.attr_scale_new(tag.scale); insert(list, attr, a, b); }
            if (tag.foreground_set) {
                var c = tag.foreground_rgba;
                attr = Pango.attr_foreground_new((uint16) (c.red * 65535), (uint16) (c.green * 65535), (uint16) (c.blue * 65535));
                insert(list, attr, a, b);
            }
            if (tag.background_set) {
                var c = tag.background_rgba;
                attr = Pango.attr_background_new((uint16) (c.red * 65535), (uint16) (c.green * 65535), (uint16) (c.blue * 65535));
                insert(list, attr, a, b);
            }
        }

        private void insert(Pango.AttrList list, Pango.Attribute attr, uint a, uint b) {
            attr.start_index = a;
            attr.end_index = b;
            list.insert(attr.copy());
        }

        private void flow() {
            double top = format.margin_top;
            double bottom = format.height - format.margin_bottom;
            double y = top;
            var page = new Gee.ArrayList<Slice?>();
            for (int i = 0; i < paragraphs.size; i++) {
                var p = paragraphs[i];
                if (y > top) y += p.above;
                int n = p.layout.get_line_count();
                int first = 0;
                double seg_start = y;
                for (int l = 0; l < n; l++) {
                    Pango.Rectangle ink, logical;
                    p.layout.get_line_readonly(l).get_extents(out ink, out logical);
                    double lh = logical.height / (double) Pango.SCALE;
                    if (y + lh > bottom && y > top) {
                        if (l > first) page.add(Slice() { paragraph = i, first_line = first, last_line = l - 1, y = seg_start });
                        pages.add(page);
                        page = new Gee.ArrayList<Slice?>();
                        y = top;
                        first = l;
                        seg_start = y;
                    }
                    y += lh;
                }
                if (n > first) page.add(Slice() { paragraph = i, first_line = first, last_line = n - 1, y = seg_start });
                y += p.below;
            }
            if (page.size > 0 || pages.size == 0) pages.add(page);
        }

        public override void render_page(Cairo.Context cr, int index) {
            if (index < 0 || index >= pages.size) return;
            cr.save();
            cr.set_source_rgb(0, 0, 0);
            foreach (var s in pages[index]) {
                var p = paragraphs[s.paragraph];
                var layout = p.layout;
                double y = s.y;
                for (int l = s.first_line; l <= s.last_line; l++) {
                    var line = layout.get_line_readonly(l);
                    Pango.Rectangle ink, logical;
                    line.get_extents(out ink, out logical);
                    double baseline = -logical.y / (double) Pango.SCALE;
                    int x_off = 0;
                    var iter = layout.get_iter();
                    for (int k = 0; k < l; k++) iter.next_line();
                    Pango.Rectangle line_logical;
                    iter.get_line_extents(null, out line_logical);
                    x_off = line_logical.x;
                    cr.move_to(format.margin_left + p.left + x_off / (double) Pango.SCALE, y + baseline);
                    Pango.cairo_show_layout_line(cr, line);
                    y += logical.height / (double) Pango.SCALE;
                }
            }
            cr.restore();
        }
    }
}
