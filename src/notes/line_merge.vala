namespace Singularity.Notes {

    public class LineMerge : Object {
        private const int MAX_LINES = 4000;

        public static string? merge(string base_text, string local, string remote) {
            if (local == remote) return local;
            if (local == base_text) return remote;
            if (remote == base_text) return local;
            string[] b = base_text.split("\n");
            string[] l = local.split("\n");
            string[] o = remote.split("\n");
            if (b.length > MAX_LINES || l.length > MAX_LINES || o.length > MAX_LINES) return null;
            var lh = hunks(b, l);
            var oh = hunks(b, o);
            var all = new Gee.ArrayList<Hunk>();
            foreach (var h in lh) {
                foreach (var g in oh) {
                    if (!h.touches(g)) continue;
                    if (h.same(g)) {
                        g.duplicate = true;
                        continue;
                    }
                    return null;
                }
                all.add(h);
            }
            foreach (var g in oh) if (!g.duplicate) all.add(g);
            all.sort((x, y) => x.start != y.start ? x.start - y.start : x.end - y.end);
            var output = new Gee.ArrayList<string>();
            int pos = 0;
            foreach (var h in all) {
                for (int i = pos; i < h.start; i++) output.add(b[i]);
                foreach (string s in h.lines) output.add(s);
                pos = int.max(pos, h.end);
            }
            for (int i = pos; i < b.length; i++) output.add(b[i]);
            var sb = new StringBuilder();
            for (int i = 0; i < output.size; i++) {
                if (i > 0) sb.append("\n");
                sb.append(output[i]);
            }
            return sb.str;
        }

        public static string pick(string base_value, string local, string remote) {
            if (local == remote) return local;
            if (local == base_value) return remote;
            if (remote == base_value) return local;
            return remote;
        }

        private class Hunk : Object {
            public int start;
            public int end;
            public Gee.ArrayList<string> lines = new Gee.ArrayList<string>();
            public bool duplicate = false;

            public bool touches(Hunk other) {
                if (start < other.end && other.start < end) return true;
                if (start == end || other.start == other.end) return start <= other.end && other.start <= end;
                return false;
            }

            public bool same(Hunk other) {
                if (start != other.start || end != other.end || lines.size != other.lines.size) return false;
                for (int i = 0; i < lines.size; i++) if (lines[i] != other.lines[i]) return false;
                return true;
            }
        }

        private static Gee.ArrayList<Hunk> hunks(string[] a, string[] b) {
            int n = a.length;
            int m = b.length;
            var table = new int[(n + 1) * (m + 1)];
            for (int i = n - 1; i >= 0; i--) {
                for (int j = m - 1; j >= 0; j--) {
                    if (a[i] == b[j]) table[i * (m + 1) + j] = table[(i + 1) * (m + 1) + j + 1] + 1;
                    else table[i * (m + 1) + j] = int.max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1]);
                }
            }
            var list = new Gee.ArrayList<Hunk>();
            int i = 0;
            int j = 0;
            Hunk? cur = null;
            while (i < n || j < m) {
                if (i < n && j < m && a[i] == b[j]) {
                    if (cur != null) {
                        list.add(cur);
                        cur = null;
                    }
                    i++;
                    j++;
                } else if (j < m && (i == n || table[i * (m + 1) + j + 1] >= table[(i + 1) * (m + 1) + j])) {
                    if (cur == null) {
                        cur = new Hunk();
                        cur.start = i;
                        cur.end = i;
                    }
                    cur.lines.add(b[j]);
                    j++;
                } else {
                    if (cur == null) {
                        cur = new Hunk();
                        cur.start = i;
                        cur.end = i;
                    }
                    cur.end = i + 1;
                    i++;
                }
            }
            if (cur != null) list.add(cur);
            return list;
        }
    }
}
