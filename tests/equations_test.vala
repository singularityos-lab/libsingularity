using Singularity.Equations;

string fixtures;
int failures = 0;
int passed = 0;

void check(bool ok, string what) {
    if (ok) {
        passed++;
    } else {
        failures++;
        stderr.printf("FAIL: %s\n", what);
    }
}

void check_eq(string got, string want, string what) {
    if (got == want) {
        passed++;
    } else {
        failures++;
        stderr.printf("FAIL: %s\n  got:  %s\n  want: %s\n", what, got, want);
    }
}

string rarrow() {
    return MathXml.uc(0x2192);
}

void flat_kids(MathNode n, Gee.ArrayList<MathNode> out_list) {
    foreach (var c in n.children) {
        if (c.local == "mrow" && !(c.children.size > 0 && c.children[0].attr("fence") == "true")) flat_kids(c, out_list);
        else out_list.add(c);
    }
}

string shape(MathNode n) {
    var sb = new StringBuilder(n.local);
    var kids = new Gee.ArrayList<MathNode>();
    flat_kids(n, kids);
    if (kids.size > 0) {
        sb.append("(");
        for (int i = 0; i < kids.size; i++) {
            if (i > 0) sb.append(" ");
            sb.append(shape(kids[i]));
        }
        sb.append(")");
    } else if (n.text.strip() != "") {
        sb.append(":").append(n.text.strip());
    }
    return sb.str;
}

string mml_shape(string mathml) {
    var root = MathXml.parse(mathml);
    return root != null ? shape(root) : "";
}

const string M = "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"block\">";

void test_xml() {
    var n = MathXml.parse("<math><mi>x</mi><mo>&InvisibleTimes;</mo><mo>&lt;</mo><mtext>a&amp;b</mtext></math>");
    check(n != null && n.children.size == 4, "xml parses children");
    check_eq(n.children[1].text, MathXml.uc(0x2062), "named entity decoded");
    check_eq(n.children[2].text, "<", "lt entity");
    check_eq(n.children[3].text, "a&b", "amp entity");
    check_eq(n.to_xml(), "<math><mi>x</mi><mo>" + MathXml.uc(0x2062) + "</mo><mo>&lt;</mo><mtext>a&amp;b</mtext></math>", "xml serializes");
    var p = MathXml.parse("<m:oMath xmlns:m=\"x\"><m:r><m:t>a</m:t></m:r></m:oMath>");
    check(p != null && p.local == "oMath" && p.prefix == "m", "prefixed names");
}

