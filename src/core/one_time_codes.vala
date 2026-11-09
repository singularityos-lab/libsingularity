namespace Singularity.OneTimeCodes {

    public class Match : Object {
        public string code { get; construct; }
        public string service { get; construct; }
        public string? domain { get; construct; }
        public string token { get; construct; }

        public Match(string code, string service, string? domain, string? token = null) {
            Object(code: code, service: service, domain: domain, token: token ?? code);
        }

        public string mask(string text) {
            string dots = string.nfill(code.length, '*').replace("*", "•");
            string result = text.replace(token, dots);
            if (token != code) result = result.replace(code, dots);
            return result;
        }
    }

    private const string[] KEYWORDS = {
        "verification code", "security code", "login code", "sign-in code", "sign in code",
        "confirmation code", "access code", "authentication code", "one-time", "one time",
        "passcode", "otp", "2fa", "pin", "code", "token",
        "codice", "verifica", "conferma", "accesso",
        "código", "codigo", "verificación", "verificacion", "verificação", "verificacao", "clave",
        "vérification", "verification", "mot de passe",
        "bestätigungscode", "sicherheitscode", "einmalcode", "tan", "kennwort",
        "verificatiecode", "inlogcode", "beveiligingscode",
        "kod", "weryfikac", "doğrulama", "dogrulama", "şifre", "sifre",
        "engångskod", "bekräftelsekod", "engangskode", "kertakäyttö", "vahvistuskoodi", "koodi",
        "код", "пароль", "підтвердження",
        "κωδικ", "קוד", "رمز", "كود", "कोड", "ओटीपी",
        "验证码", "驗證碼", "校验码", "校驗碼", "动态码", "動態碼", "确认码", "確認碼", "认证码",
        "認証コード", "確認コード", "認証番号", "確認番号", "ワンタイム", "コード",
        "인증번호", "인증 번호", "인증코드", "확인코드", "보안코드",
        "mã xác", "mã otp", "รหัส", "kode", "verifikasi"
    };

    private const string[] SERVICE_PATTERNS = {
        "^\\s*\\[([^\\]]{2,40})\\]",
        "^\\s*<#>\\s*([\\p{L}\\p{N}][\\p{L}\\p{N} .&'-]{1,38}?)\\s*:",
        "^\\s*([\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{1,30}(?: [\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{0,20}){0,2})\\s*:",
        "\\b(?i:your) ([\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{1,30}(?: [\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{0,20}){0,2}?) (?i:(?:verification |security |login |sign-in |confirmation |one-time |access )?(?:code|passcode|pin|otp|steam guard code))\\b",
        "\\b(?i:code|codice|código|codigo|kod|код|bestätigungscode|sicherheitscode)(?: \\S+)? (?i:for|per|para|pour|für|dla|для|de|di) ([\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{1,30}(?: [\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{0,20}){0,2})",
        "\\b(?i:accesso a|accedere a|access to|log in to|login to|sign in to|anmelden bei|connexion à|acceso a) ([\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{1,30}(?: [\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{0,20}){0,2})",
        "\\b(?i:from|von|od|от) ([\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{1,30}(?: [\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{0,20}){0,2})",
        "\\b(?i:il tuo codice|tu código|votre code|ihr code|twój kod|ваш код) ([\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{1,30}(?: [\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{0,20}){0,2})",
        "\\b(?i:as your|è il tuo codice|is your) ([\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{1,30}(?: [\\p{Lu}\\p{N}][\\p{L}\\p{N}.&'-]{0,20}){0,2}?) (?i:code|codice)"
    };

    private static Regex? candidate_re;
    private static Regex? web_otp_re;
    private static Regex? letter_prefix_re;
    private static Regex[]? service_res;

    private static void prepare() {
        if (candidate_re != null) return;
        try {
            candidate_re = new Regex("(?<![\\p{L}\\p{N}+#@/.,:$€£¥₹-])((?:[A-Z]-)?\\d{3,4}[ -]\\d{3,4}|(?:[A-Z]{1,3}-)?\\d{4,10}|[A-Z0-9]{4,10})(?![\\p{L}\\p{N}%€$£¥₹]|[.,/:]\\d)", RegexCompileFlags.OPTIMIZE);
            web_otp_re = new Regex("(?m)^\\s*@([a-z0-9.-]+\\.[a-z]{2,})\\s+#([A-Za-z0-9-]{4,12})(?:\\s+@([a-z0-9.-]+\\.[a-z]{2,}))?\\s*$", RegexCompileFlags.OPTIMIZE);
            letter_prefix_re = new Regex("^[A-Z]{1,3}-", RegexCompileFlags.OPTIMIZE);
            Regex[] list = {};
            foreach (string p in SERVICE_PATTERNS) list += new Regex(p, RegexCompileFlags.OPTIMIZE);
            service_res = list;
        } catch (RegexError e) {
            critical("%s", e.message);
        }
    }

    private static string normalize(string text) {
        return text.replace(" ", " ").replace(" ", " ").replace("\r", "");
    }

    private static int[] keyword_positions(string lower) {
        int[] found = {};
        foreach (string word in KEYWORDS) {
            int from = 0;
            while (true) {
                int at = lower.index_of(word, from);
                if (at < 0) break;
                bool ascii = word.get(0) < 0x80;
                bool left_ok = at == 0 || !ascii || !lower.get(at - 1).isalnum();
                int end = at + word.length;
                bool right_ok = !ascii || word.length > 4 || end >= lower.length || !lower.get(end).isalpha();
                if (left_ok && right_ok) {
                    found += at;
                    found += end;
                }
                from = at + word.length;
            }
        }
        return found;
    }

    private static bool looks_like_noise(string text, int start, int end, string token) {
        string digits = token.replace("-", "").replace(" ", "");
        if (letter_prefix_re.match(token)) digits = token.substring(token.index_of("-") + 1).replace(" ", "").replace("-", "");
        bool all_digits = true;
        int digit_count = 0;
        for (int i = 0; i < digits.length; i++) {
            if (digits[i].isdigit()) digit_count++;
            else all_digits = false;
        }
        if (digit_count == 0) return true;
        if (!all_digits) {
            if (digit_count < 2 || digits.length < 5) return true;
            bool has_upper = false;
            for (int i = 0; i < digits.length; i++) if (digits[i].isupper()) has_upper = true;
            if (!has_upper) return true;
        }
        if (all_digits && digits.length == 4) {
            int value = int.parse(digits);
            if (value >= 1900 && value <= 2099) {
                string around = text.substring(int.max(0, start - 12), int.min(text.length, end + 12) - int.max(0, start - 12)).down();
                if (!around.contains(":") && !around.contains("code") && !around.contains("codice") && !around.contains("pin")) return true;
            }
        }
        string before = text.substring(int.max(0, start - 3), start - int.max(0, start - 3));
        if (before.has_suffix("+") || before.has_suffix("tel ") || before.contains("€") || before.contains("$")) return true;
        string after = text.substring(end, int.min(text.length, end + 4) - end).strip().down();
        if (after.has_prefix("eur") || after.has_prefix("usd") || after.has_prefix("kg") || after.has_prefix("km")
                || after.has_prefix("min") || after.has_prefix("gb") || after.has_prefix("mb")) return true;
        return false;
    }

    private static string clean_code(string token) {
        string t = token;
        if (letter_prefix_re.match(t)) t = t.substring(t.index_of("-") + 1);
        return t.replace(" ", "").replace("-", "");
    }

    private static string? find_service(string text, string? fallback) {
        foreach (unowned Regex re in service_res) {
            MatchInfo info;
            if (re.match(text, 0, out info)) {
                string? name = info.fetch(1);
                if (name != null) {
                    name = name.strip();
                    string low = name.down();
                    if (name.length >= 2 && low != "your" && low != "the" && low != "il" && low != "code" && low != "codice"
                            && !low.has_prefix("verification") && !low.has_prefix("security")) return name;
                }
            }
        }
        if (fallback != null && fallback.strip() != "") return fallback.strip();
        return null;
    }

    public Match? find(string? title, string body, string? sender = null) {
        prepare();
        if (candidate_re == null) return null;
        string text = normalize(body);
        string head = normalize(title ?? "");

        MatchInfo web;
        if (web_otp_re.match(text, 0, out web)) {
            string domain = web.fetch(1);
            string? embedded = web.fetch(3);
            string service = find_service(text, null) ?? (head != "" ? head : domain);
            return new Match(web.fetch(2), service, embedded != null && embedded != "" ? embedded : domain, web.fetch(2));
        }

        string all = head != "" ? head + "\n" + text : text;
        string lower = all.down();
        int[] keys = keyword_positions(lower);
        if (keys.length == 0) return null;

        string? best = null;
        string? best_token = null;
        int best_score = int.MAX;
        MatchInfo info;
        try {
            candidate_re.match_full(all, -1, 0, 0, out info);
            while (info.matches()) {
                int start, end;
                info.fetch_pos(1, out start, out end);
                string token = info.fetch(1);
                if (!looks_like_noise(all, start, end, token)) {
                    int distance = int.MAX;
                    for (int i = 0; i < keys.length; i += 2) {
                        int d = keys[i + 1] <= start ? start - keys[i + 1] : (keys[i] >= end ? (keys[i] - end) * 2 + 4 : 0);
                        if (d < distance) distance = d;
                    }
                    string code = clean_code(token);
                    bool digits = true;
                    for (int i = 0; i < code.length; i++) if (!code[i].isdigit()) digits = false;
                    int score = distance + (digits ? 0 : 20) + (code.length >= 5 && code.length <= 8 ? 0 : 6);
                    if (distance <= 80 && score < best_score) {
                        best_score = score;
                        best = code;
                        best_token = token;
                    }
                }
                info.next();
            }
        } catch (RegexError e) {
            return null;
        }
        if (best == null) return null;
        string service = find_service(text, head != "" ? head : sender) ?? "";
        if (head != "" && service != head && service.down().contains(head.down())) service = head;
        return new Match(best, service, null, best_token);
    }

    public bool domain_matches(string host, string domain) {
        string h = host.down().strip();
        string d = domain.down().strip();
        if (h.has_prefix("www.")) h = h.substring(4);
        if (d.has_prefix("www.")) d = d.substring(4);
        return h == d || h.has_suffix("." + d);
    }
}
