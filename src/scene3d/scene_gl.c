#include "scene_gl.h"

#include <epoxy/gl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SHADOW_SIZE 2048

typedef struct {
    int used;
    int visible;
    GLuint vao;
    GLuint vbo[4];
    GLuint ebo_tri;
    GLuint ebo_line;
    GLuint ebo_wire;
    int nv;
    int ntri;
    int nline;
    int nwire;
    int has_uv;
    int has_scalar;
    SgMaterial mat;
} RMesh;

struct _SgRender {
    int gles;
    char error[512];
    GLuint p_surface;
    GLuint p_depth;
    GLuint p_floor;
    GLuint p_back;
    GLuint p_overlay;
    GLuint quad_vao;
    GLuint quad_vbo;
    GLuint ov_vao;
    GLuint ov_vbo;
    GLuint fbo_ms;
    GLuint rb_color;
    GLuint rb_depth;
    GLuint fbo_resolve;
    GLuint tex_resolve;
    GLuint fbo_shadow;
    GLuint tex_shadow;
    GLuint tex_white;
    int w;
    int h;
    int samples;
    RMesh *meshes;
    int nmeshes;
    SgFrame frame;
    float view[16];
    float proj[16];
    float vp[16];
    float light[16];
    float key[3];
    float *scratch;
    int scratch_cap;
};

static void mat_identity (float *m) {
    memset (m, 0, 16 * sizeof (float));
    m[0] = m[5] = m[10] = m[15] = 1;
}

static void mat_mul (float *out, const float *a, const float *b) {
    float r[16];
    for (int c = 0; c < 4; c++)
        for (int row = 0; row < 4; row++)
            r[c * 4 + row] = a[row] * b[c * 4] + a[4 + row] * b[c * 4 + 1] + a[8 + row] * b[c * 4 + 2] + a[12 + row] * b[c * 4 + 3];
    memcpy (out, r, sizeof r);
}

static void v_sub (float *o, const float *a, const float *b) {
    o[0] = a[0] - b[0];
    o[1] = a[1] - b[1];
    o[2] = a[2] - b[2];
}

