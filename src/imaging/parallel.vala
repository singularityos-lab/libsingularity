namespace Singularity.Imaging {

    public delegate void RangeFunc(int start, int end);

    namespace Parallel {

        private int cached_threads = 0;

        public int threads() {
            if (cached_threads <= 0) {
                string? forced = Environment.get_variable("SINGULARITY_IMAGING_THREADS");
                int n = forced != null ? int.parse(forced) : (int) get_num_processors();
                cached_threads = n.clamp(1, 64);
            }
            return cached_threads;
        }

        public void range(int count, RangeFunc func, int min_chunk = 8) {
            if (count <= 0) return;
            int n = int.min(threads(), (count + min_chunk - 1) / min_chunk);
            if (n <= 1) {
                func(0, count);
                return;
            }
            var workers = new Thread<bool>[n - 1];
            int chunk = (count + n - 1) / n;
            for (int i = 1; i < n; i++) {
                int start = i * chunk;
                int end = int.min(count, start + chunk);
                workers[i - 1] = new Thread<bool>("imaging", () => {
                    if (start < end) func(start, end);
                    return true;
                });
            }
            func(0, int.min(count, chunk));
            foreach (var w in workers) w.join();
        }
    }
}