void test_to_omml() {
    string frac = Omml.from_mathml(M + "<mfrac><mi>a</mi><mi>b</mi></mfrac></math>", true);
    check(frac.has_prefix("<m:oMathPara"), "display gives oMathPara");
    check(frac.contains("<m:jc m:val=\"centerGroup\"/>"), "justification written");
    check(frac.contains("<m:f><m:num><m:r><m:t>a</m:t></m:r></m:num><m:den><m:r><m:t>b</m:t></m:r></m:den></m:f>"), "fraction: " + frac);

    string inl = Omml.from_mathml(M + "<msup><mi>x</mi><mn>2</mn></msup></math>", false);
    check(inl.has_prefix("<m:oMath xmlns:m="), "inline gives oMath");
    check(inl.contains("<m:sSup><m:e><m:r><m:t>x</m:t></m:r></m:e><m:sup><m:r><m:t>2</m:t></m:r></m:sup></m:sSup>"), "superscript: " + inl);

    string sum = Omml.from_mathml(M + "<munderover><mo>∑</mo><mrow><mi>i</mi><mo>=</mo><mn>1</mn></mrow><mi>n</mi></munderover><msub><mi>a</mi><mi>i</mi></msub><mo>=</mo><mi>S</mi></math>", true);
    check(sum.contains("<m:nary><m:naryPr><m:chr m:val=\"∑\"/><m:limLoc m:val=\"undOvr\"/></m:naryPr>"), "nary props: " + sum);
    check(sum.contains("<m:e><m:sSub>"), "nary body is the summand");
    check(sum.contains("</m:nary><m:r><m:t>=</m:t></m:r>"), "nary body stops at relation");

    string integ = Omml.from_mathml(M + "<msubsup><mo>∫</mo><mn>0</mn><mn>1</mn></msubsup><mi>f</mi><mi>d</mi><mi>x</mi></math>", true);
    check(integ.contains("<m:limLoc m:val=\"subSup\"/>"), "integral limits at the side");

    string apply = MathXml.uc(0x2061);
    string fn = Omml.from_mathml(M + "<mi>sin</mi><mo>" + apply + "</mo><mi>x</mi></math>", false);
    check(fn.contains("<m:func><m:fName><m:r><m:rPr><m:sty m:val=\"p\"/></m:rPr><m:t>sin</m:t></m:r></m:fName><m:e><m:r><m:t>x</m:t></m:r></m:e></m:func>"), "function: " + fn);

    string lim = Omml.from_mathml(M + "<munder><mi>lim</mi><mrow><mi>x</mi><mo>" + rarrow() + "</mo><mn>0</mn></mrow></munder><mo>" + apply + "</mo><mi>f</mi></math>", true);
    check(lim.contains("<m:func><m:fName><m:limLow>"), "lim is a function with limLow: " + lim);

    string d = Omml.from_mathml(M + "<mrow><mo fence=\"true\" form=\"prefix\">[</mo><mi>x</mi><mo fence=\"true\" form=\"postfix\">]</mo></mrow></math>", true);
    check(d.contains("<m:d><m:dPr><m:begChr m:val=\"[\"/><m:endChr m:val=\"]\"/></m:dPr><m:e><m:r><m:t>x</m:t></m:r></m:e></m:d>"), "delimiters: " + d);

    string mat = Omml.from_mathml(M + "<mrow><mo fence=\"true\">(</mo><mtable><mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr><mtr><mtd><mi>c</mi></mtd><mtd><mi>d</mi></mtd></mtr></mtable><mo fence=\"true\">)</mo></mrow></math>", true);
    check(mat.contains("<m:d><m:e><m:m><m:mPr><m:mcs><m:mc><m:mcPr><m:count m:val=\"2\"/><m:mcJc m:val=\"center\"/></m:mcPr></m:mc></m:mcs></m:mPr><m:mr>"), "matrix: " + mat);

    string al = Omml.from_mathml(M + "<mtable columnalign=\"right left\" displaystyle=\"true\"><mlabeledtr><mtd><mtext>(1)</mtext></mtd><mtd><mi>a</mi></mtd><mtd><mo>=</mo><mi>b</mi></mtd></mlabeledtr></mtable></math>", true);
    check(al.contains("<m:eqArr><m:e><m:r><m:t>a</m:t></m:r><m:r><m:t>&amp;</m:t></m:r><m:r><m:t>=</m:t></m:r>"), "aligned eqArr: " + al);
    check(al.contains("<m:t>#</m:t></m:r><m:r><m:rPr><m:nor/></m:rPr><m:t>(1)</m:t>"), "equation number: " + al);

    string box = Omml.from_mathml(M + "<menclose notation=\"top bottom horizontalstrike\"><mi>x</mi></menclose></math>", true);
    check(box.contains("<m:borderBox><m:borderBoxPr><m:hideLeft m:val=\"1\"/><m:hideRight m:val=\"1\"/><m:strikeH m:val=\"1\"/></m:borderBoxPr>"), "border box sides: " + box);

    string acc = Omml.from_mathml(M + "<mover accent=\"true\"><mi>x</mi><mo>^</mo></mover><mover><mi>y</mi><mo>" + MathXml.uc(0x203e) + "</mo></mover><munder><mrow><mi>a</mi></mrow><mo>" + MathXml.uc(0x23df) + "</mo></munder></math>", true);
    check(acc.contains("<m:acc><m:accPr><m:chr m:val=\"" + MathXml.uc(0x0302) + "\"/></m:accPr>"), "accent combining: " + acc);
    check(acc.contains("<m:bar><m:barPr><m:pos m:val=\"top\"/></m:barPr>"), "overline is a bar");
    check(acc.contains("<m:groupChr><m:groupChrPr><m:chr m:val=\"" + MathXml.uc(0x23df) + "\"/><m:pos m:val=\"bot\"/>"), "underbrace is a group character");

    string pre = Omml.from_mathml(M + "<mmultiscripts><mi>C</mi><mprescripts/><mn>6</mn><mn>14</mn></mmultiscripts></math>", true);
    check(pre.contains("<m:sPre><m:sub><m:r><m:t>6</m:t></m:r></m:sub><m:sup><m:r><m:t>14</m:t></m:r></m:sup><m:e><m:r><m:t>C</m:t></m:r></m:e></m:sPre>"), "left scripts: " + pre);

    string col = Omml.from_mathml(M + "<mstyle mathcolor=\"#ff0000\"><mi>x</mi></mstyle></math>", false);
    check(col.contains("<w:rPr><w:color w:val=\"FF0000\"/></w:rPr>"), "color: " + col);

    string html = Omml.from_mathml(M + "<mi>x</mi></math>", false, Justification.CENTER_GROUP, true);
    check(html.contains("<m:r>x</m:r>") && html.contains(Omml.HTML_NS), "html flavor runs: " + html);

    string sty = Omml.from_mathml(M + "<mi mathvariant=\"double-struck\">R</mi><mi mathvariant=\"bold\">F</mi><mtext>if</mtext></math>", false);
    check(sty.contains("<m:scr m:val=\"double-struck\"/><m:sty m:val=\"p\"/>"), "double struck");
    check(sty.contains("<m:sty m:val=\"b\"/>"), "bold");
    check(sty.contains("<m:rPr><m:nor/></m:rPr><m:t>if</m:t>"), "normal text");
}

