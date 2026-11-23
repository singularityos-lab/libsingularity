using Gtk;

namespace Singularity.Hub {

    public delegate void CardAction(string action);

    public interface CardProvider : Object {
        public abstract bool handles(Item item);
        public abstract Widget build(Item item, CardAction act);
    }

    public class Cards : Object {
        private static Gee.ArrayList<CardProvider>? providers = null;

        public static void register(CardProvider provider) {
            if (providers == null) providers = new Gee.ArrayList<CardProvider>();
            providers.insert(0, provider);
        }

        public static Widget build(Item item, owned CardAction act) {
            if (providers != null) {
                foreach (var p in providers) {
                    if (p.handles(item)) return p.build(item, act);
                }
            }
            return new TextCard(item, (owned) act);
        }
    }

    public class TextCard : Box {
        private CardAction act;

        public TextCard(Item item, owned CardAction act) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            add_css_class("hub-card-text");
            this.act = (owned) act;
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
            if (item.files.length > 0) append(attachments(item.files));
            string text = item.body != "" ? item.body : item.preview;
            bool rich = item.markup != "" && valid_markup(item.markup);
            if (rich || text != "") {
                var body = new Label(null);
                if (rich) body.set_markup(item.markup);
                else body.label = text;
                body.xalign = 0;
                body.yalign = 0;
                body.wrap = true;
                body.wrap_mode = Pango.WrapMode.WORD_CHAR;
                body.selectable = false;
                body.vexpand = true;
                append(body);
            }
        }

        private static bool valid_markup(string markup) {
            try {
                var links = new Regex("<a\\s+href=\"[^\"]*\"\\s*>");
                string plain = links.replace(markup, -1, 0, "<span>").replace("</a>", "</span>");
                Pango.parse_markup(plain, -1, 0, null, null, null);
                return true;
            } catch (Error e) {
                return false;
            }
        }

        private Widget attachments(string[] files) {
            var flow = new FlowBox();
            flow.add_css_class("hub-card-files");
            flow.selection_mode = SelectionMode.NONE;
            flow.column_spacing = 8;
            flow.row_spacing = 8;
            flow.homogeneous = false;
            flow.max_children_per_line = 8;
            for (int i = 0; i < files.length; i++) {
                int index = i;
                var content = new Box(Orientation.HORIZONTAL, 6);
                content.append(new Image.from_icon_name("mail-attachment-symbolic"));
                var name = new Label(files[i]);
                name.ellipsize = Pango.EllipsizeMode.MIDDLE;
                name.max_width_chars = 28;
                content.append(name);
                var chip = new Button();
                chip.add_css_class("pill");
                chip.child = content;
                chip.tooltip_text = files[i];
                chip.clicked.connect(() => act("attachment:%d".printf(index)));
                flow.append(chip);
            }
            return flow;
        }
    }
}