static void v_cross (float *o, const float *a, const float *b) {
    float r[3] = { a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
    memcpy (o, r, sizeof r);
}

static float v_dot (const float *a, const float *b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

static void v_norm (float *a) {
    float l = sqrtf (v_dot (a, a));
    if (l > 1e-12f) {
        a[0] /= l;
        a[1] /= l;
        a[2] /= l;
    }
}

static void mat_look (float *m, const float *eye, const float *target) {
    float f[3], s[3], u[3], up[3] = { 0, 1, 0 };
    v_sub (f, target, eye);
    v_norm (f);
    v_cross (s, f, up);
    if (v_dot (s, s) < 1e-8f) {
        s[0] = 1;
        s[1] = 0;
        s[2] = 0;
    }
    v_norm (s);
    v_cross (u, s, f);
    mat_identity (m);
    m[0] = s[0]; m[4] = s[1]; m[8] = s[2];
    m[1] = u[0]; m[5] = u[1]; m[9] = u[2];
    m[2] = -f[0]; m[6] = -f[1]; m[10] = -f[2];
    m[12] = -v_dot (s, eye);
    m[13] = -v_dot (u, eye);
    m[14] = v_dot (f, eye);
}

static void mat_persp (float *m, float fov_deg, float aspect, float zn, float zf) {
    float t = 1.0f / tanf (fov_deg * (float) M_PI / 360.0f);
    memset (m, 0, 16 * sizeof (float));
    m[0] = t / aspect;
    m[5] = t;
    m[10] = (zf + zn) / (zn - zf);
    m[11] = -1;
    m[14] = 2 * zf * zn / (zn - zf);
}

static void mat_ortho (float *m, float half, float zn, float zf) {
    mat_identity (m);
    m[0] = 1 / half;
    m[5] = 1 / half;
    m[10] = -2 / (zf - zn);
    m[14] = -(zf + zn) / (zf - zn);
}

void sg_frame_matrices (const SgFrame *f, int w, int h, float *view, float *proj) {
    float d[3];
    v_sub (d, f->eye, f->target);
    float dist = sqrtf (v_dot (d, d));
    float reach = dist + f->radius * 8 + 1000;
    float zn = dist * 0.02f;
    if (zn < 1) zn = 1;
    mat_look (view, f->eye, f->target);
    mat_persp (proj, f->fov, h > 0 ? (float) w / h : 1, zn, reach * 4);
}

static const char *VS_SURFACE =
    "layout(location=0) in vec3 a_pos;\n"
    "layout(location=1) in vec3 a_nrm;\n"
    "layout(location=2) in vec2 a_uv;\n"
    "layout(location=3) in float a_scalar;\n"
    "uniform mat4 u_vp;\n"
    "uniform mat4 u_light;\n"
    "out vec3 v_pos;\n"
    "out vec3 v_nrm;\n"
    "out vec2 v_uv;\n"
    "out float v_scalar;\n"
    "out vec4 v_lpos;\n"
    "void main(){\n"
    "  v_pos=a_pos; v_nrm=a_nrm; v_uv=a_uv; v_scalar=a_scalar;\n"
    "  v_lpos=u_light*vec4(a_pos,1.0);\n"
    "  gl_Position=u_vp*vec4(a_pos,1.0);\n"
    "}\n";

static const char *FS_COMMON =
    "uniform vec3 u_key;\n"
    "uniform sampler2DShadow u_shadow;\n"
    "uniform bool u_shadow_on;\n"
    "float shadow_at(vec4 lp, float bias){\n"
    "  if(!u_shadow_on) return 1.0;\n"
    "  vec3 p=lp.xyz/lp.w*0.5+0.5;\n"
    "  if(p.x<0.0||p.y<0.0||p.x>1.0||p.y>1.0||p.z>1.0) return 1.0;\n"
    "  float s=0.0; float t=1.0/2048.0;\n"
    "  for(int i=-2;i<=2;i++) for(int j=-2;j<=2;j++)\n"
    "    s+=texture(u_shadow, vec3(p.xy+vec2(float(i),float(j))*t*1.2, p.z-bias));\n"
    "  return s/25.0;\n"
    "}\n"
    "vec3 tonemap(vec3 c){\n"
    "  c=(c*(2.51*c+0.03))/(c*(2.43*c+0.59)+0.14);\n"
    "  return pow(clamp(c,0.0,1.0), vec3(1.0/2.2));\n"
    "}\n";

static const char *FS_SURFACE =
    "in vec3 v_pos;\n"
    "in vec3 v_nrm;\n"
    "in vec2 v_uv;\n"
    "in float v_scalar;\n"
    "in vec4 v_lpos;\n"
    "uniform vec3 u_eye;\n"
    "uniform vec4 u_color;\n"
    "uniform vec4 u_back;\n"
    "uniform float u_rough;\n"
    "uniform float u_metal;\n"
    "uniform float u_sheen;\n"
    "uniform float u_weave;\n"
    "uniform float u_weave_scale;\n"
    "uniform float u_clearcoat;\n"
    "uniform float u_tex_scale;\n"
    "uniform bool u_tex;\n"
    "uniform sampler2D u_albedo;\n"
    "uniform int u_mode;\n"
    "uniform vec2 u_ramp;\n"
    "out vec4 o_color;\n"
    "vec3 ramp(float t){\n"
    "  t=clamp(t,0.0,1.0);\n"
    "  vec3 a=vec3(0.16,0.33,0.86), b=vec3(0.13,0.78,0.80), c=vec3(0.36,0.80,0.26), d=vec3(0.98,0.84,0.16), e=vec3(0.90,0.20,0.16);\n"
    "  if(t<0.25) return mix(a,b,t*4.0);\n"
    "  if(t<0.5) return mix(b,c,(t-0.25)*4.0);\n"
    "  if(t<0.75) return mix(c,d,(t-0.5)*4.0);\n"
    "  return mix(d,e,(t-0.75)*4.0);\n"
    "}\n"
    "vec3 env(vec3 d, float rough){\n"
    "  float t=d.y*0.5+0.5;\n"
    "  vec3 sky=mix(vec3(0.20,0.19,0.18), vec3(0.86,0.88,0.92), smoothstep(0.05,0.95,t));\n"
    "  float k=mix(90.0,1.5,sqrt(rough));\n"
    "  float b1=pow(max(dot(d,u_key),0.0),k);\n"
    "  float b2=pow(max(dot(d,normalize(vec3(0.75,0.25,0.5))),0.0),k);\n"
    "  float b3=pow(max(dot(d,normalize(vec3(0.1,0.4,-1.0))),0.0),k);\n"
    "  float strip=smoothstep(0.03,0.0,abs(d.y-0.35))*step(0.0,d.z)*(1.0-rough);\n"
    "  return sky+vec3(1.0,0.98,0.95)*(b1*3.0+b2*0.9+b3*1.2+strip*0.8)*mix(1.0,0.2,rough);\n"
    "}\n"
    "float ggx(float nh, float a){\n"
    "  float a2=a*a; float d=nh*nh*(a2-1.0)+1.0;\n"
    "  return a2/(3.14159*d*d+1e-6);\n"
    "}\n"
    "void main(){\n"
    "  vec3 N=normalize(v_nrm);\n"
    "  vec3 V=normalize(u_eye-v_pos);\n"
    "  bool back=!gl_FrontFacing;\n"
    "  if(back) N=-N;\n"
    "  vec4 base=back?u_back:u_color;\n"
    "  vec3 albedo=pow(base.rgb, vec3(2.2));\n"
    "  if(u_tex && !back) albedo*=pow(texture(u_albedo, v_uv*u_tex_scale).rgb, vec3(2.2));\n"
    "  float rough=clamp(u_rough,0.04,1.0);\n"
    "  float metal=u_metal;\n"
    "  if(u_mode==1){\n"
    "    albedo=pow(ramp((v_scalar-u_ramp.x)/max(1e-6,u_ramp.y-u_ramp.x)), vec3(2.2)); rough=0.8; metal=0.0;\n"
    "  } else if(u_mode==3){\n"
    "    albedo=vec3(0.78); rough=0.75; metal=0.0;\n"
    "  }\n"
    "  if(u_weave>0.0 && u_mode==0){\n"
    "    vec2 q=v_uv*u_weave_scale;\n"
    "    float fw=max(fwidth(q.x),fwidth(q.y));\n"
    "    float fade=clamp(1.0-fw*2.2,0.0,1.0);\n"
    "    if(fade>0.0){\n"
    "      float hgt=sin(q.x*6.2832)*sin(q.y*6.2832)*0.6+sin((q.x+q.y)*3.1416)*0.4;\n"
    "      vec3 dpx=dFdx(v_pos), dpy=dFdy(v_pos);\n"
    "      float dhx=dFdx(hgt)*u_weave*fade, dhy=dFdy(hgt)*u_weave*fade;\n"
    "      vec3 r1=cross(dpy,N), r2=cross(N,dpx);\n"
    "      float det=dot(dpx,r1);\n"
    "      N=normalize(abs(det)*N-sign(det)*(dhx*r1+dhy*r2));\n"
    "      albedo*=1.0-0.10*fade*(0.5-0.5*hgt);\n"
    "    }\n"
    "  }\n"
    "  float nv=max(dot(N,V),1e-4);\n"
    "  if(u_mode==2){\n"
    "    vec3 R=reflect(-V,N);\n"
    "    float s=step(0.5,fract((R.y*0.5+0.5)*14.0));\n"
    "    float lam=0.75+0.25*max(dot(N,u_key),0.0);\n"
    "    o_color=vec4(pow(vec3(mix(0.03,0.95,s)*lam),vec3(1.0/2.2)),1.0);\n"
    "    return;\n"
    "  }\n"
    "  float nl=max(dot(N,u_key),0.0);\n"
    "  float bias=mix(0.0035,0.0008,nl);\n"
    "  float sh=shadow_at(v_lpos,bias);\n"
    "  vec3 F0=mix(vec3(0.04),albedo,metal);\n"
    "  vec3 H=normalize(u_key+V);\n"
    "  float nh=max(dot(N,H),0.0), vh=max(dot(V,H),0.0);\n"
    "  float a=rough*rough;\n"
    "  vec3 F=F0+(1.0-F0)*pow(1.0-vh,5.0);\n"
    "  float kk=(rough+1.0)*(rough+1.0)/8.0;\n"
    "  float G=(nl/(nl*(1.0-kk)+kk))*(nv/(nv*(1.0-kk)+kk));\n"
    "  vec3 spec=F*ggx(nh,a)*G/(4.0*nv*max(nl,1e-4)+1e-4);\n"
    "  vec3 fill=normalize(vec3(0.75,0.25,0.5));\n"
    "  vec3 rim=normalize(vec3(0.1,0.4,-1.0));\n"
    "  float hem=N.y*0.5+0.5;\n"
    "  vec3 amb=mix(vec3(0.13,0.12,0.115), vec3(0.36,0.375,0.41), hem);\n"
    "  vec3 diff=albedo*(1.0-metal);\n"
    "  vec3 c=diff*amb;\n"
    "  c+=(diff/3.14159+spec)*nl*sh*vec3(3.5,3.4,3.25);\n"
    "  c+=diff*(max(dot(N,fill),0.0)*0.30+pow(max(dot(N,rim),0.0),1.5)*0.26);\n"
    "  vec3 R=reflect(-V,N);\n"
    "  vec3 Fe=F0+(max(vec3(1.0-rough),F0)-F0)*pow(1.0-nv,5.0);\n"
    "  c+=env(R,rough)*Fe*mix(1.0,0.35,rough)*mix(0.55,1.0,sh);\n"
    "  if(u_sheen>0.0) c+=albedo*u_sheen*pow(1.0-nv,3.0)*(0.5+0.5*hem);\n"
    "  if(u_clearcoat>0.0){\n"
    "    vec3 Nc=normalize(back?-v_nrm:v_nrm);\n"
    "    float f=0.04+0.96*pow(1.0-max(dot(Nc,V),0.0),5.0);\n"
    "    c=c*(1.0-f*u_clearcoat)+env(reflect(-V,Nc),0.03)*f*u_clearcoat;\n"
    "  }\n"
    "  if(u_mode==4) c=albedo;\n"
    "  o_color=vec4(tonemap(c), base.a);\n"
    "}\n";

static const char *VS_DEPTH =
    "layout(location=0) in vec3 a_pos;\n"
    "uniform mat4 u_vp;\n"
    "void main(){ gl_Position=u_vp*vec4(a_pos,1.0); }\n";

static const char *FS_DEPTH = "out vec4 o_color;\nvoid main(){ o_color=vec4(1.0); }\n";

static const char *VS_FLOOR =
    "layout(location=0) in vec2 a_pos;\n"
    "uniform mat4 u_vp;\n"
    "uniform mat4 u_light;\n"
    "uniform vec4 u_floor;\n"
    "out vec3 v_pos;\n"
    "out vec4 v_lpos;\n"
    "void main(){\n"
    "  v_pos=vec3(u_floor.x+a_pos.x*u_floor.w, u_floor.y, u_floor.z+a_pos.y*u_floor.w);\n"
    "  v_lpos=u_light*vec4(v_pos,1.0);\n"
    "  gl_Position=u_vp*vec4(v_pos,1.0);\n"
    "}\n";

static const char *FS_FLOOR =
    "in vec3 v_pos;\n"
    "in vec4 v_lpos;\n"
    "uniform vec4 u_floor;\n"
    "uniform float u_radius;\n"
    "uniform bool u_grid;\n"
    "out vec4 o_color;\n"
    "float grid(vec2 p, float cell){\n"
    "  vec2 g=abs(fract(p/cell-0.5)-0.5)/fwidth(p/cell);\n"
    "  return 1.0-min(min(g.x,g.y),1.0);\n"
    "}\n"
    "void main(){\n"
    "  vec2 p=v_pos.xz;\n"
    "  float d=length(p-u_floor.xz)/(u_radius*3.2);\n"
    "  float fade=1.0-smoothstep(0.35,1.0,d);\n"
    "  float sh=1.0-shadow_at(v_lpos,0.0012);\n"
    "  float a=sh*0.34;\n"
    "  vec3 c=vec3(0.0);\n"
    "  if(u_grid){\n"
    "    float g=max(grid(p,100.0)*0.10, grid(p,1000.0)*0.22);\n"
    "    c=mix(c, vec3(0.25,0.27,0.32), g/(a+g+1e-4));\n"
    "    a=a+g*(1.0-a);\n"
    "  }\n"
    "  o_color=vec4(c, a*fade);\n"
    "}\n";

static const char *VS_BACK =
    "layout(location=0) in vec2 a_pos;\n"
    "out vec2 v_uv;\n"
    "void main(){ v_uv=a_pos*0.5+0.5; gl_Position=vec4(a_pos,0.999,1.0); }\n";

static const char *FS_BACK =
    "in vec2 v_uv;\n"
    "uniform vec3 u_top;\n"
    "uniform vec3 u_bottom;\n"
    "out vec4 o_color;\n"
    "void main(){\n"
    "  float t=smoothstep(0.0,1.0,v_uv.y);\n"
    "  vec3 c=mix(u_bottom,u_top,t);\n"
    "  float n=fract(sin(dot(gl_FragCoord.xy,vec2(12.9898,78.233)))*43758.5453);\n"
    "  o_color=vec4(c+(n-0.5)/255.0,1.0);\n"
    "}\n";

static const char *VS_OVERLAY =
    "layout(location=0) in vec4 a_pos;\n"
    "layout(location=1) in vec4 a_color;\n"
    "layout(location=2) in vec2 a_corner;\n"
    "out vec4 v_color;\n"
    "out vec2 v_corner;\n"
    "void main(){ v_color=a_color; v_corner=a_corner; gl_Position=a_pos; }\n";

static const char *FS_OVERLAY =
    "in vec4 v_color;\n"
    "in vec2 v_corner;\n"
    "uniform bool u_round;\n"
    "out vec4 o_color;\n"
    "void main(){\n"
    "  float a=v_color.a;\n"
    "  if(u_round){ float d=length(v_corner); a*=1.0-smoothstep(0.8,1.0,d); if(a<=0.0) discard; }\n"
    "  o_color=vec4(v_color.rgb,a);\n"
    "}\n";

static GLuint compile (SgRender *r, GLenum type, const char *a, const char *b) {
    const char *head = r->gles ? "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2DShadow;\n" : "#version 330 core\n";
    const char *src[3] = { head, a, b ? b : "" };
    GLuint s = glCreateShader (type);
    glShaderSource (s, 3, src, NULL);
    glCompileShader (s);
    GLint ok = 0;
    glGetShaderiv (s, GL_COMPILE_STATUS, &ok);
    if (!ok && r->error[0] == 0) glGetShaderInfoLog (s, sizeof r->error, NULL, r->error);
    return s;
}

static GLuint program (SgRender *r, const char *vs, const char *fs_a, const char *fs_b) {
    GLuint v = compile (r, GL_VERTEX_SHADER, vs, NULL);
    GLuint f = compile (r, GL_FRAGMENT_SHADER, fs_a, fs_b);
    GLuint p = glCreateProgram ();
    glAttachShader (p, v);
    glAttachShader (p, f);
    glLinkProgram (p);
    GLint ok = 0;
    glGetProgramiv (p, GL_LINK_STATUS, &ok);
    if (!ok && r->error[0] == 0) glGetProgramInfoLog (p, sizeof r->error, NULL, r->error);
    glDeleteShader (v);
    glDeleteShader (f);
    return p;
}

SgRender *sg_render_new (int gles) {
    SgRender *r = calloc (1, sizeof (SgRender));
    r->gles = gles;
    r->p_surface = program (r, VS_SURFACE, FS_COMMON, FS_SURFACE);
    r->p_depth = program (r, VS_DEPTH, FS_DEPTH, NULL);
    r->p_floor = program (r, VS_FLOOR, FS_COMMON, FS_FLOOR);
    r->p_back = program (r, VS_BACK, FS_BACK, NULL);
    r->p_overlay = program (r, VS_OVERLAY, FS_OVERLAY, NULL);

    static const float quad[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
    glGenVertexArrays (1, &r->quad_vao);
    glBindVertexArray (r->quad_vao);
    glGenBuffers (1, &r->quad_vbo);
    glBindBuffer (GL_ARRAY_BUFFER, r->quad_vbo);
    glBufferData (GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
    glEnableVertexAttribArray (0);
    glVertexAttribPointer (0, 2, GL_FLOAT, GL_FALSE, 0, NULL);

    glGenVertexArrays (1, &r->ov_vao);
    glBindVertexArray (r->ov_vao);
    glGenBuffers (1, &r->ov_vbo);
    glBindBuffer (GL_ARRAY_BUFFER, r->ov_vbo);
    glEnableVertexAttribArray (0);
    glVertexAttribPointer (0, 4, GL_FLOAT, GL_FALSE, 10 * sizeof (float), (void *) 0);
    glEnableVertexAttribArray (1);
    glVertexAttribPointer (1, 4, GL_FLOAT, GL_FALSE, 10 * sizeof (float), (void *) (4 * sizeof (float)));
    glEnableVertexAttribArray (2);
    glVertexAttribPointer (2, 2, GL_FLOAT, GL_FALSE, 10 * sizeof (float), (void *) (8 * sizeof (float)));
    glBindVertexArray (0);

    glGenTextures (1, &r->tex_shadow);
    glBindTexture (GL_TEXTURE_2D, r->tex_shadow);
    glTexImage2D (GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24, SHADOW_SIZE, SHADOW_SIZE, 0, GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, NULL);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_COMPARE_FUNC, GL_LEQUAL);
    glGenFramebuffers (1, &r->fbo_shadow);
    glBindFramebuffer (GL_FRAMEBUFFER, r->fbo_shadow);
    glFramebufferTexture2D (GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, r->tex_shadow, 0);
    GLenum none = GL_NONE;
    glDrawBuffers (1, &none);
    glReadBuffer (GL_NONE);
    glBindFramebuffer (GL_FRAMEBUFFER, 0);

    static const unsigned char white[4] = { 255, 255, 255, 255 };
    glGenTextures (1, &r->tex_white);
    glBindTexture (GL_TEXTURE_2D, r->tex_white);
    glTexImage2D (GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, white);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

    glGenFramebuffers (1, &r->fbo_ms);
    glGenRenderbuffers (1, &r->rb_color);
    glGenRenderbuffers (1, &r->rb_depth);
    glGenFramebuffers (1, &r->fbo_resolve);
    glGenTextures (1, &r->tex_resolve);
    return r;
}

const char *sg_render_error (SgRender *r) {
    return r->error[0] ? r->error : NULL;
}

static void mesh_release (RMesh *m) {
    if (!m->used) return;
    glDeleteVertexArrays (1, &m->vao);
    glDeleteBuffers (4, m->vbo);
    glDeleteBuffers (1, &m->ebo_tri);
    glDeleteBuffers (1, &m->ebo_line);
    glDeleteBuffers (1, &m->ebo_wire);
    memset (m, 0, sizeof *m);
}

void sg_render_free (SgRender *r) {
    if (!r) return;
    for (int i = 0; i < r->nmeshes; i++) mesh_release (&r->meshes[i]);
    free (r->meshes);
    free (r->scratch);
    glDeleteProgram (r->p_surface);
    glDeleteProgram (r->p_depth);
    glDeleteProgram (r->p_floor);
    glDeleteProgram (r->p_back);
    glDeleteProgram (r->p_overlay);
    glDeleteVertexArrays (1, &r->quad_vao);
    glDeleteBuffers (1, &r->quad_vbo);
    glDeleteVertexArrays (1, &r->ov_vao);
    glDeleteBuffers (1, &r->ov_vbo);
    glDeleteFramebuffers (1, &r->fbo_ms);
    glDeleteRenderbuffers (1, &r->rb_color);
    glDeleteRenderbuffers (1, &r->rb_depth);
    glDeleteFramebuffers (1, &r->fbo_resolve);
    glDeleteTextures (1, &r->tex_resolve);
    glDeleteFramebuffers (1, &r->fbo_shadow);
    glDeleteTextures (1, &r->tex_shadow);
    glDeleteTextures (1, &r->tex_white);
    free (r);
}

int sg_render_mesh_new (SgRender *r) {
    int id = -1;
    for (int i = 0; i < r->nmeshes; i++)
        if (!r->meshes[i].used) {
            id = i;
            break;
        }
    if (id < 0) {
        id = r->nmeshes++;
        r->meshes = realloc (r->meshes, r->nmeshes * sizeof (RMesh));
    }
    RMesh *m = &r->meshes[id];
    memset (m, 0, sizeof *m);
    m->used = 1;
    m->visible = 1;
    glGenVertexArrays (1, &m->vao);
    glGenBuffers (4, m->vbo);
    glGenBuffers (1, &m->ebo_tri);
    glGenBuffers (1, &m->ebo_line);
    glGenBuffers (1, &m->ebo_wire);
    m->mat.color[0] = m->mat.color[1] = m->mat.color[2] = 0.8f;
    m->mat.color[3] = 1;
    memcpy (m->mat.back, m->mat.color, sizeof m->mat.color);
    m->mat.roughness = 0.7f;
    m->mat.double_sided = 1;
    m->mat.cast_shadow = 1;
    m->mat.tex_scale = 1;
    return id;
}

static RMesh *mesh_at (SgRender *r, int id) {
    if (id < 0 || id >= r->nmeshes || !r->meshes[id].used) return NULL;
    return &r->meshes[id];
}

void sg_render_mesh_free (SgRender *r, int id) {
    RMesh *m = mesh_at (r, id);
    if (m) mesh_release (m);
}

void sg_render_mesh_geometry (SgRender *r, int id, const float *pos, const float *nrm, const float *uv, const float *scalar, int nv,
                              const unsigned int *tri, int ntri, const unsigned int *line, int nline) {
    RMesh *m = mesh_at (r, id);
    if (!m) return;
    glBindVertexArray (m->vao);
    glBindBuffer (GL_ARRAY_BUFFER, m->vbo[0]);
    glBufferData (GL_ARRAY_BUFFER, (GLsizeiptr) nv * 3 * sizeof (float), pos, GL_DYNAMIC_DRAW);
    glEnableVertexAttribArray (0);
    glVertexAttribPointer (0, 3, GL_FLOAT, GL_FALSE, 0, NULL);
    glBindBuffer (GL_ARRAY_BUFFER, m->vbo[1]);
    glBufferData (GL_ARRAY_BUFFER, (GLsizeiptr) nv * 3 * sizeof (float), nrm, GL_DYNAMIC_DRAW);
    if (nrm) {
        glEnableVertexAttribArray (1);
        glVertexAttribPointer (1, 3, GL_FLOAT, GL_FALSE, 0, NULL);
    } else {
        glDisableVertexAttribArray (1);
        glVertexAttrib3f (1, 0, 1, 0);
    }
    m->has_uv = uv != NULL;
    if (uv) {
        glBindBuffer (GL_ARRAY_BUFFER, m->vbo[2]);
        glBufferData (GL_ARRAY_BUFFER, (GLsizeiptr) nv * 2 * sizeof (float), uv, GL_STATIC_DRAW);
        glEnableVertexAttribArray (2);
        glVertexAttribPointer (2, 2, GL_FLOAT, GL_FALSE, 0, NULL);
    } else {
        glDisableVertexAttribArray (2);
        glVertexAttrib2f (2, 0, 0);
    }
    m->has_scalar = scalar != NULL;
    if (scalar) {
        glBindBuffer (GL_ARRAY_BUFFER, m->vbo[3]);
        glBufferData (GL_ARRAY_BUFFER, (GLsizeiptr) nv * sizeof (float), scalar, GL_DYNAMIC_DRAW);
        glEnableVertexAttribArray (3);
        glVertexAttribPointer (3, 1, GL_FLOAT, GL_FALSE, 0, NULL);
    } else {
        glDisableVertexAttribArray (3);
        glVertexAttrib1f (3, 0);
    }
    glBindVertexArray (0);
    glBindBuffer (GL_ELEMENT_ARRAY_BUFFER, m->ebo_tri);
    glBufferData (GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr) ntri * sizeof (unsigned int), tri, GL_STATIC_DRAW);
    glBindBuffer (GL_ELEMENT_ARRAY_BUFFER, m->ebo_line);
    glBufferData (GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr) nline * sizeof (unsigned int), line, GL_STATIC_DRAW);
    unsigned int *wire = malloc ((size_t) (ntri > 0 ? ntri : 1) * 2 * sizeof (unsigned int));
    int nw = 0;
    for (int t = 0; t + 2 < ntri; t += 3)
        for (int e = 0; e < 3; e++) {
            unsigned int a = tri[t + e], b = tri[t + (e + 1) % 3];
            if (a < b) {
                wire[nw++] = a;
                wire[nw++] = b;
            }
        }
    glBindBuffer (GL_ELEMENT_ARRAY_BUFFER, m->ebo_wire);
    glBufferData (GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr) nw * sizeof (unsigned int), wire, GL_STATIC_DRAW);
    free (wire);
    glBindBuffer (GL_ELEMENT_ARRAY_BUFFER, 0);
    m->nv = nv;
    m->ntri = ntri;
    m->nline = nline;
    m->nwire = nw;
}

