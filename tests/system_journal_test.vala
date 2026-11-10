void test_empty () {
    string dir;
    try {
        dir = DirUtils.make_tmp ("journal-XXXXXX");
    } catch (FileError e) {
        error (e.message);
    }
    var journal = new Singularity.SystemJournal (dir);
    assert (!journal.available ());
    try {
        assert (journal.query_sync (null, 7, null, 10).length == 0);
    } catch (Singularity.SystemJournalError e) {
        assert (e is Singularity.SystemJournalError.NOT_AVAILABLE);
    }
    DirUtils.remove (dir);
}

void test_fixtures () {
    string? dir = Environment.get_variable ("SINTY_JOURNAL_FIXTURES");
    if (dir == null) {
        Test.skip ("no journal fixtures");
        return;
    }
    var journal = new Singularity.SystemJournal (dir);
    assert (journal.available ());
    var loop = new MainLoop ();
    GenericArray<Singularity.SystemJournalEntry>? all = null;
    GenericArray<Singularity.SystemJournalEntry>? errors = null;
    journal.query.begin (null, 7, null, 50, (o, r) => {
        try {
            all = journal.query.end (r);
        } catch (Error e) {
            error (e.message);
        }
        journal.query.begin (null, 3, null, 50, (o2, r2) => {
            try {
                errors = journal.query.end (r2);
            } catch (Error e) {
                error (e.message);
            }
            loop.quit ();
        });
    });
    loop.run ();
    assert (all.length == 50);
    int64 last = 0;
    int with_text = 0;
    foreach (var e in all.data) {
        assert (e.time >= last);
        last = e.time;
        assert (e.boot.length == 32);
        if (e.message != "" && e.identifier != "") with_text++;
    }
    assert (with_text > 40);
    foreach (var e in errors.data) assert (e.priority <= 3);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/system-journal/empty", test_empty);
    Test.add_func ("/system-journal/fixtures", test_fixtures);
    return Test.run ();
}
