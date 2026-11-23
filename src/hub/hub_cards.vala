using Gtk;

namespace Singularity.Hub {

    public interface CardProvider : Object {
        public abstract bool handles(Item item);
        public abstract Widget build(Item item);
    }

    public class Cards : Object {
        private static Gee.ArrayList<CardProvider>? providers = null;

        public static void register(CardProvider provider) {
            if (providers == null) providers = new Gee.ArrayList<CardProvider>();
            providers.insert(0, provider);
        }

        public static Widget build(Item item) {
            if (providers != null) {
                foreach (var p in providers) {
                    if (p.handles(item)) return p.build(item);
                }
            }
            return new TextCard(item);
        }
    }

    public class TextCard : Box {
        public TextCard(Item item) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            add_css_class("hub-card-text");
            margin_start = 16;
            margin_end = 16;
            margin_top = 8;
            margin_bottom = 16;
            if (item.subject != "") {
                var subject = new Label(item.subject);
                subject.add_css_class("title-3");
                subject.xalign = 0;
                subject.wrap = true;
                subject.wrap_mode = Pango.WrapMode.WORD_CHAR;
                subject.selectable = false;
                append(subject);
            }
            string text = item.body != "" ? item.body : item.preview;
            if (text != "") {
                var body = new Label(text);
                body.xalign = 0;
                body.yalign = 0;
                body.wrap = true;
                body.wrap_mode = Pango.WrapMode.WORD_CHAR;
                body.selectable = false;
                body.vexpand = true;
                append(body);
            }
        }
    }
}
