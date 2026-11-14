namespace Singularity.Scene {

    public struct Vec3 {
        public double x;
        public double y;
        public double z;

        public Vec3 (double x, double y, double z) {
            this.x = x;
            this.y = y;
            this.z = z;
        }

        public Vec3 add (Vec3 o) {
            return Vec3 (x + o.x, y + o.y, z + o.z);
        }

        public Vec3 sub (Vec3 o) {
            return Vec3 (x - o.x, y - o.y, z - o.z);
        }

        public Vec3 scale (double s) {
            return Vec3 (x * s, y * s, z * s);
        }

        public double dot (Vec3 o) {
            return x * o.x + y * o.y + z * o.z;
        }

        public Vec3 cross (Vec3 o) {
            return Vec3 (y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
        }

        public double length () {
            return Math.sqrt (x * x + y * y + z * z);
        }

        public Vec3 normalized () {
            double l = length ();
            return l > 1e-12 ? scale (1 / l) : Vec3 (0, 0, 0);
        }

        public double distance (Vec3 o) {
            return sub (o).length ();
        }

        public Vec3 lerp (Vec3 o, double t) {
            return Vec3 (x + (o.x - x) * t, y + (o.y - y) * t, z + (o.z - z) * t);
        }
    }

    public struct Ray {
        public Vec3 origin;
        public Vec3 direction;

        public Vec3 at (double t) {
            return origin.add (direction.scale (t));
        }

        public bool plane (Vec3 point, Vec3 normal, out Vec3 hit) {
            hit = origin;
            double den = direction.dot (normal);
            if (den.abs () < 1e-9) return false;
            double t = point.sub (origin).dot (normal) / den;
            if (t <= 0) return false;
            hit = at (t);
            return true;
        }

        public double segment_distance (Vec3 a, Vec3 b, out double along) {
            var u = direction;
            var v = b.sub (a);
            var w = origin.sub (a);
            double uu = u.dot (u), uv = u.dot (v), vv = v.dot (v), uw = u.dot (w), vw = v.dot (w);
            double den = uu * vv - uv * uv;
            double s = den > 1e-12 ? ((uu * vw - uv * uw) / den).clamp (0, 1) : 0;
            double t = double.max (0, (uv * s - uw) / uu);
            along = s;
            return at (t).distance (a.add (v.scale (s)));
        }
    }

    public struct Hit {
        public Mesh? mesh;
        public int triangle;
        public double distance;
        public double u;
        public double v;
        public Vec3 point;

        public int nearest_vertex () {
            if (mesh == null || triangle < 0) return -1;
            double w = 1 - u - v;
            int k = w >= u && w >= v ? 0 : (u >= v ? 1 : 2);
            return (int) mesh.triangles[triangle * 3 + k];
        }
    }

    public enum Shading {
        SURFACE = 0,
        RAMP = 1,
        ZEBRA = 2,
        CLAY = 3,
        FLAT = 4
    }

    public class Material : Object {
        public Gdk.RGBA color = Gdk.RGBA () { red = 0.8f, green = 0.8f, blue = 0.8f, alpha = 1 };
        public Gdk.RGBA? back_color;
        public double roughness = 0.7;
        public double metallic;
        public double sheen;
        public double weave;
        public double weave_scale = 1.6;
        public double clearcoat;
        public Gdk.Pixbuf? texture;
        public double texture_size = 100;
        public Shading shading = Shading.SURFACE;
        public bool double_sided = true;
        public bool cast_shadow = true;

        public Material copy () {
            var m = new Material ();
            m.color = color;
            m.back_color = back_color;
            m.roughness = roughness;
            m.metallic = metallic;
            m.sheen = sheen;
            m.weave = weave;
            m.weave_scale = weave_scale;
            m.clearcoat = clearcoat;
            m.texture = texture;
            m.texture_size = texture_size;
            m.shading = shading;
            m.double_sided = double_sided;
            m.cast_shadow = cast_shadow;
            return m;
        }
    }

    public class Mesh : Object {
        public string name = "";
        public float[] positions = {};
        public float[] normals = {};
        public float[] uvs = {};
        public float[] scalars = {};
        public uint[] triangles = {};
        public uint[] lines = {};
        public Material material = new Material ();
        public bool visible = true;
        public bool pickable = true;
        public uint geometry_serial = 1;
        public uint position_serial = 1;

        public int vertex_count {
            get { return positions.length / 3; }
        }

        public int triangle_count {
            get { return triangles.length / 3; }
        }

        public void touch_geometry () {
            geometry_serial++;
        }

        public void touch_positions () {
            position_serial++;
        }

        public Vec3 vertex (int i) {
            return Vec3 (positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]);
        }

        public void set_vertex (int i, Vec3 p) {
            positions[i * 3] = (float) p.x;
            positions[i * 3 + 1] = (float) p.y;
            positions[i * 3 + 2] = (float) p.z;
        }

        public void compute_normals () {
            int nv = positions.length / 3;
            if (normals.length != nv * 3) normals = new float[nv * 3];
            else Memory.set (normals, 0, nv * 3 * sizeof (float));
            unowned float[] p = positions;
            unowned float[] n = normals;
            int nt = triangles.length;
            for (int t = 0; t + 2 < nt; t += 3) {
                uint a = triangles[t] * 3, b = triangles[t + 1] * 3, c = triangles[t + 2] * 3;
                float e1x = p[b] - p[a], e1y = p[b + 1] - p[a + 1], e1z = p[b + 2] - p[a + 2];
                float e2x = p[c] - p[a], e2y = p[c + 1] - p[a + 1], e2z = p[c + 2] - p[a + 2];
                float nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x;
                n[a] += nx; n[a + 1] += ny; n[a + 2] += nz;
                n[b] += nx; n[b + 1] += ny; n[b + 2] += nz;
                n[c] += nx; n[c + 1] += ny; n[c + 2] += nz;
            }
            for (int i = 0; i < nv * 3; i += 3) {
                float l = Math.sqrtf (n[i] * n[i] + n[i + 1] * n[i + 1] + n[i + 2] * n[i + 2]);
                if (l > 1e-20f) {
                    n[i] /= l;
                    n[i + 1] /= l;
                    n[i + 2] /= l;
                } else {
                    n[i + 1] = 1;
                }
            }
        }

        public bool bounds (out Vec3 min, out Vec3 max) {
            double ax = double.INFINITY, ay = double.INFINITY, az = double.INFINITY;
            double bx = -double.INFINITY, by = -double.INFINITY, bz = -double.INFINITY;
            for (int i = 0; i + 2 < positions.length; i += 3) {
                double x = positions[i], y = positions[i + 1], z = positions[i + 2];
                if (x < ax) ax = x;
                if (y < ay) ay = y;
                if (z < az) az = z;
                if (x > bx) bx = x;
                if (y > by) by = y;
                if (z > bz) bz = z;
            }
            min = Vec3 (ax, ay, az);
            max = Vec3 (bx, by, bz);
            return positions.length >= 3;
        }

        public bool intersect (Ray ray, ref Hit best) {
            unowned float[] p = positions;
            double ox = ray.origin.x, oy = ray.origin.y, oz = ray.origin.z;
            double dx = ray.direction.x, dy = ray.direction.y, dz = ray.direction.z;
            bool found = false;
            int nt = triangles.length;
            for (int t = 0; t + 2 < nt; t += 3) {
                uint a = triangles[t] * 3, b = triangles[t + 1] * 3, c = triangles[t + 2] * 3;
                double e1x = p[b] - p[a], e1y = p[b + 1] - p[a + 1], e1z = p[b + 2] - p[a + 2];
                double e2x = p[c] - p[a], e2y = p[c + 1] - p[a + 1], e2z = p[c + 2] - p[a + 2];
                double px = dy * e2z - dz * e2y, py = dz * e2x - dx * e2z, pz = dx * e2y - dy * e2x;
                double det = e1x * px + e1y * py + e1z * pz;
                if (det > -1e-12 && det < 1e-12) continue;
                double inv = 1 / det;
                double tx = ox - p[a], ty = oy - p[a + 1], tz = oz - p[a + 2];
                double u = (tx * px + ty * py + tz * pz) * inv;
                if (u < 0 || u > 1) continue;
                double qx = ty * e1z - tz * e1y, qy = tz * e1x - tx * e1z, qz = tx * e1y - ty * e1x;
                double v = (dx * qx + dy * qy + dz * qz) * inv;
                if (v < 0 || u + v > 1) continue;
                double d = (e2x * qx + e2y * qy + e2z * qz) * inv;
                if (d <= 1e-6 || d >= best.distance) continue;
                best.mesh = this;
                best.triangle = t / 3;
                best.distance = d;
                best.u = u;
                best.v = v;
                best.point = ray.at (d);
                found = true;
            }
            return found;
        }
    }

    public class Camera : Object {
        public Vec3 target = Vec3 (0, 0, 0);
        public double yaw;
        public double pitch = 0.12;
        public double distance = 3000;
        public double fov = 32;

        public Camera copy () {
            var c = new Camera ();
            c.target = target;
            c.yaw = yaw;
            c.pitch = pitch;
            c.distance = distance;
            c.fov = fov;
            return c;
        }

        public Vec3 eye () {
            return target.add (Vec3 (Math.cos (pitch) * Math.sin (yaw), Math.sin (pitch), Math.cos (pitch) * Math.cos (yaw)).scale (distance));
        }

        public void basis (out Vec3 right, out Vec3 up, out Vec3 forward) {
            forward = target.sub (eye ()).normalized ();
            right = forward.cross (Vec3 (0, 1, 0)).normalized ();
            if (right.length () < 0.5) right = Vec3 (1, 0, 0);
            up = right.cross (forward).normalized ();
        }

        public Ray ray (double x, double y, int width, int height) {
            Vec3 r, u, f;
            basis (out r, out u, out f);
            double focal = (height / 2.0) / Math.tan (fov * Math.PI / 360);
            var dir = f.add (r.scale ((x - width / 2.0) / focal)).add (u.scale (-(y - height / 2.0) / focal)).normalized ();
            return Ray () { origin = eye (), direction = dir };
        }

        public bool project (Vec3 p, int width, int height, out double sx, out double sy, out double depth) {
            Vec3 r, u, f;
            basis (out r, out u, out f);
            var d = p.sub (eye ());
            double z = d.dot (f);
            double focal = (height / 2.0) / Math.tan (fov * Math.PI / 360);
            depth = z;
            sx = 0;
            sy = 0;
            if (z < 1e-6) return false;
            sx = width / 2.0 + d.dot (r) / z * focal;
            sy = height / 2.0 - d.dot (u) / z * focal;
            return true;
        }

        public double units_per_pixel (Vec3 at, int height) {
            Vec3 r, u, f;
            basis (out r, out u, out f);
            double z = double.max (1e-6, at.sub (eye ()).dot (f));
            return z * Math.tan (fov * Math.PI / 360) * 2 / int.max (1, height);
        }

        public void frame (Vec3 min, Vec3 max) {
            target = min.add (max).scale (0.5);
            double radius = max.sub (min).length () / 2;
            distance = double.max (10, radius / Math.sin (fov * Math.PI / 360) * 1.05);
        }

        public Camera blend (Camera to, double t) {
            var c = new Camera ();
            c.target = target.lerp (to.target, t);
            double dy = to.yaw - yaw;
            while (dy > Math.PI) dy -= 2 * Math.PI;
            while (dy < -Math.PI) dy += 2 * Math.PI;
            c.yaw = yaw + dy * t;
            c.pitch = pitch + (to.pitch - pitch) * t;
            c.distance = distance * Math.pow (to.distance / distance, t);
            c.fov = fov + (to.fov - fov) * t;
            return c;
        }
    }

    public class Overlay : Object {
        internal class Batch {
            public int prim;
            public float size;
            public bool depth;
            public float[] data = new float[256];
            public int used;

            public void push (Vec3 p, Gdk.RGBA c) {
                if (used + 7 > data.length) data.resize (data.length * 2);
                data[used++] = (float) p.x;
                data[used++] = (float) p.y;
                data[used++] = (float) p.z;
                data[used++] = c.red;
                data[used++] = c.green;
                data[used++] = c.blue;
                data[used++] = c.alpha;
            }
        }

        internal GenericArray<Batch> batches = new GenericArray<Batch> ();

        private Batch batch (int prim, double size, bool depth) {
            for (int i = 0; i < batches.length; i++) {
                var b = batches[i];
                if (b.prim == prim && b.size == (float) size && b.depth == depth) return b;
            }
            var b = new Batch ();
            b.prim = prim;
            b.size = (float) size;
            b.depth = depth;
            batches.add (b);
            return b;
        }

        public void point (Vec3 p, Gdk.RGBA color, double size = 8, bool depth = false) {
            batch (0, size, depth).push (p, color);
        }

        public void line (Vec3 a, Vec3 b, Gdk.RGBA color, double width = 2, bool depth = false) {
            var bt = batch (1, width, depth);
            bt.push (a, color);
            bt.push (b, color);
        }

        public void polyline (Vec3[] pts, Gdk.RGBA color, double width = 2, bool depth = false, bool closed = false) {
            var bt = batch (1, width, depth);
            for (int i = 0; i + 1 < pts.length; i++) {
                bt.push (pts[i], color);
                bt.push (pts[i + 1], color);
            }
            if (closed && pts.length > 2) {
                bt.push (pts[pts.length - 1], color);
                bt.push (pts[0], color);
            }
        }

        public void triangle (Vec3 a, Vec3 b, Vec3 c, Gdk.RGBA color, bool depth = false) {
            var bt = batch (2, 0, depth);
            bt.push (a, color);
            bt.push (b, color);
            bt.push (c, color);
        }

        public void circle (Vec3 center, Vec3 normal, double radius, Gdk.RGBA color, double width = 2, bool depth = false) {
            var n = normal.normalized ();
            var a = (n.x.abs () < 0.9 ? Vec3 (1, 0, 0) : Vec3 (0, 1, 0)).cross (n).normalized ();
            var b = n.cross (a);
            var bt = batch (1, width, depth);
            Vec3 prev = center.add (a.scale (radius));
            for (int i = 1; i <= 64; i++) {
                double t = 2 * Math.PI * i / 64;
                var p = center.add (a.scale (radius * Math.cos (t))).add (b.scale (radius * Math.sin (t)));
                bt.push (prev, color);
                bt.push (p, color);
                prev = p;
            }
        }
    }
}
