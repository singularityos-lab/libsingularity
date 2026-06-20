namespace Singularity {

    public class SharedClock : Object {
        private static SharedClock? _instance = null;
        private uint timer_id = 0;

        public signal void minute_changed(DateTime now);

        public static SharedClock get_default() {
            if (_instance == null) {
                _instance = new SharedClock();
            }
            return _instance;
        }

        private SharedClock() {
            schedule_next_minute();
        }

        private void schedule_next_minute() {
            var now = new DateTime.now_local();
            uint secs_to_next = (uint)(60 - now.get_second());
            timer_id = Timeout.add_seconds(secs_to_next, () => {
                timer_id = 0;
                minute_changed(new DateTime.now_local());
                schedule_next_minute();
                return Source.REMOVE;
            });
        }
    }
}
