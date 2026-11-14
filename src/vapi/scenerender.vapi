[CCode (cheader_filename = "scene3d/scene_gl.h")]
namespace SgScene {
    [CCode (cname = "SgMaterial", has_type_id = false, destroy_function = "")]
    public struct Material {
        public float color[4];
        public float back[4];
        public float roughness;
        public float metallic;
        public float sheen;
        public float weave;
        public float weave_scale;
        public float clearcoat;
        public float tex_scale;
        public int texture;
        public int mode;
        public int double_sided;
        public int cast_shadow;
    }

    [CCode (cname = "SgFrame", has_type_id = false, destroy_function = "")]
    public struct Frame {
        public float eye[3];
        public float target[3];
        public float fov;
        public float top[3];
        public float bottom[3];
        public float center[3];
        public float radius;
        public float floor_y;
        public float ramp_min;
        public float ramp_max;
        public int shadow;
        public int grid;
        public int wire;
        public int transparent;
        public int samples;
    }

    [Compact]
    [CCode (cname = "SgRender", free_function = "sg_render_free", cprefix = "sg_render_")]
    public class Render {
        [CCode (cname = "sg_render_new")]
        public Render (int gles);
        public unowned string? error ();
        public int mesh_new ();
        public void mesh_free (int id);
        public void mesh_geometry (int id, [CCode (array_length = false)] float[] pos, [CCode (array_length = false)] float[]? nrm, [CCode (array_length = false)] float[]? uv, [CCode (array_length = false)] float[]? scalar, int nv, [CCode (array_length = false)] uint[] tri, int ntri, [CCode (array_length = false)] uint[]? line, int nline);
        public void mesh_update (int id, [CCode (array_length = false)] float[] pos, [CCode (array_length = false)] float[]? nrm, [CCode (array_length = false)] float[]? scalar, int nv);
        public void mesh_material (int id, Material m);
        public void mesh_visible (int id, int visible);
        public int texture ([CCode (array_length = false)] uint8[] rgba, int w, int h);
        public void texture_free (int tex);
        public void begin (Frame f, int w, int h);
        public void overlay ([CCode (array_length = false)] float[] xyzrgba, int count, int prim, float size, int depth);
        public void end (int target_fbo, int dw, int dh);
        public void read ([CCode (array_length = false)] uint8[] rgba);
        [CCode (cname = "sg_render_bound_fbo")]
        public static int bound_fbo ();
    }
}
