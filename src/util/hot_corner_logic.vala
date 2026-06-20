namespace Singularity {

    public struct HotCornerHit {
        public int hint_corner;   // corner index the pointer is hinting, or -1
        public bool arm;          // whether the action at hint_corner should arm
    }

    public class HotCornerLogic {

        public static HotCornerHit evaluate(int w, double x, double last_x,
                                            int corner_size, int edge_trigger,
                                            bool left_enabled, bool right_enabled,
                                            int left_corner, int right_corner) {
            bool moving_left  = last_x >= 0 && x < last_x - 0.5;
            bool moving_right = last_x >= 0 && x > last_x + 0.5;

            HotCornerHit hit = { -1, false };
            if (x < corner_size && left_enabled) {
                hit.hint_corner = left_corner;
                if (x <= edge_trigger && (moving_left || x <= 1)) hit.arm = true;
            } else if (w > 0 && x > w - corner_size && right_enabled) {
                hit.hint_corner = right_corner;
                if (x >= w - edge_trigger && (moving_right || x >= w - 1)) hit.arm = true;
            }
            return hit;
        }
    }
}
