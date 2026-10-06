namespace Singularity.Print {

    public enum PageSet {
        ALL,
        ODD,
        EVEN
    }

    public enum NupOrder {
        LEFT_RIGHT_TOP_BOTTOM,
        RIGHT_LEFT_TOP_BOTTOM,
        TOP_BOTTOM_LEFT_RIGHT,
        TOP_BOTTOM_RIGHT_LEFT
    }

    public enum ScaleMode {
        FIT,
        ACTUAL,
        CUSTOM
    }

    /**
     * Parses page range text such as "1-3, 7" or "5-" against a document
     * of `n_pages` pages. Page numbers are one-based in the text and
     * zero-based in the result, which is sorted and free of duplicates.
     */
    namespace PageRanges {

        public int[] parse(string text, int n_pages) throws PrintError {
            var seen = new bool[int.max(n_pages, 0)];
            string cleaned = text.replace(";", ",").replace(" ", "");
            if (cleaned == "") throw new PrintError.INVALID(_("Enter the pages to print"));
            foreach (var part in cleaned.split(",")) {
                if (part == "") continue;
                int first, last;
                int dash = part.index_of("-");
                if (dash < 0) {
                    first = last = parse_number(part);
                } else {
                    string a = part.substring(0, dash);
                    string b = part.substring(dash + 1);
                    first = a == "" ? 1 : parse_number(a);
                    last = b == "" ? n_pages : parse_number(b);
                }
                if (first < 1 || last < 1 || first > n_pages || last > n_pages)
                    throw new PrintError.INVALID(_("The document has %d pages").printf(n_pages));
                if (first > last) {
                    int t = first;
                    first = last;
                    last = t;
                }
                for (int p = first; p <= last; p++) seen[p - 1] = true;
            }
            int[] pages = {};
            for (int i = 0; i < n_pages; i++) if (seen[i]) pages += i;
            if (pages.length == 0) throw new PrintError.INVALID(_("Enter the pages to print"));
            return pages;
        }

        public string format(int[] pages) {
            var parts = new StringBuilder();
            int i = 0;
            while (i < pages.length) {
                int j = i;
                while (j + 1 < pages.length && pages[j + 1] == pages[j] + 1) j++;
                if (parts.len > 0) parts.append(", ");
                if (j == i) parts.append((pages[i] + 1).to_string());
                else parts.append("%d-%d".printf(pages[i] + 1, pages[j] + 1));
                i = j + 1;
            }
            return parts.str;
        }

        private int parse_number(string s) throws PrintError {
            int64 v;
            if (!int64.try_parse(s, out v) || v > int.MAX)
                throw new PrintError.INVALID(_("\"%s\" is not a page number").printf(s));
            return (int) v;
        }
    }

    /**
     * Where one logical page lands on a sheet side, in points from the
     * sheet's top left corner. `page` is -1 for a blank slot.
     */
    public struct Placement {
        public int page;
        public double x;
        public double y;
        public double width;
        public double height;
        public bool rotated;
        public double scale;
    }

    /**
     * One printed side of a sheet.
     */
    public class SheetSide : Object {
        public double width;
        public double height;
        public Placement[] placements = {};
    }

    /**
     * The inputs of imposition: page and sheet geometry plus the
     * options that decide which pages go where.
     */
    public class LayoutSpec : Object {
        public double page_width { get; set; default = 595; }
        public double page_height { get; set; default = 842; }
        public double sheet_width { get; set; default = 595; }
        public double sheet_height { get; set; default = 842; }
        public int pages_per_sheet { get; set; default = 1; }
        public NupOrder order { get; set; default = NupOrder.LEFT_RIGHT_TOP_BOTTOM; }
        public ScaleMode scale_mode { get; set; default = ScaleMode.FIT; }
        public double scale_percent { get; set; default = 100; }
        public bool booklet { get; set; }
        public PageSet page_set { get; set; default = PageSet.ALL; }
        public bool reverse { get; set; }
        public double gutter { get; set; default = 0; }
    }

    /**
     * Pure imposition: turns a list of selected logical pages into sheet
     * sides for n-up, booklet, odd or even and reverse order.
     */
    namespace Imposition {

        public const int[] PAGES_PER_SHEET = {1, 2, 4, 6, 9, 16};

        public Gee.ArrayList<SheetSide> impose(int[] pages, LayoutSpec spec) {
            var sides = spec.booklet ? booklet(pages, spec) : nup(pages, spec);
            if (spec.page_set != PageSet.ALL) {
                var filtered = new Gee.ArrayList<SheetSide>();
                for (int i = 0; i < sides.size; i++) {
                    bool odd = i % 2 == 0;
                    if ((spec.page_set == PageSet.ODD) == odd) filtered.add(sides[i]);
                }
                sides = filtered;
            }
            if (spec.reverse) {
                var reversed = new Gee.ArrayList<SheetSide>();
                for (int i = sides.size - 1; i >= 0; i--) reversed.add(sides[i]);
                sides = reversed;
            }
            return sides;
        }

        public int physical_sheets(int sides, bool duplex, int copies) {
            int per_copy = duplex ? (sides + 1) / 2 : sides;
            return per_copy * int.max(copies, 1);
        }

        public void grid(int n, double sheet_w, double sheet_h, double page_w, double page_h,
                         out int cols, out int rows, out bool rotated) {
            cols = 1;
            rows = 1;
            rotated = false;
            double best = -1;
            for (int c = 1; c <= n; c++) {
                if (n % c != 0) continue;
                int r = n / c;
                for (int rot = 0; rot < 2; rot++) {
                    double pw = rot == 1 ? page_h : page_w;
                    double ph = rot == 1 ? page_w : page_h;
                    double s = double.min(sheet_w / c / pw, sheet_h / r / ph);
                    if (s > best + 1e-9) {
                        best = s;
                        cols = c;
                        rows = r;
                        rotated = rot == 1;
                    }
                }
            }
        }

        private Gee.ArrayList<SheetSide> nup(int[] pages, LayoutSpec spec) {
            var list = new Gee.ArrayList<SheetSide>();
            int n = int.max(spec.pages_per_sheet, 1);
            int cols, rows;
            bool rotated;
            grid(n, spec.sheet_width, spec.sheet_height, spec.page_width, spec.page_height,
                 out cols, out rows, out rotated);
            double cell_w = spec.sheet_width / cols;
            double cell_h = spec.sheet_height / rows;
            for (int start = 0; start < pages.length; start += n) {
                var side = new SheetSide();
                side.width = spec.sheet_width;
                side.height = spec.sheet_height;
                Placement[] cells = {};
                for (int k = 0; k < n; k++) {
                    int col, row;
                    cell_position(k, cols, rows, spec.order, out col, out row);
                    var p = Placement();
                    p.page = start + k < pages.length ? pages[start + k] : -1;
                    p.rotated = rotated;
                    double pw = rotated ? spec.page_height : spec.page_width;
                    double ph = rotated ? spec.page_width : spec.page_height;
                    double inner_w = cell_w - spec.gutter * 2;
                    double inner_h = cell_h - spec.gutter * 2;
                    double scale = double.min(inner_w / pw, inner_h / ph);
                    if (n == 1 && spec.scale_mode == ScaleMode.ACTUAL) scale = 1.0;
                    else if (n == 1 && spec.scale_mode == ScaleMode.CUSTOM) scale = spec.scale_percent / 100.0;
                    p.scale = scale;
                    p.width = pw * scale;
                    p.height = ph * scale;
                    p.x = col * cell_w + (cell_w - p.width) / 2;
                    p.y = row * cell_h + (cell_h - p.height) / 2;
                    cells += p;
                }
                side.placements = cells;
                list.add(side);
            }
            return list;
        }

        private void cell_position(int k, int cols, int rows, NupOrder order, out int col, out int row) {
            switch (order) {
                case NupOrder.RIGHT_LEFT_TOP_BOTTOM:
                    row = k / cols;
                    col = cols - 1 - k % cols;
                    break;
                case NupOrder.TOP_BOTTOM_LEFT_RIGHT:
                    col = k / rows;
                    row = k % rows;
                    break;
                case NupOrder.TOP_BOTTOM_RIGHT_LEFT:
                    col = cols - 1 - k / rows;
                    row = k % rows;
                    break;
                default:
                    row = k / cols;
                    col = k % cols;
                    break;
            }
        }

        public int[] booklet_order(int n_pages) {
            int padded = ((n_pages + 3) / 4) * 4;
            int[] order = {};
            for (int s = 0; s < padded / 4; s++) {
                order += padded - 1 - 2 * s;
                order += 2 * s;
                order += 2 * s + 1;
                order += padded - 2 - 2 * s;
            }
            return order;
        }

        private Gee.ArrayList<SheetSide> booklet(int[] pages, LayoutSpec spec) {
            var list = new Gee.ArrayList<SheetSide>();
            double sw = double.max(spec.sheet_width, spec.sheet_height);
            double sh = double.min(spec.sheet_width, spec.sheet_height);
            double half = sw / 2;
            double scale = double.min(half / spec.page_width, sh / spec.page_height);
            var order = booklet_order(pages.length);
            for (int i = 0; i < order.length; i += 2) {
                var side = new SheetSide();
                side.width = sw;
                side.height = sh;
                Placement[] cells = {};
                for (int k = 0; k < 2; k++) {
                    var p = Placement();
                    int idx = order[i + k];
                    p.page = idx < pages.length ? pages[idx] : -1;
                    p.rotated = false;
                    p.scale = scale;
                    p.width = spec.page_width * scale;
                    p.height = spec.page_height * scale;
                    p.x = k * half + (k == 0 ? half - p.width : 0);
                    p.y = (sh - p.height) / 2;
                    cells += p;
                }
                side.placements = cells;
                list.add(side);
            }
            return list;
        }
    }
}