void test_from_omml() {
    bool disp;
    Justification jc;
    string mml = Omml.to_mathml("<m:oMathPara><m:oMathParaPr><m:jc m:val=\"left\"/></m:oMathParaPr><m:oMath><m:f><m:fPr><m:type m:val=\"noBar\"/></m:fPr><m:num><m:r><m:t>n</m:t></m:r></m:num><m:den><m:r><m:t>k</m:t></m:r></m:den></m:f></m:oMath></m:oMathPara>", out disp, out jc);
    check(disp, "para is display");
    check(jc == Justification.LEFT, "jc read");
    check(mml.contains("<mfrac linethickness=\"0\"><mi>n</mi><mi>k</mi></mfrac>"), "noBar fraction: " + mml);

    mml = Omml.to_mathml("<m:oMath><m:nary><m:naryPr><m:chr m:val=\"∑\"/><m:limLoc m:val=\"undOvr\"/></m:naryPr><m:sub><m:r><m:t>i=1</m:t></m:r></m:sub><m:sup><m:r><m:t>n</m:t></m:r></m:sup><m:e><m:r><m:t>i</m:t></m:r></m:e></m:nary></m:oMath>", out disp, out jc);
    check(!disp, "bare oMath is inline");
    check(mml.contains("<munderover><mo>∑</mo><mrow><mi>i</mi><mo>=</mo><mn>1</mn></mrow><mi>n</mi></munderover><mi>i</mi>"), "nary read: " + mml);

    mml = Omml.to_mathml("<m:oMath><m:nary><m:e><m:r><m:t>f</m:t></m:r></m:e></m:nary></m:oMath>", out disp, out jc);
    check(mml.contains("<mo>∫</mo><mi>f</mi>"), "nary defaults to integral: " + mml);

    mml = Omml.to_mathml("<m:oMath><m:d><m:dPr><m:begChr m:val=\"|\"/><m:endChr m:val=\"|\"/></m:dPr><m:e><m:r><m:t>x</m:t></m:r></m:e></m:d><m:func><m:fName><m:r><m:rPr><m:sty m:val=\"p\"/></m:rPr><m:t>sin</m:t></m:r></m:fName><m:e><m:r><m:t>θ</m:t></m:r></m:e></m:func></m:oMath>", out disp, out jc);
    check(mml.contains("<mrow><mo fence=\"true\" form=\"prefix\">|</mo><mi>x</mi><mo fence=\"true\" form=\"postfix\">|</mo></mrow>"), "delimiter read: " + mml);
    check(mml.contains("<mi>sin</mi><mo>" + MathXml.uc(0x2061) + "</mo><mi>θ</mi>"), "function read: " + mml);

    mml = Omml.to_mathml("<m:oMathPara><m:oMath><m:eqArr><m:e><m:r><m:t>a&amp;=b#(1)</m:t></m:r></m:e><m:e><m:r><m:t>c&amp;=d</m:t></m:r></m:e></m:eqArr></m:oMath></m:oMathPara>", out disp, out jc);
    check(mml.contains("<mtable columnalign=\"right left\" displaystyle=\"true\"><mlabeledtr><mtd><mtext>(1)</mtext></mtd><mtd><mi>a</mi></mtd><mtd><mo>=</mo><mi>b</mi></mtd></mlabeledtr>"), "eqArr read: " + mml);

    mml = Omml.to_mathml("<m:oMath><m:borderBox><m:borderBoxPr><m:hideTop m:val=\"1\"/><m:strikeBLTR m:val=\"1\"/></m:borderBoxPr><m:e><m:r><m:t>x</m:t></m:r></m:e></m:borderBox><m:sPre><m:sub><m:r><m:t>6</m:t></m:r></m:sub><m:sup><m:r><m:t>14</m:t></m:r></m:sup><m:e><m:r><m:t>C</m:t></m:r></m:e></m:sPre></m:oMath>", out disp, out jc);
    check(mml.contains("<menclose notation=\"bottom left right updiagonalstrike\"><mi>x</mi></menclose>"), "border box read: " + mml);
    check(mml.contains("<mmultiscripts><mi>C</mi><mprescripts/><mn>6</mn><mn>14</mn></mmultiscripts>"), "sPre read: " + mml);

    mml = Omml.to_mathml("<m:oMath><m:acc><m:accPr><m:chr m:val=\"" + MathXml.uc(0x0303) + "\"/></m:accPr><m:e><m:r><m:t>z</m:t></m:r></m:e></m:acc><m:bar><m:e><m:r><m:t>w</m:t></m:r></m:e></m:bar><m:groupChr><m:e><m:r><m:t>q</m:t></m:r></m:e></m:groupChr></m:oMath>", out disp, out jc);
    check(mml.contains("<mover accent=\"true\"><mi>z</mi><mo stretchy=\"false\">~</mo></mover>"), "accent read: " + mml);
    check(mml.contains("<munder accentunder=\"true\"><mi>w</mi><mo stretchy=\"true\">_</mo></munder>"), "bar defaults to bottom: " + mml);
    check(mml.contains("<munder><mi>q</mi><mo stretchy=\"true\">" + MathXml.uc(0x23df) + "</mo></munder>"), "group char defaults to under brace: " + mml);

    mml = Omml.to_mathml("<m:oMath><m:r><m:rPr><m:scr m:val=\"double-struck\"/><m:sty m:val=\"p\"/></m:rPr><m:t>R</m:t></m:r><m:r><m:rPr><m:nor/></m:rPr><m:t>for all</m:t></m:r><m:r><w:rPr><w:color w:val=\"FF0000\"/></w:rPr><m:t>x</m:t></m:r><m:r><m:t>12.5</m:t></m:r></m:oMath>", out disp, out jc);
    check(mml.contains("<mi mathvariant=\"double-struck\">R</mi>"), "script read: " + mml);
    check(mml.contains("<mtext>for all</mtext>"), "normal text read");
    check(mml.contains("<mstyle mathcolor=\"#FF0000\"><mi>x</mi></mstyle>"), "color read");
    check(mml.contains("<mn>12.5</mn>"), "decimal number");

    mml = Omml.to_mathml("<m:oMath xmlns:m=\"http://schemas.microsoft.com/office/2004/12/omml\"><m:sSup><m:e><m:r>x</m:r></m:e><m:sup><m:r>2</m:r></m:sup></m:sSup></m:oMath>", out disp, out jc);
    check(mml.contains("<msup><mi>x</mi><mn>2</mn></msup>"), "html flavor read: " + mml);
}

