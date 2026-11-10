namespace Singularity {

    public errordomain SystemJournalError {
        NOT_AVAILABLE,
        FAILED
    }

    public class SystemJournalEntry : Object {
        public int64 time { get; construct; }
        public int priority { get; construct; }
        public int pid { get; construct; }
        public string identifier { get; construct; }
        public string unit { get; construct; }
        public string boot { get; construct; }
        public string message { get; construct; }

        public SystemJournalEntry(int64 time, int priority, int pid, string identifier, string unit, string boot, string message) {
            Object(time: time, priority: priority, pid: pid, identifier: identifier, unit: unit, boot: boot, message: message);
        }
    }

    public class SystemJournal : Object {
        public string? directory { get; construct; }

        public SystemJournal(string? directory = null) {
            Object(directory: directory);
        }

        public bool available() {
            return SintySystem.logs_journal_available(directory);
        }

        public GenericArray<SystemJournalEntry> query_sync(string? boot, int max_priority, string? unit, size_t limit) throws SystemJournalError {
            SintySystem.LogEntries list;
            int rc = SintySystem.logs_journal(directory, boot, max_priority, unit, limit, out list);
            if (rc == -Posix.ENOENT) throw new SystemJournalError.NOT_AVAILABLE("no journal");
            if (rc < 0) throw new SystemJournalError.FAILED(Posix.strerror(-rc));
            var result = new GenericArray<SystemJournalEntry>();
            for (size_t i = 0; i < list.count(); i++) {
                unowned SintySystem.LogEntry? e = list.at(i);
                result.add(new SystemJournalEntry((int64) e.realtime_usec, e.priority, e.pid,
                    (string) e.identifier, (string) e.unit, (string) e.boot_id, (string) e.message));
            }
            return result;
        }

        public async GenericArray<SystemJournalEntry> query(string? boot, int max_priority, string? unit, size_t limit) throws SystemJournalError {
            GenericArray<SystemJournalEntry>? result = null;
            SystemJournalError? failure = null;
            string? b = boot;
            string? u = unit;
            SourceFunc resume = query.callback;
            new Thread<void>("system-journal", () => {
                try {
                    result = query_sync(b, max_priority, u, limit);
                } catch (SystemJournalError e) {
                    failure = e;
                }
                Idle.add((owned) resume);
            });
            yield;
            if (failure != null) throw failure;
            return result;
        }
    }
}
