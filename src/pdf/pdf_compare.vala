namespace Singularity.Pdf {

    public enum ChangeKind {
        INSERTED,
        DELETED,
        REPLACED,
        PAGE_ADDED,
        PAGE_REMOVED
    }

    public class Word {
        public string text;
        public Rect box;

        public Word(string text, Rect box) {
            this.text = text;
            this.box = box;
        }
    }

    public class Change {
        public ChangeKind kind;
        public int page_a = -1;
        public int page_b = -1;
        public string old_text = "";
        public string new_text = "";
        public Gee.ArrayList<Rect?> boxes_a = new Gee.ArrayList<Rect?>();
        public Gee.ArrayList<Rect?> boxes_b = new Gee.ArrayList<Rect?>();
    }

    public class CompareResult {
        public Gee.ArrayList<Change> changes = new Gee.ArrayList<Change>();
        public int inserted_words = 0;
        public int deleted_words = 0;
        public int replaced = 0;
        public int pages_added = 0;
        public int pages_removed = 0;
        public int pages_a = 0;
        public int pages_b = 0;

        public bool identical {
            get { return changes.size == 0; }
        }
    }

    public class Compare {
        public static Gee.ArrayList<Word> words(Document doc, int page) {
            var result = new Gee.ArrayList<Word>();
            var it = new Interpreter(doc);
            it.run_page(page);
            var cur = new StringBuilder();
            var box = Rect.empty();
            double last_x = -double.MAX, last_y = double.MAX;
            foreach (var item in it.items) {
                if (item.kind != ItemKind.TEXT) continue;
                foreach (var g in item.glyphs) {
                    double y = (g.box.y1 + g.box.y2) / 2;
                    bool gap = last_x > -double.MAX && (g.box.x1 - last_x > g.box.height() * 0.2 || (y - last_y).abs() > g.box.height() * 0.6);
                    if (g.space || g.text.strip() == "" || gap) {
                        if (cur.len > 0) {
                            result.add(new Word(cur.str, box));
                            cur.truncate();
                            box = Rect.empty();
                        }
                        if (g.space || g.text.strip() == "") {
                            last_x = g.box.x2;
                            last_y = y;
                            continue;
                        }
                    }
                    cur.append(g.text);
                    box.union(g.box);
                    last_x = g.box.x2;
                    last_y = y;
                }
            }
            if (cur.len > 0) result.add(new Word(cur.str, box));
            return result;
        }

        private static string join(Gee.List<Word> list, int from, int to) {
            var s = new StringBuilder();
            for (int i = from; i < to; i++) {
                if (s.len > 0) s.append_c(' ');
                s.append(list[i].text);
            }
            return s.str;
        }

        public static void diff_words(Gee.List<Word> a, Gee.List<Word> b, int page_a, int page_b, CompareResult result) {
            int n = a.size, m = b.size;
            int prefix = 0;
            while (prefix < n && prefix < m && a[prefix].text == b[prefix].text) prefix++;
            int suffix = 0;
            while (suffix < n - prefix && suffix < m - prefix && a[n - 1 - suffix].text == b[m - 1 - suffix].text) suffix++;
            int an = n - prefix - suffix, bm = m - prefix - suffix;
            if (an == 0 && bm == 0) return;
            if ((int64) an * bm > 16000000) {
                emit(a, b, prefix, prefix + an, prefix, prefix + bm, page_a, page_b, result);
                return;
            }
            var dp = new int[(an + 1) * (bm + 1)];
            for (int i = an - 1; i >= 0; i--) {
                for (int j = bm - 1; j >= 0; j--) {
                    if (a[prefix + i].text == b[prefix + j].text) dp[i * (bm + 1) + j] = dp[(i + 1) * (bm + 1) + j + 1] + 1;
                    else dp[i * (bm + 1) + j] = int.max(dp[(i + 1) * (bm + 1) + j], dp[i * (bm + 1) + j + 1]);
                }
            }
            int x = 0, y = 0;
            int da = -1, db = -1;
            while (x < an || y < bm) {
                if (x < an && y < bm && a[prefix + x].text == b[prefix + y].text) {
                    if (da >= 0 || db >= 0) {
                        emit(a, b, da >= 0 ? prefix + da : prefix + x, prefix + x, db >= 0 ? prefix + db : prefix + y, prefix + y, page_a, page_b, result);
                        da = -1;
                        db = -1;
                    }
                    x++;
                    y++;
                } else if (y < bm && (x >= an || dp[x * (bm + 1) + y + 1] >= dp[(x + 1) * (bm + 1) + y])) {
                    if (db < 0) db = y;
                    if (da < 0) da = -1;
                    y++;
                } else {
                    if (da < 0) da = x;
                    x++;
                }
            }
            if (da >= 0 || db >= 0) emit(a, b, da >= 0 ? prefix + da : prefix + x, prefix + x, db >= 0 ? prefix + db : prefix + y, prefix + y, page_a, page_b, result);
        }

        private static void emit(Gee.List<Word> a, Gee.List<Word> b, int a1, int a2, int b1, int b2, int page_a, int page_b, CompareResult result) {
            var c = new Change();
            c.page_a = page_a;
            c.page_b = page_b;
            c.old_text = join(a, a1, a2);
            c.new_text = join(b, b1, b2);
            for (int i = a1; i < a2; i++) c.boxes_a.add(a[i].box);
            for (int i = b1; i < b2; i++) c.boxes_b.add(b[i].box);
            if (a2 > a1 && b2 > b1) {
                c.kind = ChangeKind.REPLACED;
                result.replaced++;
                result.deleted_words += a2 - a1;
                result.inserted_words += b2 - b1;
            } else if (a2 > a1) {
                c.kind = ChangeKind.DELETED;
                result.deleted_words += a2 - a1;
            } else {
                c.kind = ChangeKind.INSERTED;
                result.inserted_words += b2 - b1;
            }
            result.changes.add(c);
        }

        private static double similarity(Gee.List<Word> a, Gee.List<Word> b) {
            if (a.size == 0 && b.size == 0) return 1;
            var set = new Gee.HashMap<string, int>();
            foreach (var w in a) set[w.text] = (set.has_key(w.text) ? set[w.text] : 0) + 1;
            int common = 0;
            foreach (var w in b) {
                if (set.has_key(w.text) && set[w.text] > 0) {
                    common++;
                    set[w.text] = set[w.text] - 1;
                }
            }
            return 2.0 * common / (a.size + b.size);
        }

        public static CompareResult documents(Document a, Document b) {
            var result = new CompareResult();
            result.pages_a = a.page_count();
            result.pages_b = b.page_count();
            var wa = new Gee.ArrayList<Gee.ArrayList<Word>>();
            var wb = new Gee.ArrayList<Gee.ArrayList<Word>>();
            for (int i = 0; i < result.pages_a; i++) wa.add(words(a, i));
            for (int i = 0; i < result.pages_b; i++) wb.add(words(b, i));
            int n = wa.size, m = wb.size;
            var score = new int[(n + 1) * (m + 1)];
            for (int i = n - 1; i >= 0; i--) {
                for (int j = m - 1; j >= 0; j--) {
                    int match = similarity(wa[i], wb[j]) >= 0.5 ? score[(i + 1) * (m + 1) + j + 1] + 1 : -1;
                    score[i * (m + 1) + j] = int.max(match, int.max(score[(i + 1) * (m + 1) + j], score[i * (m + 1) + j + 1]));
                }
            }
            int x = 0, y = 0;
            while (x < n || y < m) {
                if (x < n && y < m && similarity(wa[x], wb[y]) >= 0.5 && score[x * (m + 1) + y] == score[(x + 1) * (m + 1) + y + 1] + 1) {
                    diff_words(wa[x], wb[y], x, y, result);
                    x++;
                    y++;
                } else if (y < m && (x >= n || score[x * (m + 1) + y + 1] >= score[(x + 1) * (m + 1) + y])) {
                    var c = new Change();
                    c.kind = ChangeKind.PAGE_ADDED;
                    c.page_b = y;
                    c.new_text = join(wb[y], 0, int.min(wb[y].size, 40));
                    result.changes.add(c);
                    result.pages_added++;
                    y++;
                } else {
                    var c = new Change();
                    c.kind = ChangeKind.PAGE_REMOVED;
                    c.page_a = x;
                    c.old_text = join(wa[x], 0, int.min(wa[x].size, 40));
                    result.changes.add(c);
                    result.pages_removed++;
                    x++;
                }
            }
            return result;
        }
    }
}