void collect_math(MathNode n, Gee.ArrayList<MathNode> list) {
    if (n.local == "oMathPara" || n.local == "oMath") {
        list.add(n);
        return;
    }
    foreach (var c in n.children) collect_math(c, list);
}

void test_fixture_roundtrip() {
    string xml;
    try {
        FileUtils.get_contents(Path.build_filename(fixtures, "pandoc-document.xml"), out xml);
    } catch (Error e) {
        check(false, "fixture: " + e.message);
        return;
    }
    var doc = MathXml.parse(xml);
    check(doc != null, "document.xml parses");
    var list = new Gee.ArrayList<MathNode>();
    collect_math(doc, list);
    check(list.size == 12, "12 equations found in the Word document, got %d".printf(list.size));
    string[] expect = { "msup", "mroot", "mfrac", "munderover", "msubsup", "munder", "mtable", "mtable", "mover", "menclose", "msqrt", "mtable" };
    int inline_count = 0;
    for (int i = 0; i < list.size && i < expect.length; i++) {
        var m = list[i];
        var eq = Equation.from_omml(m.to_xml());
        check(eq != null, "equation %d converts".printf(i));
        if (eq == null) continue;
        if (!eq.display) inline_count++;
        string mml = eq.mathml;
        check(mml.contains("<" + expect[i]), "equation %d has %s: %s".printf(i, expect[i], mml));
        string omml = eq.to_omml();
        var back = Equation.from_omml(omml);
        check(back != null, "equation %d re-reads".printf(i));
        if (back == null) continue;
        check_eq(mml_shape(back.mathml), mml_shape(mml), "equation %d stable through OMML".printf(i));
        check(back.display == eq.display, "equation %d keeps display".printf(i));
    }
    check(inline_count == 2, "two inline equations, got %d".printf(inline_count));
}

