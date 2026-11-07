using Gtk;

namespace Singularity.Widgets {

    public delegate string ReadAloudText();

    public class ReadAloudButton : IconButton {
        private ReadAloudText? source = null;
        private uint job = 0;
        private ulong word_id = 0;
        private ulong finished_id = 0;

        public string text { get; set; default = ""; }
        public bool reading { get; private set; default = false; }

        public signal void word(int offset, int length);
        public signal void done(bool completed);

        public ReadAloudButton() {
            Object();
        }

        construct {
            icon = "audio-speakers-symbolic";
            tooltip_text = _("Read Aloud");
            update_property(Gtk.AccessibleProperty.LABEL, _("Read Aloud"), -1);
            clicked.connect(toggle);
        }

        public override void dispose() {
            disconnect_speech();
            base.dispose();
        }

        public void set_text_func(owned ReadAloudText func) {
            source = (owned) func;
        }

        public void toggle() {
            if (reading) {
                Speech.get_default().stop();
                finish(false);
            } else {
                start.begin();
            }
        }

        private async void start() {
            string t = source != null ? source() : text;
            if (t.strip() == "") return;
            var speech = Speech.get_default();
            disconnect_speech();
            reading = true;
            update();
            word_id = speech.word.connect((j, offset, length) => {
                if (j == job) word(offset, length);
            });
            finished_id = speech.finished.connect((j, completed) => {
                if (j == job) finish(completed);
            });
            try {
                job = yield speech.speak(t);
                if (speech.has_finished(job)) finish(true);
            } catch (Error e) {
                debug("ReadAloudButton: %s", e.message);
                finish(false);
            }
        }

        private void finish(bool completed) {
            if (!reading) return;
            disconnect_speech();
            job = 0;
            reading = false;
            update();
            done(completed);
        }

        private void disconnect_speech() {
            var speech = Speech.get_default();
            if (word_id != 0) speech.disconnect(word_id);
            if (finished_id != 0) speech.disconnect(finished_id);
            word_id = 0;
            finished_id = 0;
        }

        private void update() {
            icon = reading ? "media-playback-stop-symbolic" : "audio-speakers-symbolic";
            string label = reading ? _("Stop Reading") : _("Read Aloud");
            tooltip_text = label;
            update_property(Gtk.AccessibleProperty.LABEL, label, -1);
        }
    }
}
