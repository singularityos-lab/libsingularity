using GLib;
using Singularity;

[DBus (name = "dev.sinty.Speech1")]
public class FakeSpeech : Object {
    private uint next = 0;
    public bool early = false;
    public int stops = 0;

    public signal void started(uint job);
    public signal void word(uint job, int offset, int length);
    public signal void finished(uint job, bool completed);

    public uint speak(string text, string voice, double rate, double pitch) throws Error {
        uint job = ++next;
        if (early) {
            finished(job, true);
            return job;
        }
        Idle.add(() => {
            started(job);
            word(job, 0, text.index_of(" ") > 0 ? text.index_of(" ") : text.length);
            finished(job, text != "cancel me");
            return Source.REMOVE;
        });
        return job;
    }

    public void stop() throws Error {
        stops++;
    }

    public string[,] list_voices() throws Error {
        var v = new string[2, 4];
        v[0, 0] = "espeak-ng:it";
        v[0, 1] = "Italian";
        v[0, 2] = "it";
        v[0, 3] = "espeak-ng";
        v[1, 0] = "piper:it_IT-paola-medium";
        v[1, 1] = "paola";
        v[1, 2] = "it-IT";
        v[1, 3] = "piper";
        return v;
    }
}

private FakeSpeech fake;
private MainLoop loop;

private void run(owned SourceFunc body) {
    Idle.add((owned) body);
    uint guard = Timeout.add_seconds(5, () => {
        error("timed out");
    });
    loop.run();
    Source.remove(guard);
}

private void test_say_waits_for_the_end() {
    var speech = Speech.get_default();
    int words = 0;
    var id = speech.word.connect(() => words++);
    bool completed = false;
    bool cancelled = true;
    run(() => {
        speech.say.begin("Ciao mondo", "", 0, 0, (o, r) => {
            try {
                completed = speech.say.end(r);
            } catch (Error e) {
                error(e.message);
            }
            speech.say.begin("cancel me", "", 0, 0, (o2, r2) => {
                try {
                    cancelled = speech.say.end(r2);
                } catch (Error e) {
                    error(e.message);
                }
                loop.quit();
            });
        });
        return Source.REMOVE;
    });
    speech.disconnect(id);
    assert(completed);
    assert(!cancelled);
    assert(words == 2);
}

private void test_end_before_the_reply() {
    var speech = Speech.get_default();
    fake.early = true;
    bool completed = false;
    run(() => {
        speech.say.begin("Svelto", "", 0, 0, (o, r) => {
            try {
                completed = speech.say.end(r);
            } catch (Error e) {
                error(e.message);
            }
            loop.quit();
        });
        return Source.REMOVE;
    });
    fake.early = false;
    assert(completed);
}

private void test_voices_and_stop() {
    var speech = Speech.get_default();
    SpeechVoiceInfo[] list = {};
    run(() => {
        speech.voices.begin((o, r) => {
            try {
                list = speech.voices.end(r);
            } catch (Error e) {
                error(e.message);
            }
            speech.stop();
            Timeout.add(200, () => {
                loop.quit();
                return Source.REMOVE;
            });
        });
        return Source.REMOVE;
    });
    assert(list.length == 2);
    assert(list[1].id == "piper:it_IT-paola-medium");
    assert(list[1].engine == "piper");
    assert(fake.stops == 1);
}

int main(string[] args) {
    Test.init(ref args);
    var bus = new TestDBus(TestDBusFlags.NONE);
    bus.up();
    loop = new MainLoop();
    try {
        var conn = Bus.get_sync(BusType.SESSION);
        fake = new FakeSpeech();
        conn.register_object(Speech.OBJECT_PATH, fake);
        Bus.own_name_on_connection(conn, Speech.BUS_NAME, BusNameOwnerFlags.NONE);
    } catch (Error e) {
        error(e.message);
    }
    Test.add_func("/speech/say", test_say_waits_for_the_end);
    Test.add_func("/speech/early-end", test_end_before_the_reply);
    Test.add_func("/speech/voices", test_voices_and_stop);
    int status = Test.run();
    bus.stop();
    Process.exit(status);
}