void test_speech() {
    check_eq(Speech.describe(M + "<msup><mi>x</mi><mn>2</mn></msup><mo>+</mo><msup><mi>y</mi><mn>2</mn></msup><mo>=</mo><msup><mi>r</mi><mn>2</mn></msup></math>"),
        "x squared plus y squared equals r squared", "pythagoras speech");
    check_eq(Speech.describe(M + "<mfrac><mrow><mi>a</mi><mo>+</mo><mn>1</mn></mrow><mi>b</mi></mfrac></math>"),
        "fraction, a plus 1, over, b, end fraction", "fraction speech");
    check_eq(Speech.describe(M + "<munderover><mo>∑</mo><mrow><mi>i</mi><mo>=</mo><mn>1</mn></mrow><mi>n</mi></munderover><mi>i</mi></math>"),
        "sum from i equals 1 to n of i", "sum speech");
    check_eq(Speech.describe(M + "<msqrt><mi>x</mi></msqrt><mo>≠</mo><mi>π</mi></math>"),
        "square root of x is not equal to pi", "root speech");
    check_eq(Speech.describe(M + "<mrow><mo>|</mo><mi>x</mi><mo>|</mo></mrow></math>"),
        "absolute value of x, end absolute value", "abs speech");
    check_eq(Speech.describe(M + "<munder><mi>lim</mi><mrow><mi>x</mi><mo>" + rarrow() + "</mo><mn>0</mn></mrow></munder><mi>f</mi></math>"),
        "limit as x tends to 0 of f", "limit speech");
    check(Speech.describe(M + "<mtable><mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr></mtable></math>").has_prefix("1 by 2 matrix, row 1: a, b"), "matrix speech");
}

void test_autocorrect() {
    string path = Path.build_filename(Environment.get_tmp_dir(), "math-autocorrect-test-%d.json".printf((int) (Random.next_int() % 100000)));
    FileUtils.remove(path);
    var ac = new AutoCorrect(path);
    check_eq(ac.lookup("\\alpha") ?? "", "α", "default entry");
    check_eq(ac.lookup("->") ?? "", rarrow(), "arrow entry decoded");
    check_eq(ac.lookup("\\hat") ?? "", MathXml.uc(0x0302), "combining entry decoded");
    check(ac.is_function("sin") && !ac.is_function("Tr"), "default functions");
    ac.set_entry("\\RR", "ℝ");
    ac.remove_entry("\\beta");
    ac.add_function("Tr");
    ac.remove_function("sec");
    ac.replace_outside_math = true;
    try {
        ac.save();
    } catch (Error e) {
        check(false, "save: " + e.message);
    }
    var again = new AutoCorrect(path);
    check_eq(again.lookup("\\RR") ?? "", "ℝ", "custom entry persists");
    check(again.lookup("\\beta") == null, "removal persists");
    check(again.is_function("Tr") && !again.is_function("sec"), "function list persists");
    check(again.replace_outside_math, "outside math flag persists");
    check(again.is_custom("\\RR") && !again.is_custom("\\alpha"), "custom detection");
    var ops = again.operator_keys();
    check(ops.size > 5 && ops[0].length >= ops[ops.size - 1].length, "operator keys longest first");
    FileUtils.remove(path);
}

