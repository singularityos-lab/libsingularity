namespace Singularity {

    public class TilingLayout {
        public const uint SNAP_NONE = 0;
        public const uint SNAP_LEFT = 1;
        public const uint SNAP_RIGHT = 2;
        public const uint SNAP_TOP = 3;
        public const uint SNAP_BOTTOM = 4;
        public const uint SNAP_TOP_LEFT = 5;
        public const uint SNAP_TOP_RIGHT = 6;
        public const uint SNAP_BOTTOM_LEFT = 7;
        public const uint SNAP_BOTTOM_RIGHT = 8;
        public const uint SNAP_MAXIMIZE = 9;

        public static uint snap_for(int count, int index) {
            if (count <= 1) return SNAP_MAXIMIZE;
            if (count == 2) return index == 0 ? SNAP_LEFT : SNAP_RIGHT;
            if (count == 3) {
                if (index == 0) return SNAP_LEFT;
                if (index == 1) return SNAP_TOP_RIGHT;
                return SNAP_BOTTOM_RIGHT;
            }
            switch (index) {
                case 0:  return SNAP_TOP_LEFT;
                case 1:  return SNAP_TOP_RIGHT;
                case 2:  return SNAP_BOTTOM_LEFT;
                case 3:  return SNAP_BOTTOM_RIGHT;
                default: return SNAP_MAXIMIZE;
            }
        }
    }
}
