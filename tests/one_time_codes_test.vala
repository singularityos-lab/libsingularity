using Singularity;

struct Case {
    string? title;
    string body;
    string? code;
    string? service;
    string? domain;
}

const Case[] CASES = {
    { "Banca X", "Il tuo codice di accesso è 482913. Non condividerlo con nessuno.", "482913", "Banca X", null },
    { null, "G-582014 is your Google verification code.", "582014", "Google", null },
    { "Amazon", "123456 is your Amazon OTP. Do not share it with anyone.", "123456", "Amazon", null },
    { null, "[Revolut] Your verification code is 834 221", "834221", "Revolut", null },
    { null, "Your code is 739204\n\n@shop.example.com #739204", "739204", null, "shop.example.com" },
    { "PayPal", "PayPal: Your security code is: 618473. Your code expires in 10 minutes.", "618473", "PayPal", null },
    { null, "Tu código de verificación de WhatsApp es 271-940", "271940", null, null },
    { null, "Votre code de vérification Microsoft est 9154", "9154", null, null },
    { null, "Ihr Bestätigungscode für Sparkasse lautet 551203", "551203", "Sparkasse", null },
    { null, "Twój kod weryfikacyjny to 402918", "402918", null, null },
    { null, "Ваш код подтверждения: 774512", "774512", null, null },
    { null, "【淘宝】验证码 482931，5分钟内有效，请勿泄露。", "482931", null, null },
    { null, "認証コード：610482 このコードを他人に教えないでください。", "610482", null, null },
    { null, "[네이버] 인증번호 [583920]를 입력해주세요.", "583920", "네이버", null },
    { "Steam", "Your Steam Guard code is F7K2Q", "F7K2Q", "Steam", null },
    { "Mamma", "Ci vediamo alle 18:30 al solito posto, porta 20 euro", null, null, null },
    { "Corriere", "Il pacco 482913 arriverà il 12/11/2026 tra le 9 e le 13", null, null, null },
    { null, "Hai speso 1250 EUR con la carta che termina con 4421", null, null, null },
    { null, "Chiamami al +39 347 1234567 quando puoi", null, null, null },
    { null, "Meeting moved to 2026, see you in room 214", null, null, null },
    { "Lettere", "Your Dropbox code is 381 006. Enter it to finish signing in.", "381006", "Dropbox", null },
    { null, "Codice OTP per accesso a Poste Italiane: 74019252. Valido 5 minuti.", "74019252", "Poste Italiane", null },
    { null, "Use 4821 as your Uber code", "4821", null, null },
    { null, "<#> Telegram: Il tuo codice è 70125\nq2Wsd/lQaxS", "70125", "Telegram", null }
};

static void test_cases() {
    int i = 0;
    foreach (unowned Case c in CASES) {
        var m = OneTimeCodes.find(c.title, c.body, null);
        if (c.code == null) {
            if (m != null) error("case %d: expected no code in '%s', got %s", i, c.body, m.code);
        } else {
            if (m == null) error("case %d: no code found in '%s'", i, c.body);
            if (m.code != c.code) error("case %d: expected %s, got %s in '%s'", i, c.code, m.code, c.body);
            if (c.service != null && m.service != c.service) error("case %d: expected service '%s', got '%s'", i, c.service, m.service);
            if (c.domain != null && m.domain != c.domain) error("case %d: expected domain %s, got %s", i, c.domain, m.domain ?? "(none)");
        }
        i++;
    }
}

static void test_mask() {
    var m = OneTimeCodes.find(null, "[Revolut] Your verification code is 834 221", null);
    assert(m.token == "834 221");
    assert(m.mask("[Revolut] Your verification code is 834 221") == "[Revolut] Your verification code is ••••••");
    var g = OneTimeCodes.find(null, "G-582014 is your Google verification code.", null);
    assert(!g.mask("G-582014 is your Google verification code.").contains("582014"));
}

static void test_domain_matches() {
    assert(OneTimeCodes.domain_matches("shop.example.com", "example.com"));
    assert(OneTimeCodes.domain_matches("www.example.com", "example.com"));
    assert(OneTimeCodes.domain_matches("EXAMPLE.com", "example.com"));
    assert(!OneTimeCodes.domain_matches("example.com.evil.net", "example.com"));
    assert(!OneTimeCodes.domain_matches("notexample.com", "example.com"));
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/one-time-codes/cases", test_cases);
    Test.add_func("/one-time-codes/domain", test_domain_matches);
    Test.add_func("/one-time-codes/mask", test_mask);
    return Test.run();
}
