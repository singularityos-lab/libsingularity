namespace Singularity.Text {

    /**
     * Spell checking shared by every Singularity process.
     *
     * Uses enchant, so any installed hunspell or aspell dictionary works.
     * Languages come from the desktop `spell-check-languages` setting, or
     * from the session locale when that list is empty. A word is correct
     * when any active dictionary accepts it.
     */
    public class SpellChecker : Object {
        private static SpellChecker? instance = null;

        private Enchant.Broker broker;
        private (unowned Enchant.Dict)[] dicts = {};
        private GLib.Settings? settings;

        /** Emitted when the languages or the enabled state change. */
        public signal void changed();

        /** Whether spell checking is switched on for the desktop. */
        public bool enabled {
            get { return settings == null || settings.get_boolean("spell-check-enabled"); }
        }

        /** Whether at least one dictionary is available for the active languages. */
        public bool available {
            get { return dicts.length > 0; }
        }

        public static SpellChecker get_default() {
            if (instance == null) instance = new SpellChecker();
            return instance;
        }

        private SpellChecker() {
            broker = new Enchant.Broker();
            settings = Core.safe_settings(Singularity.Runtime.desktop_settings_schema);
            if (settings != null && settings.settings_schema.has_key("spell-check-enabled")) {
                settings.changed["spell-check-enabled"].connect(() => changed());
                settings.changed["spell-check-languages"].connect(() => {
                    load_dictionaries();
                    changed();
                });
            } else {
                settings = null;
            }
            load_dictionaries();
        }

        private void load_dictionaries() {
            foreach (unowned Enchant.Dict dict in dicts) broker.free_dict(dict);
            dicts = {};
            string[] languages = settings != null ? settings.get_strv("spell-check-languages") : new string[0];
            if (languages.length == 0) {
                foreach (unowned string name in Intl.get_language_names()) {
                    if (name == "C" || name.contains(".") || name.contains("@")) continue;
                    languages += name;
                }
            }
            foreach (string language in languages) {
                if (broker.dict_exists(language) == 0) continue;
                unowned Enchant.Dict? dict = broker.request_dict(language);
                if (dict != null) dicts += dict;
            }
        }

        /** Returns `true` when `word` is spelled correctly or cannot be checked. */
        public bool check(string word) {
            if (dicts.length == 0 || word.length == 0) return true;
            foreach (unowned Enchant.Dict dict in dicts) {
                if (dict.check(word) == 0) return true;
            }
            return false;
        }

        /** Returns up to `limit` corrections for `word`, best first. */
        public string[] suggest(string word, int limit = 5) {
            string[] result = {};
            foreach (unowned Enchant.Dict dict in dicts) {
                foreach (unowned string suggestion in dict.suggest(word)) {
                    if (result.length >= limit) return result;
                    if (!(suggestion in result)) result += suggestion;
                }
            }
            return result;
        }

        /** Adds `word` to the personal dictionary of the first active language. */
        public void add_to_dictionary(string word) {
            if (dicts.length == 0) return;
            dicts[0].add(word);
            changed();
        }
    }
}