void test_numbering() {
    var a = new Equation.from_mathml(M + "<mi>a</mi></math>");
    a.numbered = true;
    a.label = "eq-a";
    var b = new Equation.from_mathml(M + "<mi>b</mi></math>");
    b.display = false;
    b.numbered = true;
    var c = new Equation.from_mathml(M + "<mi>c</mi></math>");
    c.numbered = true;
    c.label = "eq-c";
    var fmt = new NumberFormat();
    var labels = Numbering.assign({ a, b, c }, fmt);
    check_eq(labels[0] ?? "", "(1)", "first number");
    check(labels[1] == null, "inline equations are not numbered");
    check_eq(labels[2] ?? "", "(2)", "second number");
    fmt.style = NumberStyle.BRACKETS;
    fmt.with_chapter = true;
    var refs = Numbering.references({ a, b, c }, fmt, { 3, 3, 4 });
    check_eq(refs["eq-a"] ?? "", "[3.1]", "chapter number");
    check_eq(refs["eq-c"] ?? "", "[4.1]", "numbering restarts by chapter");
}

void test_equation() {
    var eq = Equation.from_omml("<m:oMathPara><m:oMathParaPr><m:jc m:val=\"right\"/></m:oMathParaPr><m:oMath><m:sSup><m:e><m:r><m:t>e</m:t></m:r></m:e><m:sup><m:r><m:t>x</m:t></m:r></m:sup></m:sSup></m:oMath></m:oMathPara>");
    check(eq != null && eq.display && eq.justification == Justification.RIGHT, "equation from OMML");
    string odf = eq.to_odf_object();
    check(odf.has_prefix("<?xml") && odf.contains("<math xmlns=\"http://www.w3.org/1998/Math/MathML\"") && odf.contains("<msup><mi>e</mi><mi>x</mi></msup>"), "ODF object: " + odf);
    var back = Equation.from_odf_object("<math:math xmlns:math=\"http://www.w3.org/1998/Math/MathML\" math:display=\"block\"><math:semantics><math:mi>q</math:mi><math:annotation math:encoding=\"StarMath 5.0\">q</math:annotation></math:semantics></math:math>");
    check(back != null && back.mathml.contains("<mi>q</mi>") && !back.mathml.contains("math:"), "ODF object with prefixes: " + (back != null ? back.mathml : ""));
    string html = eq.to_word_html();
    check(html.contains("<!--[if gte msEquation 12]><m:oMathPara>") && html.contains("<m:r>e</m:r>") && html.contains("<![if !msEquation]><math"), "Word clipboard HTML: " + html);
    var pasted = Equation.from_clipboard("text/html", new Bytes(html.data));
    check(pasted != null && pasted.mathml.contains("<msup><mi>e</mi><mi>x</mi></msup>"), "paste Word HTML back");
    var pasted2 = Equation.from_clipboard("application/mathml+xml", new Bytes((M + "<mi>z</mi></math>").data));
    check(pasted2 != null && pasted2.speech == "z", "paste MathML");
    var latex = new Equation.from_mathml(M + "<semantics><mi>x</mi><annotation encoding=\"application/x-tex\">x</annotation></semantics></math>");
    check_eq(latex.latex, "x", "LaTeX annotation");
    var provider = eq.content_provider();
    var formats = provider.ref_formats();
    check(formats.contain_mime_type("application/mathml+xml") && formats.contain_mime_type("text/html") && formats.contain_mime_type(Equation.OMML_MIME), "clipboard formats");
}

int main(string[] args) {
    fixtures = args.length > 1 ? args[1] : "tests/fixtures/equations";
    test_xml();
    test_to_omml();
    test_from_omml();
    test_fixture_roundtrip();
    test_speech();
    test_autocorrect();
    test_numbering();
    test_equation();
    print("equations: %d passed, %d failed\n", passed, failures);
    return failures == 0 ? 0 : 1;
}
