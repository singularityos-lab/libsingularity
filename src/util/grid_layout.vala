namespace Singularity {

    public delegate bool CellTakenFunc(int x, int y);

    public class GridLayout {

        public static int snap(double v, int origin, int grid) {
            int cell = (int)Math.lround((v - origin) / (double)grid);
            if (cell < 0) cell = 0;
            return cell * grid + origin;
        }

        public static void find_free_cell(ref int sx, ref int sy, int origin_y,
                                          int grid, int bottom_limit, CellTakenFunc taken) {
            int guard = 0;
            while (taken(sx, sy) && guard < 4096) {
                sy += grid;
                if (sy > bottom_limit) {
                    sy = origin_y;
                    sx += grid;
                }
                guard++;
            }
        }
    }
}
