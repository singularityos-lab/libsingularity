namespace Singularity.Charts {

    public class DataTable : Object {
        public int rows { get; private set; }
        public int columns { get; private set; }
        private Gee.ArrayList<Gee.ArrayList<string>> text = new Gee.ArrayList<Gee.ArrayList<string>>();

        public DataTable(int rows, int columns) {
            resize(rows, columns);
        }

        public void resize(int new_rows, int new_columns) {
            while (text.size < new_rows) text.add(new Gee.ArrayList<string>());
            while (text.size > new_rows) text.remove_at(text.size - 1);
            foreach (var row in text) {
                while (row.size < new_columns) row.add("");
                while (row.size > new_columns) row.remove_at(row.size - 1);
            }
            rows = new_rows;
            columns = new_columns;
        }

        public void set_text(int row, int column, string value) {
            if (row >= rows || column >= columns) resize(int.max(rows, row + 1), int.max(columns, column + 1));
            text[row][column] = value;
        }

        public void set_number(int row, int column, double value) {
            set_text(row, column, XmlText.num(value));
        }

        public string get_text(int row, int column) {
            if (row < 0 || column < 0 || row >= rows || column >= columns) return "";
            return text[row][column];
        }

        public double get_number(int row, int column) {
            return XmlText.parse_num(get_text(row, column));
        }

        public ChartSpec to_spec(ChartSpec? style, bool series_in_rows = false, bool first_row_names = true, bool first_column_labels = true) {
            var spec = style != null ? style.copy() : new ChartSpec();
            var old = new Gee.ArrayList<Series>();
            foreach (var s in spec.series) old.add(s);
            spec.series.clear();
            int outer = series_in_rows ? rows : columns;
            int inner = series_in_rows ? columns : rows;
            int so = first_column_labels ? 1 : 0;
            int si = first_row_names ? 1 : 0;
            if (series_in_rows) {
                so = first_row_names ? 1 : 0;
                si = first_column_labels ? 1 : 0;
            }
            string[] cats = {};
            for (int j = si; j < inner; j++) {
                bool has_labels = series_in_rows ? first_row_names : first_column_labels;
                cats += has_labels ? (series_in_rows ? get_text(0, j) : get_text(j, 0)) : (j - si + 1).to_string();
            }
            spec.categories = cats;
            for (int i = so; i < outer; i++) {
                Series s = i - so < old.size ? old[i - so] : new Series();
                bool has_names = series_in_rows ? first_column_labels : first_row_names;
                s.name = has_names ? (series_in_rows ? get_text(i, 0) : get_text(0, i)) : _("Series %d").printf(i - so + 1);
                double[] vals = {};
                for (int j = si; j < inner; j++) vals += series_in_rows ? get_number(i, j) : get_number(j, i);
                s.values = vals;
                s.categories = {};
                if (spec.kind == ChartType.SCATTER || spec.kind == ChartType.BUBBLE) {
                    double[] xs = {};
                    foreach (string c in cats) xs += XmlText.parse_num(c);
                    s.xvalues = xs;
                }
                spec.series.add(s);
            }
            return spec;
        }

        public static DataTable from_spec(ChartSpec spec) {
            var cats = spec.category_labels();
            int n = cats.length;
            foreach (var s in spec.series) n = int.max(n, s.values.length);
            var t = new DataTable(n + 1, spec.series.size + 1);
            for (int r = 0; r < n; r++) t.set_text(r + 1, 0, r < cats.length ? cats[r] : "");
            for (int i = 0; i < spec.series.size; i++) {
                var s = spec.series[i];
                t.set_text(0, i + 1, s.name);
                for (int r = 0; r < s.values.length; r++) if (!s.values[r].is_nan()) t.set_number(r + 1, i + 1, s.values[r]);
            }
            return t;
        }
    }
}
