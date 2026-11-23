namespace Singularity.Migration {

    public class Preview : Object {
        public string kind { get; construct; }
        public Gdk.Texture texture { get; construct; }

        private Preview(string kind, Gdk.Texture texture) {
            Object(kind: kind, texture: texture);
        }

        public static async Gee.List<Preview> fetch(string app_id, Cancellable? cancellable = null) throws Error {
            var list = new Gee.ArrayList<Preview>();
            if (!GLib.Application.id_is_valid(app_id)) return list;
            var bus = yield Bus.get(BusType.SESSION, cancellable);
            var reply = yield bus.call(app_id, "/" + app_id.replace(".", "/").replace("-", "_"), "dev.sinty.Migration1", "Snapshot",
                null, new VariantType("(v)"), DBusCallFlags.NO_AUTO_START, 5000, cancellable);
            var pictures = reply.get_child_value(0).get_variant();
            if (!pictures.is_of_type(new VariantType("a(siiay)"))) return list;
            foreach (var picture in pictures) {
                int width = picture.get_child_value(1).get_int32(), height = picture.get_child_value(2).get_int32();
                var pixels = picture.get_child_value(3).get_data_as_bytes();
                if (width <= 0 || height <= 0 || pixels.get_size() != (size_t) width * height * 4) continue;
                var texture = new Gdk.MemoryTexture(width, height, Gdk.MemoryFormat.R8G8B8A8, pixels, width * 4);
                list.add(new Preview(picture.get_child_value(0).get_string(), texture));
            }
            return list;
        }
    }
}
