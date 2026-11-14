#ifndef SINGULARITY_SCENE_RENDER_H
#define SINGULARITY_SCENE_RENDER_H

typedef struct _SgRender SgRender;

enum {
    SG_MODE_SURFACE = 0,
    SG_MODE_RAMP = 1,
    SG_MODE_ZEBRA = 2,
    SG_MODE_CLAY = 3,
    SG_MODE_FLAT = 4
};

typedef struct {
    float color[4];
    float back[4];
    float roughness;
    float metallic;
    float sheen;
    float weave;
    float weave_scale;
    float clearcoat;
    float tex_scale;
    int texture;
    int mode;
    int double_sided;
    int cast_shadow;
} SgMaterial;

typedef struct {
    float eye[3];
    float target[3];
    float fov;
    float top[3];
    float bottom[3];
    float center[3];
    float radius;
    float floor_y;
    float ramp_min;
    float ramp_max;
    int shadow;
    int grid;
    int wire;
    int transparent;
    int samples;
} SgFrame;

SgRender *sg_render_new (int gles);
void sg_render_free (SgRender *r);
const char *sg_render_error (SgRender *r);

int sg_render_mesh_new (SgRender *r);
void sg_render_mesh_free (SgRender *r, int id);
void sg_render_mesh_geometry (SgRender *r, int id, const float *pos, const float *nrm, const float *uv, const float *scalar, int nv,
                              const unsigned int *tri, int ntri, const unsigned int *line, int nline);
void sg_render_mesh_update (SgRender *r, int id, const float *pos, const float *nrm, const float *scalar, int nv);
void sg_render_mesh_material (SgRender *r, int id, const SgMaterial *m);
void sg_render_mesh_visible (SgRender *r, int id, int visible);

int sg_render_texture (SgRender *r, const unsigned char *rgba, int w, int h);
void sg_render_texture_free (SgRender *r, int tex);

void sg_render_begin (SgRender *r, const SgFrame *f, int w, int h);
void sg_render_overlay (SgRender *r, const float *xyzrgba, int count, int prim, float size, int depth);
void sg_render_end (SgRender *r, int target_fbo);
void sg_render_read (SgRender *r, unsigned char *rgba);

int sg_render_bound_fbo (void);
void sg_frame_matrices (const SgFrame *f, int w, int h, float *view, float *proj);

#endif
