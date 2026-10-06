namespace Singularity.Equations {

    public class AutoCorrect : Object {
        private const string[] DEFAULTS = {
            "\\above", "┴", "\\acute", "{0301}", "\\aleph", "ℵ", "\\alpha", "α", "\\Alpha", "Α", "\\amalg", "∐",
            "\\angle", "∠", "\\aoint", "∳", "\\approx", "≈", "\\asmash", "⬆", "\\ast", "∗", "\\asymp", "≍",
            "\\atop", "¦", "\\bar", "{0305}", "\\Bar", "{033f}", "\\because", "∵", "\\begin", "〖", "\\below", "┬",
            "\\bet", "ℶ", "\\beta", "β", "\\Beta", "Β", "\\beth", "ℶ", "\\bigcap", "⋂", "\\bigcup", "⋃",
            "\\bigodot", "⨀", "\\bigoplus", "⨁", "\\bigotimes", "⨂", "\\bigsqcup", "⨆", "\\biguplus", "⨄",
            "\\bigvee", "⋁", "\\bigwedge", "⋀", "\\bot", "⊥", "\\bowtie", "⋈", "\\box", "□", "\\bra", "⟨",
            "\\breve", "{0306}", "\\bullet", "∙", "\\cap", "∩", "\\cbrt", "∛", "\\cases", "Ⓒ", "\\cdot", "⋅",
            "\\cdots", "⋯", "\\check", "{030c}", "\\chi", "χ", "\\Chi", "Χ", "\\circ", "∘", "\\close", "┤",
            "\\clubsuit", "♣", "\\coint", "∲", "\\cong", "≅", "\\coprod", "∐", "\\cup", "∪", "\\dalet", "ℸ",
            "\\daleth", "ℸ", "\\dashv", "⊣", "\\dd", "ⅆ", "\\Dd", "ⅅ", "\\ddddot", "{20dc}", "\\dddot", "{20db}",
            "\\ddot", "{0308}", "\\ddots", "⋱", "\\defeq", "≝", "\\degc", "℃", "\\degf", "℉", "\\degree", "°",
            "\\delta", "δ", "\\Delta", "Δ", "\\Deltaeq", "≜", "\\diamond", "⋄", "\\diamondsuit", "♢", "\\div", "÷",
            "\\dot", "{0307}", "\\doteq", "≐", "\\dots", "…", "\\doublea", "𝕒", "\\doubleA", "𝔸", "\\doubleb", "𝕓",
            "\\doubleB", "𝔹", "\\doublec", "𝕔", "\\doubleC", "ℂ", "\\doubleN", "ℕ", "\\doubleQ", "ℚ", "\\doubleR", "ℝ",
            "\\doubleZ", "ℤ", "\\downarrow", "{2193}", "\\Downarrow", "{21d3}", "\\dsmash", "⬇", "\\ee", "ⅇ",
            "\\ell", "ℓ", "\\emptyset", "∅", "\\emsp", "{2003}", "\\end", "〗", "\\ensp", "{2002}", "\\epsilon", "ϵ",
            "\\Epsilon", "Ε", "\\eqarray", "█", "\\equiv", "≡", "\\eta", "η", "\\Eta", "Η", "\\exists", "∃",
            "\\forall", "∀", "\\fraktura", "𝔞", "\\frakturA", "𝔄", "\\frakturC", "ℭ", "\\frakturH", "ℌ", "\\frakturR", "ℜ",
            "\\frown", "⌑", "\\funcapply", "{2061}", "\\G", "Γ", "\\gamma", "γ", "\\Gamma", "Γ", "\\ge", "≥",
            "\\geq", "≥", "\\gets", "{2190}", "\\gg", "≫", "\\gimel", "ℷ", "\\grave", "{0300}", "\\hairsp", "{200a}",
            "\\hat", "{0302}", "\\hbar", "ℏ", "\\heartsuit", "♡", "\\hookleftarrow", "{21a9}", "\\hookrightarrow", "{21aa}",
            "\\hphantom", "⬄", "\\hsmash", "⬌", "\\hvec", "{20d1}", "\\identitymatrix", "(■(1&0&0@0&1&0@0&0&1))",
            "\\ii", "ⅈ", "\\iiiint", "⨌", "\\iiint", "∭", "\\iint", "∬", "\\Im", "ℑ", "\\imath", "ı", "\\in", "∈",
            "\\inc", "∆", "\\infty", "∞", "\\int", "∫",
            "\\integral", "1/2π ∫_0^2π▒ⅆθ/(a+b sin θ)=1/√(a^2-b^2)", "\\iota", "ι", "\\Iota", "Ι",
            "\\itimes", "{2062}", "\\j", "Jay", "\\jj", "ⅉ", "\\jmath", "ȷ", "\\kappa", "κ", "\\Kappa", "Κ", "\\ket", "⟩",
            "\\lambda", "λ", "\\Lambda", "Λ", "\\langle", "⟨", "\\lbbrack", "⟦", "\\lbrace", "{", "\\lbrack", "[",
            "\\lceil", "⌈", "\\ldiv", "∕", "\\ldivide", "∕", "\\ldots", "…", "\\le", "≤", "\\left", "├",
            "\\leftarrow", "{2190}", "\\Leftarrow", "{21d0}", "\\leftharpoondown", "{21bd}", "\\leftharpoonup", "{21bc}",
            "\\leftrightarrow", "{2194}", "\\Leftrightarrow", "{21d4}", "\\leq", "≤", "\\lfloor", "⌊", "\\lhvec", "{20d0}",
            "\\limit", "lim┬(n{2192}∞)⁡〖(1+1/n)^n〗=e", "\\ll", "≪", "\\lmoust", "⎰", "\\Longleftarrow", "{27f8}",
            "\\Longleftrightarrow", "{27fa}", "\\Longrightarrow", "{27f9}", "\\lrhar", "{21cb}", "\\lvec", "{20d6}",
            "\\mapsto", "{21a6}", "\\matrix", "■", "\\medsp", "{205f}", "\\mid", "∣", "\\middle", "ⓜ", "\\models", "⊨",
            "\\mp", "∓", "\\mu", "μ", "\\Mu", "Μ", "\\nabla", "∇", "\\naryand", "▒", "\\nbsp", "{00a0}", "\\ne", "≠",
            "\\nearrow", "{2197}", "\\neg", "¬", "\\neq", "≠", "\\ni", "∋", "\\norm", "‖", "\\notcontain", "∌",
            "\\notelement", "∉", "\\notin", "∉", "\\nu", "ν", "\\Nu", "Ν", "\\nwarrow", "{2196}", "\\o", "ο", "\\O", "Ο",
            "\\odot", "⊙", "\\of", "▒", "\\oiiint", "∰", "\\oiint", "∯", "\\oint", "∮", "\\omega", "ω", "\\Omega", "Ω",
            "\\ominus", "⊖", "\\open", "├", "\\oplus", "⊕", "\\otimes", "⊗", "\\over", "/", "\\overbar", "¯",
            "\\overbrace", "⏞", "\\overbracket", "⎴", "\\overline", "¯", "\\overparen", "⏜", "\\overshell", "⏠",
            "\\parallel", "∥", "\\partial", "∂", "\\pmatrix", "⒨", "\\perp", "⊥", "\\phantom", "⟡", "\\phi", "ϕ",
            "\\Phi", "Φ", "\\pi", "π", "\\Pi", "Π", "\\pm", "±", "\\pppprime", "⁗", "\\ppprime", "‴", "\\pprime", "″",
            "\\prec", "≺", "\\preceq", "≼", "\\prime", "′", "\\prod", "∏", "\\propto", "∝", "\\psi", "ψ", "\\Psi", "Ψ",
            "\\qdrt", "∜", "\\quadratic", "x=(-b±√(b^2-4ac))/2a", "\\rangle", "⟩", "\\Rangle", "⟫", "\\ratio", "∶",
            "\\rbrace", "}", "\\rbrack", "]", "\\Rbrack", "⟧", "\\rceil", "⌉", "\\rddots", "⋰", "\\Re", "ℜ",
            "\\rect", "▭", "\\rfloor", "⌋", "\\rho", "ρ", "\\Rho", "Ρ", "\\rhvec", "{20d1}", "\\right", "┤",
            "\\rightarrow", "{2192}", "\\Rightarrow", "{21d2}", "\\rightharpoondown", "{21c1}", "\\rightharpoonup", "{21c0}",
            "\\rmoust", "⎱", "\\root", "⒭", "\\scripta", "𝒶", "\\scriptA", "𝒜", "\\scriptB", "ℬ", "\\scriptE", "ℰ",
            "\\scriptF", "ℱ", "\\scriptH", "ℋ", "\\scriptI", "ℐ", "\\scriptL", "ℒ", "\\scriptM", "ℳ", "\\scriptR", "ℛ",
            "\\sdiv", "⁄", "\\sdivide", "⁄", "\\searrow", "{2198}", "\\setminus", "∖", "\\sigma", "σ", "\\Sigma", "Σ",
            "\\sim", "∼", "\\simeq", "≃", "\\smash", "⬍", "\\smile", "⌣", "\\spadesuit", "♠", "\\sqcap", "⊓",
            "\\sqcup", "⊔", "\\sqrt", "√", "\\sqsubseteq", "⊑", "\\sqsuperseteq", "⊒", "\\star", "⋆", "\\subset", "⊂",
            "\\subseteq", "⊆", "\\succ", "≻", "\\succeq", "≽", "\\sum", "∑", "\\superset", "⊃", "\\superseteq", "⊇",
            "\\swarrow", "{2199}", "\\tau", "τ", "\\Tau", "Τ", "\\therefore", "∴", "\\theta", "θ", "\\Theta", "Θ",
            "\\thicksp", "{2005}", "\\thinsp", "{2006}", "\\tilde", "{0303}", "\\times", "×", "\\to", "{2192}",
            "\\top", "⊤", "\\tvec", "{20e1}", "\\ubar", "{0332}", "\\Ubar", "{0333}", "\\underbar", "▁",
            "\\underbrace", "⏟", "\\underbracket", "⎵", "\\underline", "▁", "\\underparen", "⏝", "\\uparrow", "{2191}",
            "\\Uparrow", "{21d1}", "\\updownarrow", "{2195}", "\\Updownarrow", "{21d5}", "\\uplus", "⊎",
            "\\upsilon", "υ", "\\Upsilon", "Υ", "\\varepsilon", "ε", "\\varphi", "φ", "\\varpi", "ϖ", "\\varrho", "ϱ",
            "\\varsigma", "ς", "\\vartheta", "ϑ", "\\vbar", "│", "\\vdash", "⊢", "\\vdots", "⋮", "\\vec", "{20d7}",
            "\\vee", "∨", "\\vert", "|", "\\Vert", "‖", "\\vphantom", "⇳", "\\vthicksp", "{2004}", "\\wedge", "∧",
            "\\wp", "℘", "\\wr", "≀", "\\xi", "ξ", "\\Xi", "Ξ", "\\zeta", "ζ", "\\Zeta", "Ζ", "\\zwnj", "{200c}",
            "\\zwsp", "{200b}", "~=", "≅", "-+", "∓", "+-", "±", "<<", "≪", "<=", "≤", "->", "{2192}", ">=", "≥",
            ">>", "≫", "!=", "≠", "=>", "{21d2}", "<-", "{2190}", "<->", "{2194}", "==", "≡", ":=", "≔", "...", "…"
        };

        private const string[] DEFAULT_FUNCTIONS = {
            "arccos", "arccosh", "arccot", "arccoth", "arccsc", "arccsch", "arcsec", "arcsech", "arcsin", "arcsinh",
            "arctan", "arctanh", "arg", "cos", "cosh", "cot", "coth", "csc", "csch", "def", "deg", "det", "dim", "exp",
            "gcd", "hom", "inf", "ker", "lg", "lim", "liminf", "limsup", "ln", "log", "max", "min", "mod", "Pr", "sec",
            "sech", "sin", "sinh", "sup", "tan", "tanh"
        };

        private static AutoCorrect? instance;
        private Gee.TreeMap<string, string> defaults = new Gee.TreeMap<string, string>();
        private Gee.TreeMap<string, string> entries = new Gee.TreeMap<string, string>();
        private Gee.TreeSet<string> functions_set = new Gee.TreeSet<string>();
        private FileMonitor? monitor;
        private bool saving;

        public bool replace_outside_math { get; set; default = false; }
        public bool enabled { get; set; default = true; }
        public string path { get; construct; }

        public signal void changed();

        public AutoCorrect(string path) {
            Object(path: path);
            for (int i = 0; i + 1 < DEFAULTS.length; i += 2) defaults[DEFAULTS[i]] = decode(DEFAULTS[i + 1]);
            load();
        }

        public static AutoCorrect get_default() {
            if (instance == null) {
                instance = new AutoCorrect(default_path());
                instance.watch();
            }
            return instance;
        }

        public static string default_path() {
            string? over = Environment.get_variable("SINGULARITY_MATH_AUTOCORRECT");
            if (over != null && over != "") return over;
            return Path.build_filename(Environment.get_user_config_dir(), "singularity", "math-autocorrect.json");
        }

        public static string decode(string value) {
            if (!value.contains("{")) return value;
            var sb = new StringBuilder();
            int i = 0;
            while (i < value.length) {
                if (value[i] == '{') {
                    int close = value.index_of_char('}', i);
                    if (close > i + 1 && close - i <= 7) {
                        string code = value.substring(i + 1, close - i - 1);
                        bool hexcode = true;
                        for (int k = 0; k < code.length; k++) if (!code[k].isxdigit()) hexcode = false;
                        if (hexcode && code.length >= 4) {
                            sb.append(MathXml.hex(code));
                            i = close + 1;
                            continue;
                        }
                    }
                }
                sb.append_c(value[i]);
                i++;
            }
            return sb.str;
        }

        public Gee.List<string> keys() {
            var list = new Gee.ArrayList<string>();
            list.add_all(entries.keys);
            return list;
        }

        public string? lookup(string key) {
            if (!enabled) return null;
            return entries[key];
        }

        public bool is_default(string key) {
            return defaults.has_key(key) && entries.has_key(key) && defaults[key] == entries[key];
        }

        public bool is_custom(string key) {
            return entries.has_key(key) && !is_default(key);
        }

        public string? replace_word(string word) {
            if (!enabled) return null;
            if (!word.has_prefix("\\") && word.length < 2) return null;
            return entries[word];
        }

        public Gee.List<string> operator_keys() {
            var list = new Gee.ArrayList<string>();
            foreach (var k in entries.keys) if (!k.has_prefix("\\")) list.add(k);
            list.sort((a, b) => b.length - a.length);
            return list;
        }

        public void set_entry(string key, string replacement) {
            string k = key.strip();
            if (k == "") return;
            entries[k] = replacement;
            changed();
        }

        public void remove_entry(string key) {
            if (entries.unset(key)) changed();
        }

        public Gee.List<string> functions() {
            var list = new Gee.ArrayList<string>();
            list.add_all(functions_set);
            return list;
        }

        public bool is_function(string name) {
            return functions_set.contains(name);
        }

        public bool is_default_function(string name) {
            foreach (var f in DEFAULT_FUNCTIONS) if (f == name) return true;
            return false;
        }

        public void add_function(string name) {
            string n = name.strip();
            if (n == "" || functions_set.contains(n)) return;
            functions_set.add(n);
            changed();
        }

        public void remove_function(string name) {
            if (functions_set.remove(name)) changed();
        }

        public void reset() {
            entries.clear();
            foreach (var e in defaults.entries) entries[e.key] = e.value;
            functions_set.clear();
            foreach (var f in DEFAULT_FUNCTIONS) functions_set.add(f);
            replace_outside_math = false;
            enabled = true;
            changed();
        }

        private void load() {
            entries.clear();
            foreach (var e in defaults.entries) entries[e.key] = e.value;
            functions_set.clear();
            foreach (var f in DEFAULT_FUNCTIONS) functions_set.add(f);
            if (!FileUtils.test(path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var o = root.get_object();
                if (o.has_member("replace-outside-math")) replace_outside_math = o.get_boolean_member("replace-outside-math");
                if (o.has_member("enabled")) enabled = o.get_boolean_member("enabled");
                if (o.has_member("added")) {
                    var added = o.get_object_member("added");
                    foreach (var k in added.get_members()) entries[k] = added.get_string_member(k);
                }
                if (o.has_member("removed")) {
                    foreach (var n in o.get_array_member("removed").get_elements()) entries.unset(n.get_string());
                }
                if (o.has_member("functions-added")) {
                    foreach (var n in o.get_array_member("functions-added").get_elements()) functions_set.add(n.get_string());
                }
                if (o.has_member("functions-removed")) {
                    foreach (var n in o.get_array_member("functions-removed").get_elements()) functions_set.remove(n.get_string());
                }
            } catch (Error e) {
                warning("math autocorrect: %s", e.message);
            }
        }

        public void save() throws Error {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("version");
            b.add_int_value(1);
            b.set_member_name("enabled");
            b.add_boolean_value(enabled);
            b.set_member_name("replace-outside-math");
            b.add_boolean_value(replace_outside_math);
            b.set_member_name("added");
            b.begin_object();
            foreach (var e in entries.entries) {
                if (defaults.has_key(e.key) && defaults[e.key] == e.value) continue;
                b.set_member_name(e.key);
                b.add_string_value(e.value);
            }
            b.end_object();
            b.set_member_name("removed");
            b.begin_array();
            foreach (var k in defaults.keys) if (!entries.has_key(k)) b.add_string_value(k);
            b.end_array();
            b.set_member_name("functions-added");
            b.begin_array();
            foreach (var f in functions_set) if (!is_default_function(f)) b.add_string_value(f);
            b.end_array();
            b.set_member_name("functions-removed");
            b.begin_array();
            foreach (var f in DEFAULT_FUNCTIONS) if (!functions_set.contains(f)) b.add_string_value(f);
            b.end_array();
            b.end_object();
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(b.get_root());
            string dir = Path.get_dirname(path);
            DirUtils.create_with_parents(dir, 0700);
            saving = true;
            FileUtils.set_contents(path, gen.to_data(null));
            Timeout.add(400, () => {
                saving = false;
                return Source.REMOVE;
            });
        }

        private void watch() {
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                monitor = File.new_for_path(path).monitor_file(FileMonitorFlags.NONE, null);
                monitor.changed.connect((f, other, ev) => {
                    if (saving) return;
                    if (ev != FileMonitorEvent.CHANGES_DONE_HINT && ev != FileMonitorEvent.DELETED && ev != FileMonitorEvent.CREATED) return;
                    load();
                    changed();
                });
            } catch (Error e) {
                monitor = null;
            }
        }
    }
}