void sg_render_mesh_update (SgRender *r, int id, const float *pos, const float *nrm, const float *scalar, int nv) {
    RMesh *m = mesh_at (r, id);
    if (!m || nv != m->nv) return;
    glBindBuffer (GL_ARRAY_BUFFER, m->vbo[0]);
    glBufferSubData (GL_ARRAY_BUFFER, 0, (GLsizeiptr) nv * 3 * sizeof (float), pos);
    if (nrm) {
        glBindBuffer (GL_ARRAY_BUFFER, m->vbo[1]);
        glBufferSubData (GL_ARRAY_BUFFER, 0, (GLsizeiptr) nv * 3 * sizeof (float), nrm);
    }
    if (scalar && m->has_scalar) {
        glBindBuffer (GL_ARRAY_BUFFER, m->vbo[3]);
        glBufferSubData (GL_ARRAY_BUFFER, 0, (GLsizeiptr) nv * sizeof (float), scalar);
    }
    glBindBuffer (GL_ARRAY_BUFFER, 0);
}

void sg_render_mesh_material (SgRender *r, int id, const SgMaterial *mat) {
    RMesh *m = mesh_at (r, id);
    if (m) m->mat = *mat;
}

void sg_render_mesh_visible (SgRender *r, int id, int visible) {
    RMesh *m = mesh_at (r, id);
    if (m) m->visible = visible;
}

