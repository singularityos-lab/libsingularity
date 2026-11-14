namespace Singularity.Scene {

    public class SceneView : Gtk.GLArea {
        public Camera camera = new Camera ();
        public bool orbit_with_primary = true;
        public bool orbit_with_secondary = true;
        public bool shadows = true;
        public bool grid = true;
        public bool wireframe;
        public int shading_override = -1;
        public bool auto_background = true;
        public Gdk.RGBA background_top = Gdk.RGBA () { red = 0.93f, green = 0.94f, blue = 0.96f, alpha = 1 };
        public Gdk.RGBA background_bottom = Gdk.RGBA () { red = 0.76f, green = 0.78f, blue = 0.82f, alpha = 1 };
        public bool auto_floor = true;
        public double floor_y;
        public double ramp_min;
        public double ramp_max = 1;
        public double min_distance = 20;
        public double max_distance = 200000;
        public double frame_ms { get; private set; }
        public bool adaptive_quality = true;
        public int quality_level { get; private set; }
        private double frame_average;
        private int frames_at_level;
        private int active_level;
        private int64 last_frame;
        private uint settle_id;

        public signal void overlay (Overlay o);
        public signal bool pressed (double x, double y, uint button, Gdk.ModifierType state);
        public signal void dragged (double x, double y, Gdk.ModifierType state);
        public signal void released (double x, double y, uint button);
        public signal void hover (double x, double y);
        public signal void failed (string message);
        public signal void camera_changed ();

        private class Gpu {
            public int id;
            public uint geometry_serial;
            public uint position_serial;
            public uint seen;
        }

        private enum Drag {
            NONE,
            TOOL,
            ORBIT,
            PAN,
            DOLLY
        }

        private SgScene.Render? renderer;
        private GenericArray<Mesh> list = new GenericArray<Mesh> ();
        private HashTable<Mesh, Gpu> gpu = new HashTable<Mesh, Gpu> (direct_hash, direct_equal);
        private HashTable<Gdk.Pixbuf, int> textures = new HashTable<Gdk.Pixbuf, int> (direct_hash, direct_equal);
        private uint frame_no;
        private Drag drag_mode = Drag.NONE;
        private uint drag_button;
        private Camera? drag_start;
        private double zoom_start;
        private double rotate_last;
        private double pinch_x;
        private double pinch_y;
        private uint tick_id;
        private Camera? anim_from;
        private Camera? anim_to;
        private int64 anim_begin;
        private int64 anim_length;

        public SceneView () {
            hexpand = true;
            vexpand = true;
            focusable = true;
            has_depth_buffer = false;

            var drag = new Gtk.GestureDrag ();
            drag.button = 0;
            drag.drag_begin.connect ((x, y) => {
                grab_focus ();
                stop_animation ();
                drag_button = drag.get_current_button ();
                var state = drag.get_current_event_state ();
                drag_start = camera.copy ();
                if (pressed (x, y, drag_button, state)) {
                    drag_mode = Drag.TOOL;
                    return;
                }
                bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
                bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
                bool orbit = (drag_button == Gdk.BUTTON_PRIMARY && orbit_with_primary) || (drag_button == Gdk.BUTTON_SECONDARY && orbit_with_secondary);
                if (drag_button == Gdk.BUTTON_MIDDLE) drag_mode = ctrl ? Drag.DOLLY : Drag.PAN;
                else if (orbit) drag_mode = shift ? Drag.PAN : (ctrl ? Drag.DOLLY : Drag.ORBIT);
                else drag_mode = Drag.NONE;
            });
            drag.drag_update.connect ((dx, dy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                switch (drag_mode) {
                    case Drag.TOOL:
                        dragged (sx + dx, sy + dy, drag.get_current_event_state ());
                        break;
                    case Drag.ORBIT:
                        camera.yaw = drag_start.yaw - dx * 0.008;
                        camera.pitch = (drag_start.pitch + dy * 0.008).clamp (-1.5, 1.5);
                        changed ();
                        break;
                    case Drag.PAN:
                        pan_from (drag_start, dx, dy);
                        changed ();
                        break;
                    case Drag.DOLLY:
                        camera.distance = (drag_start.distance * Math.pow (1.006, dy)).clamp (min_distance, max_distance);
                        changed ();
                        break;
                    default:
                        break;
                }
            });
            drag.drag_end.connect ((dx, dy) => {
                double sx, sy;
                drag.get_start_point (out sx, out sy);
                if (drag_mode == Drag.TOOL) released (sx + dx, sy + dy, drag_button);
                drag_mode = Drag.NONE;
                drag_start = null;
            });
            add_controller (drag);

            var motion = new Gtk.EventControllerMotion ();
            motion.motion.connect ((x, y) => {
                if (drag_mode == Drag.NONE) hover (x, y);
            });
            add_controller (motion);

            var scroll = new Gtk.EventControllerScroll (Gtk.EventControllerScrollFlags.VERTICAL);
            scroll.scroll.connect ((dx, dy) => {
                stop_animation ();
                zoom_about (Math.pow (1.12, dy), pointer_x, pointer_y);
                return true;
            });
            add_controller (scroll);
            var track = new Gtk.EventControllerMotion ();
            track.motion.connect ((x, y) => {
                pointer_x = x;
                pointer_y = y;
            });
            add_controller (track);

            var zoom = new Gtk.GestureZoom ();
            zoom.begin.connect ((seq) => {
                zoom_start = camera.distance;
                drag_start = camera.copy ();
                zoom.get_bounding_box_center (out pinch_x, out pinch_y);
            });
            zoom.scale_changed.connect ((scale) => {
                if (drag_start == null) return;
                double cx = 0, cy = 0;
                if (zoom.get_bounding_box_center (out cx, out cy)) pan_from (drag_start, cx - pinch_x, cy - pinch_y);
                if (scale > 0) camera.distance = (zoom_start / scale).clamp (min_distance, max_distance);
                changed ();
            });
            add_controller (zoom);
            var rotate = new Gtk.GestureRotate ();
            rotate.begin.connect ((seq) => rotate_last = 0);
            rotate.angle_changed.connect ((angle, delta) => {
                camera.yaw -= delta - rotate_last;
                rotate_last = delta;
                changed ();
            });
            add_controller (rotate);
        }

        private double pointer_x;
        private double pointer_y;

        private void changed () {
            camera_changed ();
            queue_render ();
        }

        private void pan_from (Camera start, double dx, double dy) {
            Vec3 r, u, f;
            start.basis (out r, out u, out f);
            double k = start.distance * Math.tan (start.fov * Math.PI / 360) * 2 / int.max (1, get_height ());
            camera.target = start.target.sub (r.scale (dx * k)).add (u.scale (dy * k));
        }

        public void zoom_about (double factor, double x, double y) {
            double next = (camera.distance * factor).clamp (min_distance, max_distance);
            double k = next / camera.distance;
            Vec3 r, u, f;
            camera.basis (out r, out u, out f);
            Vec3 anchor;
            if (camera.ray (x, y, get_width (), get_height ()).plane (camera.target, f, out anchor)) {
                camera.target = anchor.add (camera.target.sub (anchor).scale (k));
            }
            camera.distance = next;
            changed ();
        }

        public void add (Mesh mesh) {
            list.add (mesh);
            queue_render ();
        }

        public void remove (Mesh mesh) {
            list.remove (mesh);
            queue_render ();
        }

        public void clear () {
            list = new GenericArray<Mesh> ();
            queue_render ();
        }

        public bool has (Mesh mesh) {
            return list.find (mesh);
        }

        public unowned GenericArray<Mesh> meshes () {
            return list;
        }

        public bool scene_bounds (out Vec3 min, out Vec3 max) {
            min = Vec3 (double.INFINITY, double.INFINITY, double.INFINITY);
            max = Vec3 (-double.INFINITY, -double.INFINITY, -double.INFINITY);
            bool any = false;
            for (int i = 0; i < list.length; i++) {
                var m = list[i];
                Vec3 a, b;
                if (!m.visible) continue;
                if (!m.bounds (out a, out b)) continue;
                min = Vec3 (double.min (min.x, a.x), double.min (min.y, a.y), double.min (min.z, a.z));
                max = Vec3 (double.max (max.x, b.x), double.max (max.y, b.y), double.max (max.z, b.z));
                any = true;
            }
            return any;
        }

        public void frame_all (bool animate = false) {
            Vec3 min, max;
            if (!scene_bounds (out min, out max)) return;
            var c = camera.copy ();
            c.frame (min, max);
            if (animate) animate_to (c);
            else {
                camera = c;
                changed ();
            }
        }

        public void animate_to (Camera to, uint ms = 260) {
            stop_animation ();
            anim_from = camera.copy ();
            anim_to = to.copy ();
            anim_begin = get_frame_clock () != null ? get_frame_clock ().get_frame_time () : 0;
            anim_length = (int64) ms * 1000;
            tick_id = add_tick_callback ((w, clock) => {
                double t = ((double) (clock.get_frame_time () - anim_begin) / anim_length).clamp (0, 1);
                double e = 1 - Math.pow (1 - t, 3);
                camera = anim_from.blend (anim_to, e);
                changed ();
                if (t < 1) return Source.CONTINUE;
                tick_id = 0;
                return Source.REMOVE;
            });
        }

        private void stop_animation () {
            if (tick_id == 0) return;
            remove_tick_callback (tick_id);
            tick_id = 0;
        }

        public Ray ray (double x, double y) {
            return camera.ray (x, y, get_width (), get_height ());
        }

        public bool pick_at (double x, double y, out Hit hit) {
            return pick_ray (ray (x, y), out hit);
        }

        public bool pick_ray (Ray r, out Hit hit) {
            hit = Hit () { mesh = null, triangle = -1, distance = double.INFINITY };
            for (int i = 0; i < list.length; i++) {
                var m = list[i];
                if (m.visible && m.pickable) m.intersect (r, ref hit);
            }
            return hit.mesh != null;
        }

        public bool project (Vec3 p, out double x, out double y) {
            double d;
            return camera.project (p, get_width (), get_height (), out x, out y, out d);
        }

        public override void realize () {
            base.realize ();
            make_current ();
            if (get_error () != null) {
                failed (get_error ().message);
                return;
            }
            renderer = new SgScene.Render (get_context ().get_use_es () ? 1 : 0);
            unowned string? err = renderer.error ();
            if (err != null) {
                warning ("scene renderer: %s", err);
                failed (err);
            }
        }

        public override void unrealize () {
            if (settle_id != 0) Source.remove (settle_id);
            settle_id = 0;
            make_current ();
            renderer = null;
            gpu.remove_all ();
            textures.remove_all ();
            base.unrealize ();
        }

        private int texture_of (Gdk.Pixbuf? pix) {
            if (pix == null) return 0;
            if (textures.contains (pix)) return textures[pix];
            var rgba = pix.has_alpha && pix.n_channels == 4 ? pix : pix.add_alpha (false, 0, 0, 0);
            int w = rgba.width, h = rgba.height;
            var data = new uint8[w * h * 4];
            unowned uint8[] src = rgba.get_pixels ();
            int stride = rgba.rowstride;
            for (int y = 0; y < h; y++) Memory.copy (&data[y * w * 4], &src[y * stride], w * 4);
            int id = renderer.texture (data, w, h);
            textures[pix] = id;
            return id;
        }

        private void sync () {
            frame_no++;
            for (int i = 0; i < list.length; i++) {
                var m = list[i];
                int nv = m.vertex_count;
                if (nv == 0) continue;
                Gpu? g = gpu[m];
                if (g == null) {
                    g = new Gpu ();
                    g.id = renderer.mesh_new ();
                    gpu[m] = g;
                }
                g.seen = frame_no;
                if (m.normals.length != nv * 3 && m.triangles.length > 0) m.compute_normals ();
                bool has_n = m.normals.length == nv * 3;
                bool has_s = m.scalars.length == nv;
                if (g.geometry_serial != m.geometry_serial) {
                    renderer.mesh_geometry (g.id, m.positions, has_n ? m.normals : null, m.uvs.length == nv * 2 ? m.uvs : null, has_s ? m.scalars : null, nv,
                                            m.triangles, m.triangles.length, m.lines.length > 0 ? m.lines : null, m.lines.length);
                    g.geometry_serial = m.geometry_serial;
                    g.position_serial = m.position_serial;
                } else if (g.position_serial != m.position_serial) {
                    renderer.mesh_update (g.id, m.positions, has_n ? m.normals : null, has_s ? m.scalars : null, nv);
                    g.position_serial = m.position_serial;
                }
                var mat = SgScene.Material ();
                var src = m.material;
                mat.color[0] = src.color.red;
                mat.color[1] = src.color.green;
                mat.color[2] = src.color.blue;
                mat.color[3] = src.color.alpha;
                if (src.back_color != null) {
                    mat.back[0] = src.back_color.red;
                    mat.back[1] = src.back_color.green;
                    mat.back[2] = src.back_color.blue;
                    mat.back[3] = src.back_color.alpha;
                } else {
                    mat.back[0] = src.color.red * 0.82f;
                    mat.back[1] = src.color.green * 0.82f;
                    mat.back[2] = src.color.blue * 0.82f;
                    mat.back[3] = src.color.alpha;
                }
                mat.roughness = (float) src.roughness;
                mat.metallic = (float) src.metallic;
                mat.sheen = (float) src.sheen;
                mat.weave = (float) src.weave;
                mat.weave_scale = (float) src.weave_scale;
                mat.clearcoat = (float) src.clearcoat;
                mat.texture = texture_of (src.texture);
                mat.tex_scale = (float) (1 / double.max (1e-6, src.texture_size));
                mat.mode = shading_override >= 0 && src.shading != Shading.FLAT ? shading_override : (int) src.shading;
                mat.double_sided = src.double_sided ? 1 : 0;
                mat.cast_shadow = src.cast_shadow ? 1 : 0;
                renderer.mesh_material (g.id, mat);
                renderer.mesh_visible (g.id, m.visible ? 1 : 0);
            }
            var stale = new GenericArray<Mesh> ();
            gpu.foreach ((m, g) => {
                if (g.seen != frame_no) stale.add (m);
            });
            for (int i = 0; i < stale.length; i++) {
                renderer.mesh_free (gpu[stale[i]].id);
                gpu.remove (stale[i]);
            }
        }

        private void resolve_background (out Gdk.RGBA top, out Gdk.RGBA bottom) {
            top = background_top;
            bottom = background_bottom;
            if (!auto_background) return;
            var fg = get_color ();
            if (0.299 * fg.red + 0.587 * fg.green + 0.114 * fg.blue > 0.6) {
                top = Gdk.RGBA () { red = 0.20f, green = 0.21f, blue = 0.24f, alpha = 1 };
                bottom = Gdk.RGBA () { red = 0.10f, green = 0.105f, blue = 0.12f, alpha = 1 };
            }
        }

        private void draw_scene (Camera cam, int w, int h, bool transparent, bool with_overlay) {
            sync ();
            var f = SgScene.Frame ();
            var eye = cam.eye ();
            f.eye[0] = (float) eye.x;
            f.eye[1] = (float) eye.y;
            f.eye[2] = (float) eye.z;
            f.target[0] = (float) cam.target.x;
            f.target[1] = (float) cam.target.y;
            f.target[2] = (float) cam.target.z;
            f.fov = (float) cam.fov;
            Gdk.RGBA top, bottom;
            resolve_background (out top, out bottom);
            f.top[0] = top.red;
            f.top[1] = top.green;
            f.top[2] = top.blue;
            f.bottom[0] = bottom.red;
            f.bottom[1] = bottom.green;
            f.bottom[2] = bottom.blue;
            Vec3 min, max;
            if (scene_bounds (out min, out max)) {
                var c = min.add (max).scale (0.5);
                f.center[0] = (float) c.x;
                f.center[1] = (float) c.y;
                f.center[2] = (float) c.z;
                f.radius = (float) double.max (1, max.sub (min).length () / 2);
                f.floor_y = (float) (auto_floor ? min.y : floor_y);
            } else {
                f.radius = 1000;
                f.floor_y = (float) floor_y;
            }
            f.ramp_min = (float) ramp_min;
            f.ramp_max = (float) ramp_max;
            f.shadow = shadows && (transparent || !with_overlay || active_level < 3) ? 1 : 0;
            f.grid = grid ? 1 : 0;
            f.wire = wireframe ? 1 : 0;
            f.transparent = transparent ? 1 : 0;
            f.samples = with_overlay && active_level > 0 ? 0 : 4;
            renderer.begin (f, w, h);
            if (!with_overlay) return;
            var o = new Overlay ();
            overlay (o);
            for (int i = 0; i < o.batches.length; i++) {
                var b = o.batches[i];
                renderer.overlay (b.data, b.used / 7, b.prim, (float) (b.size * get_scale_factor () * (active_level >= 3 ? 0.5 : (active_level == 2 ? 0.7 : 1))), b.depth ? 1 : 0);
            }
        }

        public override bool render (Gdk.GLContext context) {
            if (renderer == null) return true;
            int64 t0 = get_monotonic_time ();
            int scale = get_scale_factor ();
            int w = int.max (1, get_width () * scale), h = int.max (1, get_height () * scale);
            int target = SgScene.Render.bound_fbo ();
            bool still = t0 - last_frame > 300000;
            active_level = still ? 0 : quality_level;
            double shrink = active_level >= 3 ? 0.5 : (active_level == 2 ? 0.7 : 1);
            draw_scene (camera, int.max (1, (int) (w * shrink)), int.max (1, (int) (h * shrink)), false, true);
            renderer.end (target, w, h);
            last_frame = get_monotonic_time ();
            frame_ms = (last_frame - t0) / 1000.0;
            if (adaptive_quality && !still) {
                frame_average = frames_at_level == 0 ? frame_ms : frame_average * 0.7 + frame_ms * 0.3;
                frames_at_level++;
                if (frames_at_level >= 3 && frame_average > 30 && quality_level < 3) {
                    quality_level++;
                    frames_at_level = 0;
                } else if (frames_at_level >= 90 && frame_average < 5 && quality_level > 0) {
                    quality_level--;
                    frames_at_level = 0;
                }
            } else if (adaptive_quality && frame_ms > 30 && quality_level == 0) {
                quality_level = 1;
                frames_at_level = 0;
            }
            if (active_level > 0) {
                if (settle_id != 0) Source.remove (settle_id);
                settle_id = Timeout.add (360, () => {
                    settle_id = 0;
                    queue_render ();
                    return Source.REMOVE;
                });
            }
            return true;
        }

        public Cairo.ImageSurface? snapshot_image (int width, int height, Camera? view = null, bool transparent = false) {
            if (renderer == null || width <= 0 || height <= 0) return null;
            make_current ();
            draw_scene (view ?? camera, width, height, transparent, false);
            var rgba = new uint8[width * height * 4];
            renderer.read (rgba);
            var surf = new Cairo.ImageSurface (Cairo.Format.ARGB32, width, height);
            unowned uint8[] dst = surf.get_data ();
            int stride = surf.get_stride ();
            for (int y = 0; y < height; y++) {
                int s = (height - 1 - y) * width * 4;
                int d = y * stride;
                for (int x = 0; x < width; x++) {
                    uint a = rgba[s + 3];
                    dst[d] = (uint8) (rgba[s + 2] * a / 255);
                    dst[d + 1] = (uint8) (rgba[s + 1] * a / 255);
                    dst[d + 2] = (uint8) (rgba[s] * a / 255);
                    dst[d + 3] = (uint8) a;
                    s += 4;
                    d += 4;
                }
            }
            surf.mark_dirty ();
            queue_render ();
            return surf;
        }
    }
}
