[CCode (cheader_filename = "gtk/gtk.h")]
namespace GdkExtra {
    [CCode (cname = "GdkMemoryTextureBuilder", type_id = "gdk_memory_texture_builder_get_type ()")]
    public class MemoryTextureBuilder : GLib.Object {
        [CCode (cname = "gdk_memory_texture_builder_new", has_construct_function = false)]
        public MemoryTextureBuilder ();
        [CCode (cname = "gdk_memory_texture_builder_set_bytes")]
        public void set_bytes (GLib.Bytes bytes);
        [CCode (cname = "gdk_memory_texture_builder_set_format")]
        public void set_format (Gdk.MemoryFormat format);
        [CCode (cname = "gdk_memory_texture_builder_set_width")]
        public void set_width (int width);
        [CCode (cname = "gdk_memory_texture_builder_set_height")]
        public void set_height (int height);
        [CCode (cname = "gdk_memory_texture_builder_set_stride")]
        public void set_stride (size_t stride);
        [CCode (cname = "gdk_memory_texture_builder_set_update_texture")]
        public void set_update_texture (Gdk.Texture? texture);
        [CCode (cname = "gdk_memory_texture_builder_set_update_region")]
        public void set_update_region (Cairo.Region? region);
        [CCode (cname = "gdk_memory_texture_builder_build")]
        public Gdk.Texture build ();
    }
}