int sg_render_texture (SgRender *r, const unsigned char *rgba, int w, int h) {
    GLuint t;
    glGenTextures (1, &t);
    glBindTexture (GL_TEXTURE_2D, t);
    glTexImage2D (GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    glGenerateMipmap (GL_TEXTURE_2D);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
    return (int) t;
}

void sg_render_texture_free (SgRender *r, int tex) {
    GLuint t = (GLuint) tex;
    if (t) glDeleteTextures (1, &t);
}

static void resize (SgRender *r, int w, int h, int samples) {
    if (w == r->w && h == r->h && samples == r->samples) return;
    r->w = w;
    r->h = h;
    r->samples = samples;
    GLint max_samples = 0;
    glGetIntegerv (GL_MAX_SAMPLES, &max_samples);
    if (samples > max_samples) samples = max_samples;
    if (samples < 2) samples = 0;
    glBindRenderbuffer (GL_RENDERBUFFER, r->rb_color);
    glRenderbufferStorageMultisample (GL_RENDERBUFFER, samples, GL_RGBA8, w, h);
    glBindRenderbuffer (GL_RENDERBUFFER, r->rb_depth);
    glRenderbufferStorageMultisample (GL_RENDERBUFFER, samples, GL_DEPTH_COMPONENT24, w, h);
    glBindFramebuffer (GL_FRAMEBUFFER, r->fbo_ms);
    glFramebufferRenderbuffer (GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, r->rb_color);
    glFramebufferRenderbuffer (GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, r->rb_depth);
    glBindTexture (GL_TEXTURE_2D, r->tex_resolve);
    glTexImage2D (GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glBindFramebuffer (GL_FRAMEBUFFER, r->fbo_resolve);
    glFramebufferTexture2D (GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, r->tex_resolve, 0);
}

static void set_mat (GLuint p, const char *name, const float *m) {
    glUniformMatrix4fv (glGetUniformLocation (p, name), 1, GL_FALSE, m);
}

static void draw_tris (RMesh *m) {
    glBindVertexArray (m->vao);
    glBindBuffer (GL_ELEMENT_ARRAY_BUFFER, m->ebo_tri);
    glDrawElements (GL_TRIANGLES, m->ntri, GL_UNSIGNED_INT, NULL);
}

void sg_render_begin (SgRender *r, const SgFrame *f, int w, int h) {
    r->frame = *f;
    resize (r, w, h, f->samples >= 0 ? f->samples : 4);
    sg_frame_matrices (f, w, h, r->view, r->proj);
    mat_mul (r->vp, r->proj, r->view);
    float key[3] = { -0.42f, 0.78f, 0.46f };
    v_norm (key);
    memcpy (r->key, key, sizeof key);
    float rad = f->radius > 1 ? f->radius : 1;
    float leye[3] = { f->center[0] + key[0] * rad * 3, f->center[1] + key[1] * rad * 3, f->center[2] + key[2] * rad * 3 };
    float lview[16], lproj[16];
    mat_look (lview, leye, f->center);
    mat_ortho (lproj, rad * 1.15f, rad * 0.5f, rad * 6);
    mat_mul (r->light, lproj, lview);

    glDisable (GL_BLEND);
    glDisable (GL_SCISSOR_TEST);
    glDisable (GL_STENCIL_TEST);
    glEnable (GL_DEPTH_TEST);
    glDepthFunc (GL_LEQUAL);
    glDepthMask (GL_TRUE);
    glColorMask (GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glFrontFace (GL_CCW);
    if (r->gles) {
        glClearDepthf (1.0f);
        glDepthRangef (0.0f, 1.0f);
    } else {
        glClearDepth (1.0);
        glDepthRange (0.0, 1.0);
    }

    if (f->shadow) {
        glBindFramebuffer (GL_FRAMEBUFFER, r->fbo_shadow);
        glViewport (0, 0, SHADOW_SIZE, SHADOW_SIZE);
        glClear (GL_DEPTH_BUFFER_BIT);
        glUseProgram (r->p_depth);
        set_mat (r->p_depth, "u_vp", r->light);
        glDisable (GL_CULL_FACE);
        glEnable (GL_POLYGON_OFFSET_FILL);
        glPolygonOffset (2.0f, 4.0f);
        for (int i = 0; i < r->nmeshes; i++) {
            RMesh *m = &r->meshes[i];
            if (!m->used || !m->visible || m->ntri == 0 || !m->mat.cast_shadow) continue;
            draw_tris (m);
        }
        glDisable (GL_POLYGON_OFFSET_FILL);
    }

    glBindFramebuffer (GL_FRAMEBUFFER, r->fbo_ms);
    glViewport (0, 0, w, h);
    glClearColor (0, 0, 0, 0);
    glClear (GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    if (!f->transparent) {
        glDepthMask (GL_FALSE);
        glUseProgram (r->p_back);
        glUniform3fv (glGetUniformLocation (r->p_back, "u_top"), 1, f->top);
        glUniform3fv (glGetUniformLocation (r->p_back, "u_bottom"), 1, f->bottom);
        glBindVertexArray (r->quad_vao);
        glDrawArrays (GL_TRIANGLE_STRIP, 0, 4);
        glDepthMask (GL_TRUE);
    }

    GLuint p = r->p_surface;
    glUseProgram (p);
    set_mat (p, "u_vp", r->vp);
    set_mat (p, "u_light", r->light);
    glUniform3fv (glGetUniformLocation (p, "u_eye"), 1, f->eye);
    glUniform3fv (glGetUniformLocation (p, "u_key"), 1, r->key);
    glUniform1i (glGetUniformLocation (p, "u_shadow_on"), f->shadow);
    glUniform2f (glGetUniformLocation (p, "u_ramp"), f->ramp_min, f->ramp_max);
    glActiveTexture (GL_TEXTURE1);
    glBindTexture (GL_TEXTURE_2D, r->tex_shadow);
    glUniform1i (glGetUniformLocation (p, "u_shadow"), 1);
    glUniform1i (glGetUniformLocation (p, "u_albedo"), 0);
    glActiveTexture (GL_TEXTURE0);
    if (f->wire) {
        glEnable (GL_POLYGON_OFFSET_FILL);
        glPolygonOffset (1.0f, 1.0f);
    }
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < r->nmeshes; i++) {
            RMesh *m = &r->meshes[i];
            if (!m->used || !m->visible || m->ntri == 0) continue;
            int translucent = m->mat.color[3] < 0.999f;
            if (translucent != pass) continue;
            if (pass) {
                glEnable (GL_BLEND);
                glBlendFuncSeparate (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                glDepthMask (GL_FALSE);
            }
            if (m->mat.double_sided) glDisable (GL_CULL_FACE);
            else {
                glEnable (GL_CULL_FACE);
                glCullFace (GL_BACK);
            }
            glUniform4fv (glGetUniformLocation (p, "u_color"), 1, m->mat.color);
            glUniform4fv (glGetUniformLocation (p, "u_back"), 1, m->mat.back);
            glUniform1f (glGetUniformLocation (p, "u_rough"), m->mat.roughness);
            glUniform1f (glGetUniformLocation (p, "u_metal"), m->mat.metallic);
            glUniform1f (glGetUniformLocation (p, "u_sheen"), m->mat.sheen);
            glUniform1f (glGetUniformLocation (p, "u_weave"), m->has_uv ? m->mat.weave : 0);
            glUniform1f (glGetUniformLocation (p, "u_weave_scale"), m->mat.weave_scale);
            glUniform1f (glGetUniformLocation (p, "u_clearcoat"), m->mat.clearcoat);
            glUniform1f (glGetUniformLocation (p, "u_tex_scale"), m->mat.tex_scale);
            int mode = m->mat.mode;
            if (mode == SG_MODE_RAMP && !m->has_scalar) mode = SG_MODE_CLAY;
            glUniform1i (glGetUniformLocation (p, "u_mode"), mode);
            int tex = m->mat.texture > 0 && m->has_uv;
            glUniform1i (glGetUniformLocation (p, "u_tex"), tex);
            glBindTexture (GL_TEXTURE_2D, tex ? (GLuint) m->mat.texture : r->tex_white);
            draw_tris (m);
        }
    }
    glDisable (GL_BLEND);
    glDepthMask (GL_TRUE);
    glDisable (GL_POLYGON_OFFSET_FILL);
    glDisable (GL_CULL_FACE);

    int any_lines = f->wire;
    for (int i = 0; i < r->nmeshes && !any_lines; i++)
        if (r->meshes[i].used && r->meshes[i].visible && r->meshes[i].nline > 0) any_lines = 1;
    if (any_lines) {
        glUseProgram (r->p_depth);
        set_mat (r->p_depth, "u_vp", r->vp);
        glEnable (GL_BLEND);
        glBlendFunc (GL_ZERO, GL_SRC_COLOR);
        for (int i = 0; i < r->nmeshes; i++) {
            RMesh *m = &r->meshes[i];
            if (!m->used || !m->visible) continue;
            glBindVertexArray (m->vao);
            if (f->wire && m->nwire > 0) {
                glBlendColor (0, 0, 0, 0);
                glBlendFunc (GL_ZERO, GL_CONSTANT_COLOR);
                glBlendColor (0.55f, 0.58f, 0.64f, 1);
                glBindBuffer (GL_ELEMENT_ARRAY_BUFFER, m->ebo_wire);
                glDrawElements (GL_LINES, m->nwire, GL_UNSIGNED_INT, NULL);
            }
            if (m->nline > 0) {
                glBlendFunc (GL_CONSTANT_COLOR, GL_ZERO);
                glBlendColor (m->mat.color[0], m->mat.color[1], m->mat.color[2], 1);
                glBindBuffer (GL_ELEMENT_ARRAY_BUFFER, m->ebo_line);
                glDrawElements (GL_LINES, m->nline, GL_UNSIGNED_INT, NULL);
            }
        }
        glDisable (GL_BLEND);
    }

    if (!f->transparent && (f->shadow || f->grid)) {
        glUseProgram (r->p_floor);
        set_mat (r->p_floor, "u_vp", r->vp);
        set_mat (r->p_floor, "u_light", r->light);
        glUniform4f (glGetUniformLocation (r->p_floor, "u_floor"), f->center[0], f->floor_y, f->center[2], rad * 12);
        glUniform1f (glGetUniformLocation (r->p_floor, "u_radius"), rad);
        glUniform1i (glGetUniformLocation (r->p_floor, "u_grid"), f->grid);
        glUniform1i (glGetUniformLocation (r->p_floor, "u_shadow_on"), f->shadow && f->eye[1] > f->floor_y);
        glUniform3fv (glGetUniformLocation (r->p_floor, "u_key"), 1, r->key);
        glActiveTexture (GL_TEXTURE1);
        glBindTexture (GL_TEXTURE_2D, r->tex_shadow);
        glUniform1i (glGetUniformLocation (r->p_floor, "u_shadow"), 1);
        glActiveTexture (GL_TEXTURE0);
        glEnable (GL_BLEND);
        glBlendFuncSeparate (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glDepthMask (GL_FALSE);
        glBindVertexArray (r->quad_vao);
        glDrawArrays (GL_TRIANGLE_STRIP, 0, 4);
        glDepthMask (GL_TRUE);
        glDisable (GL_BLEND);
    }
    glBindVertexArray (0);
}

static float *scratch (SgRender *r, int floats) {
    if (floats > r->scratch_cap) {
        r->scratch_cap = floats * 2;
        r->scratch = realloc (r->scratch, (size_t) r->scratch_cap * sizeof (float));
    }
    return r->scratch;
}

static void clip_of (const float *vp, const float *p, float *o) {
    for (int i = 0; i < 4; i++) o[i] = vp[i] * p[0] + vp[4 + i] * p[1] + vp[8 + i] * p[2] + vp[12 + i];
}

static float *emit (float *o, const float *clip, float dx, float dy, const float *col, float cx, float cy, float zbias) {
    o[0] = clip[0] + dx * clip[3];
    o[1] = clip[1] + dy * clip[3];
    o[2] = clip[2] - zbias * clip[3];
    o[3] = clip[3];
    memcpy (o + 4, col, 4 * sizeof (float));
    o[8] = cx;
    o[9] = cy;
    return o + 10;
}

void sg_render_overlay (SgRender *r, const float *v, int count, int prim, float size, int depth) {
    if (count <= 0) return;
    float zbias = depth ? 0.0006f : 0;
    float px = size / r->w, py = size / r->h;
    float *buf = NULL, *o = NULL;
    int round = 0;
    if (prim == 0) {
        buf = o = scratch (r, count * 6 * 10);
        round = 1;
        for (int i = 0; i < count; i++) {
            float c[4];
            clip_of (r->vp, v + i * 7, c);
            if (c[3] <= 1e-3f) continue;
            const float *col = v + i * 7 + 3;
            o = emit (o, c, -px, -py, col, -1, -1, zbias);
            o = emit (o, c, px, -py, col, 1, -1, zbias);
            o = emit (o, c, px, py, col, 1, 1, zbias);
            o = emit (o, c, -px, -py, col, -1, -1, zbias);
            o = emit (o, c, px, py, col, 1, 1, zbias);
            o = emit (o, c, -px, py, col, -1, 1, zbias);
        }
    } else if (prim == 1) {
        buf = o = scratch (r, count * 3 * 10);
        for (int i = 0; i + 1 < count; i += 2) {
            float a[4], b[4];
            clip_of (r->vp, v + i * 7, a);
            clip_of (r->vp, v + (i + 1) * 7, b);
            float ca[4], cb[4];
            memcpy (ca, v + i * 7 + 3, sizeof ca);
            memcpy (cb, v + (i + 1) * 7 + 3, sizeof cb);
            float near = 1e-2f;
            if (a[3] < near && b[3] < near) continue;
            if (a[3] < near || b[3] < near) {
                float t = (near - a[3]) / (b[3] - a[3]);
                float m[4];
                for (int k = 0; k < 4; k++) m[k] = a[k] + (b[k] - a[k]) * t;
                if (a[3] < near) memcpy (a, m, sizeof m);
                else memcpy (b, m, sizeof m);
            }
            float ax = a[0] / a[3] * r->w, ay = a[1] / a[3] * r->h, bx = b[0] / b[3] * r->w, by = b[1] / b[3] * r->h;
            float dx = bx - ax, dy = by - ay;
            float l = sqrtf (dx * dx + dy * dy);
            if (l < 1e-6f) continue;
            float nx = -dy / l * size / r->w, ny = dx / l * size / r->h;
            o = emit (o, a, nx, ny, ca, 0, 0, zbias);
            o = emit (o, a, -nx, -ny, ca, 0, 0, zbias);
            o = emit (o, b, nx, ny, cb, 0, 0, zbias);
            o = emit (o, a, -nx, -ny, ca, 0, 0, zbias);
            o = emit (o, b, -nx, -ny, cb, 0, 0, zbias);
            o = emit (o, b, nx, ny, cb, 0, 0, zbias);
        }
    } else {
        buf = o = scratch (r, count * 10);
        for (int i = 0; i < count; i++) {
            float c[4];
            clip_of (r->vp, v + i * 7, c);
            o = emit (o, c, 0, 0, v + i * 7 + 3, 0, 0, zbias);
        }
    }
    int n = (int) ((o - buf) / 10);
    if (n == 0) return;
    glBindFramebuffer (GL_FRAMEBUFFER, r->fbo_ms);
    glUseProgram (r->p_overlay);
    glUniform1i (glGetUniformLocation (r->p_overlay, "u_round"), round);
    if (depth) glEnable (GL_DEPTH_TEST);
    else glDisable (GL_DEPTH_TEST);
    glDepthMask (GL_FALSE);
    glDisable (GL_CULL_FACE);
    glEnable (GL_BLEND);
    glBlendFuncSeparate (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glBindVertexArray (r->ov_vao);
    glBindBuffer (GL_ARRAY_BUFFER, r->ov_vbo);
    glBufferData (GL_ARRAY_BUFFER, (GLsizeiptr) n * 10 * sizeof (float), buf, GL_STREAM_DRAW);
    glDrawArrays (GL_TRIANGLES, 0, n);
    glBindVertexArray (0);
    glDisable (GL_BLEND);
    glDepthMask (GL_TRUE);
    glEnable (GL_DEPTH_TEST);
}

void sg_render_end (SgRender *r, int target_fbo, int dw, int dh) {
    glBindFramebuffer (GL_READ_FRAMEBUFFER, r->fbo_ms);
    glBindFramebuffer (GL_DRAW_FRAMEBUFFER, (GLuint) target_fbo);
    if (dw <= 0 || dh <= 0 || r->samples > 1) {
        dw = r->w;
        dh = r->h;
    }
    glBlitFramebuffer (0, 0, r->w, r->h, 0, 0, dw, dh, GL_COLOR_BUFFER_BIT, dw == r->w && dh == r->h ? GL_NEAREST : GL_LINEAR);
    glBindFramebuffer (GL_FRAMEBUFFER, (GLuint) target_fbo);
    glUseProgram (0);
}

int sg_render_bound_fbo (void) {
    GLint fbo = 0;
    glGetIntegerv (GL_DRAW_FRAMEBUFFER_BINDING, &fbo);
    return (int) fbo;
}

void sg_render_read (SgRender *r, unsigned char *rgba) {
    sg_render_end (r, (int) r->fbo_resolve, 0, 0);
    glBindFramebuffer (GL_READ_FRAMEBUFFER, r->fbo_resolve);
    glPixelStorei (GL_PACK_ALIGNMENT, 1);
    glReadPixels (0, 0, r->w, r->h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    glBindFramebuffer (GL_READ_FRAMEBUFFER, 0);
}
