namespace Singularity {

    public enum QuickUnlockKind {
        NONE,
        PIN,
        PATTERN;

        public string to_label() {
            switch (this) {
                case PIN: return _("Quick PIN");
                case PATTERN: return _("Pattern");
                default: return _("Off");
            }
        }
    }

    public enum QuickUnlockResult {
        OK,
        FAIL,
        LOCKED,
        BLOCKED,
        INVALID,
        UNAVAILABLE
    }

    public class QuickUnlock : Object {

        public static bool available() {
            return SintySystem.unlock_available();
        }

        public static QuickUnlockKind kind() {
            SintySystem.UnlockState state = {};
            if (!available() || SintySystem.unlock_state(out state) != 0) return QuickUnlockKind.NONE;
            if (state.kind == SintySystem.UnlockKind.PIN) return QuickUnlockKind.PIN;
            if (state.kind == SintySystem.UnlockKind.PATTERN) return QuickUnlockKind.PATTERN;
            return QuickUnlockKind.NONE;
        }

        public static bool lockdown() {
            return available() && SintySystem.unlock_lockdown() == 0;
        }

        public static async QuickUnlockResult set(string pin, QuickUnlockKind kind, string secret) {
            int code = kind == QuickUnlockKind.PATTERN ? SintySystem.UnlockKind.PATTERN : SintySystem.UnlockKind.PIN;
            return yield run(() => SintySystem.unlock_set(pin, code, secret));
        }

        public static async QuickUnlockResult clear(string pin) {
            return yield run(() => SintySystem.unlock_clear(pin));
        }

        private delegate int Call();

        private static async QuickUnlockResult run(owned Call call) {
            if (!available()) return QuickUnlockResult.UNAVAILABLE;
            int rc = 0;
            SourceFunc resume = run.callback;
            new Thread<void>("quick-unlock", () => {
                rc = call();
                Idle.add((owned) resume);
            });
            yield;
            if (rc < 0) return QuickUnlockResult.UNAVAILABLE;
            switch (rc) {
                case SintySystem.UnlockVerdict.OK: return QuickUnlockResult.OK;
                case SintySystem.UnlockVerdict.LOCKED: return QuickUnlockResult.LOCKED;
                case SintySystem.UnlockVerdict.BLOCKED: return QuickUnlockResult.BLOCKED;
                case SintySystem.UnlockVerdict.INVALID: return QuickUnlockResult.INVALID;
                default: return QuickUnlockResult.FAIL;
            }
        }
    }
}
