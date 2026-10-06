namespace Singularity {

    using PulseAudio;

    public class AudioManager : Object {
        public struct AudioDevice {
            public uint32 index;
            public string name;
            public string description;
            public string friendly_name;
            public bool is_default;
            public string icon_name;
        }
        public struct SinkInput {
            public uint32 index;
            public string name;
            public string app_name;
            public string icon_name;
            public double volume;
            public bool is_muted;
            public int pid;
            public string binary;
        }
        private static AudioManager? default_instance = null;

        public static AudioManager get_default() {
            if (default_instance == null) default_instance = new AudioManager();
            return default_instance;
        }
        public double volume { get; private set; default = 50.0; }

        /** Highest output volume in percent: 100, or 150 when overamplification is allowed. */
        public double max_volume { get; private set; default = 100.0; }

        private GLib.Settings? sound_settings;

        private void watch_overamplification() {
            var src = GLib.SettingsSchemaSource.get_default();
            if (src == null || src.lookup("org.gnome.desktop.sound", true) == null) return;
            sound_settings = new GLib.Settings("org.gnome.desktop.sound");
            if (!sound_settings.settings_schema.has_key("allow-volume-above-100-percent")) return;
            sync_max_volume();
            sound_settings.changed["allow-volume-above-100-percent"].connect(() => {
                sync_max_volume();
                if (volume > max_volume) update_volume(max_volume);
                state_changed();
            });
        }

        private void sync_max_volume() {
            max_volume = sound_settings.get_boolean("allow-volume-above-100-percent") ? 150.0 : 100.0;
        }
        public bool is_muted { get; private set; default = false; }
        public string icon_name { get; private set; default = "audio-volume-medium-symbolic"; }
        public double input_volume { get; private set; default = 50.0; }
        public bool input_muted { get; private set; default = false; }
        public List<AudioDevice?> sinks;
        public List<AudioDevice?> sources;
        public List<SinkInput?> sink_inputs;
        public signal void state_changed();
        public signal void external_volume_changed();
        private bool sink_seen = false;
        private int64 local_change_at = 0;
        public signal void devices_changed();
        public signal void mixer_changed();

        public string default_sink_icon {
            get {
                unowned List<AudioDevice?> l = sinks;
                while (l != null) {
                    if (l.data != null && l.data.index == default_sink_index)
                        return l.data.icon_name ?? "audio-card-symbolic";
                    l = l.next;
                }
                return "audio-card-symbolic";
            }
        }

        public string default_sink_friendly {
            get {
                unowned List<AudioDevice?> l = sinks;
                while (l != null) {
                    if (l.data != null && l.data.index == default_sink_index)
                        return l.data.friendly_name ?? l.data.description ?? "";
                    l = l.next;
                }
                return "";
            }
        }

        public string default_sink_description {
            get {
                unowned List<AudioDevice?> l = sinks;
                while (l != null) {
                    if (l.data != null && l.data.index == default_sink_index)
                        return l.data.description ?? "";
                    l = l.next;
                }
                return "";
            }
        }
        private PulseAudio.GLibMainLoop loop;
        private PulseAudio.Context context;
        public uint32 default_sink_index { get; private set; default = 0; }
        public uint32 default_source_index { get; private set; default = 0; }
        private uint reconnect_delay_ms = 1000;
        private uint reconnect_source_id = 0;
        private uint _refresh_timer = 0;
        private bool _refreshing = false;

        private const string MONO_SINK = "singularity_mono";
        private bool mono_enabled = false;
        private uint32 mono_module = PulseAudio.INVALID_INDEX;
        private string? mono_master = null;
        private bool mono_pending = false;
        private bool mono_load_after_unload = false;

        public AudioManager() {
            watch_overamplification();
            sinks = new List<AudioDevice?>();
            sources = new List<AudioDevice?>();
            sink_inputs = new List<SinkInput?>();
            loop = new PulseAudio.GLibMainLoop(null);
            connect_context();
        }

        private void connect_context() {
            var api = loop.get_api();
            context = new PulseAudio.Context(api, "Singularity Desktop");
            context.set_state_callback((c) => {
                var state = c.get_state();
                if (state == Context.State.READY) {
                    message("AudioManager: PulseAudio Context READY");
                    reconnect_delay_ms = 1000;
                    queue_refresh();
                    c.set_subscribe_callback((c2, type, idx) => {
                        queue_refresh();
                    });
                    c.subscribe(Context.SubscriptionMask.SINK | Context.SubscriptionMask.SOURCE | Context.SubscriptionMask.SINK_INPUT | Context.SubscriptionMask.SERVER, null);
                } else if (state == Context.State.FAILED || state == Context.State.TERMINATED) {
                    warning("AudioManager: PulseAudio Context FAILED/TERMINATED, reconnecting in %ums", reconnect_delay_ms);
                    schedule_reconnect();
                }
            });
            context.connect(null, (Context.Flags)0, null);
        }

        private void schedule_reconnect() {
            if (reconnect_source_id != 0) return;
            uint delay = reconnect_delay_ms;
            reconnect_source_id = Timeout.add(delay, () => {
                reconnect_source_id = 0;
                reconnect_delay_ms = uint.min(reconnect_delay_ms * 2, 30000);
                connect_context();
                return false;
            });
        }

        private void queue_refresh() {
            if (_refresh_timer != 0) {
                Source.remove(_refresh_timer);
                _refresh_timer = 0;
            }
            _refresh_timer = Timeout.add(80, () => {
                _refresh_timer = 0;
                refresh_all();
                return Source.REMOVE;
            });
        }

        private void refresh_all() {
            if (_refreshing) return;
            _refreshing = true;
            context.get_server_info((c, info) => {
                if (info != null) {
                    string default_sink = info.default_sink_name ?? "";
                    if (default_sink == MONO_SINK && mono_master != null) {
                        default_sink = mono_master;
                    } else if (mono_enabled && default_sink != "" && !mono_pending) {
                        apply_mono(default_sink);
                    }
                    get_sink_info(default_sink);
                    get_source_info(info.default_source_name);
                    sinks = new List<AudioDevice?>();
                    context.get_sink_info_list((c, info, eol) => {
                        if (eol != 0) {
                            _refreshing = false;
                            devices_changed();
                            return;
                        }
                        if (info != null && info.name != MONO_SINK) {
                            AudioDevice dev = AudioDevice();
                            dev.index = info.index;
                            dev.name = info.name;
                            dev.description = info.description;
                            string? ff = info.proplist.gets("device.form_factor");
                            dev.icon_name = AudioManager.form_factor_to_icon(ff);
                            dev.friendly_name = AudioManager.friendly_description(info.description, ff);
                            sinks.append(dev);
                        }
                    });
                    sources = new List<AudioDevice?>();
                    context.get_source_info_list((c, info, eol) => {
                        if (eol != 0) {
                            devices_changed();
                            return;
                        }
                        if (info != null) {
                            if (info.monitor_of_sink == PulseAudio.INVALID_INDEX) {
                                AudioDevice dev = AudioDevice();
                                dev.index = info.index;
                                dev.name = info.name;
                                dev.description = info.description;
                                string? ff = info.proplist.gets("device.form_factor");
                                dev.icon_name = AudioManager.form_factor_to_icon(ff);
                                dev.friendly_name = AudioManager.friendly_description(info.description, ff);
                                sources.append(dev);
                            }
                        }
                    });
                    sink_inputs = new List<SinkInput?>();
                    context.get_sink_input_info_list((c, info, eol) => {
                        if (eol != 0) {
                            mixer_changed();
                            return;
                        }
                        if (info != null) {
                            SinkInput input = SinkInput();
                            input.index = info.index;
                            input.name = info.name;
                            string? app_name = info.proplist.gets(PulseAudio.Proplist.PROP_APPLICATION_NAME);
                            input.app_name = app_name ?? info.name;
                            string? icon = info.proplist.gets(PulseAudio.Proplist.PROP_APPLICATION_ICON_NAME);
                            input.icon_name = icon ?? "application-x-executable-symbolic";
                            double vol = 0;
                            if (info.volume.channels > 0) {
                                long total = 0;
                                for (int i = 0; i < info.volume.channels; i++) {
                                    total += info.volume.values[i];
                                }
                                vol = (double)total / info.volume.channels;
                            }
                            input.volume = (vol / 65536.0) * 100.0;
                            if (input.volume > 100) input.volume = 100;
                            input.is_muted = (info.mute != 0);
                            string? pid = info.proplist.gets(PulseAudio.Proplist.PROP_APPLICATION_PROCESS_ID);
                            input.pid = pid != null ? int.parse(pid) : 0;
                            input.binary = info.proplist.gets(PulseAudio.Proplist.PROP_APPLICATION_PROCESS_BINARY) ?? "";
                            sink_inputs.append(input);
                        }
                    });
                }
            });
        }

        private void get_sink_info(string name) {
            context.get_sink_info_by_name(name, (c, info, eol) => {
                if (eol != 0 || info == null) return;
                bool same_sink = sink_seen && default_sink_index == info.index;
                double old_volume = volume;
                bool old_muted = is_muted;
                default_sink_index = info.index;
                double vol = 0;
                if (info.volume.channels > 0) {
                    long total = 0;
                    for (int i = 0; i < info.volume.channels; i++) {
                        total += info.volume.values[i];
                    }
                    vol = (double)total / info.volume.channels;
                }
                volume = (vol / 65536.0) * 100.0;
                if (volume > max_volume) volume = max_volume;
                is_muted = (info.mute != 0);
                update_icon();
                state_changed();
                bool changed = (volume - old_volume).abs() >= 0.5 || is_muted != old_muted;
                bool echo = get_monotonic_time() - local_change_at < 500000;
                if (same_sink && changed && !echo) external_volume_changed();
                sink_seen = true;
            });
        }

        private void update_icon() {
            if (is_muted) {
                icon_name = "audio-volume-muted-symbolic";
            } else {
                if (volume < 30) icon_name = "audio-volume-low-symbolic";
                else if (volume < 70) icon_name = "audio-volume-medium-symbolic";
                else icon_name = "audio-volume-high-symbolic";
            }
        }

        public void update_volume(double val) {
            if (context.get_state() != Context.State.READY) return;
            local_change_at = get_monotonic_time();
            val = val.clamp(0, max_volume);
            volume = val;
            // Raising volume implicitly unmutes
            if (val > 0 && is_muted) {
                is_muted = false;
                context.set_sink_mute_by_index(default_sink_index, false, null);
            }
            update_icon();
            state_changed();
            CVolume cvol = CVolume();
            cvol.channels = 2;
            var v = (uint32)((val / 100.0) * 65536.0);
            for (int i = 0; i < 2; i++) cvol.values[i] = v;
            context.set_sink_volume_by_index(default_sink_index, cvol, null);
        }

        public void toggle_mute() {
             if (context.get_state() != Context.State.READY) return;
             local_change_at = get_monotonic_time();
             is_muted = !is_muted;
             update_icon();
             state_changed();
             context.set_sink_mute_by_index(default_sink_index, is_muted, null);
        }

        private void get_source_info(string name) {
            context.get_source_info_by_name(name, (c, info, eol) => {
                if (eol != 0 || info == null) return;
                default_source_index = info.index;
                double vol = 0;
                if (info.volume.channels > 0) {
                    long total = 0;
                    for (int i = 0; i < info.volume.channels; i++) {
                        total += info.volume.values[i];
                    }
                    vol = (double)total / info.volume.channels;
                }
                input_volume = (vol / 65536.0) * 100.0;
                if (input_volume > 100) input_volume = 100;
                input_muted = (info.mute != 0);
                state_changed();
            });
        }

        public void update_input_volume(double val) {
            if (context.get_state() != Context.State.READY) return;
            input_volume = val;
            state_changed();
            CVolume cvol = CVolume();
            cvol.channels = 2;
            var v = (uint32)((val / 100.0) * 65536.0);
            for (int i = 0; i < 2; i++) cvol.values[i] = v;
            context.set_source_volume_by_index(default_source_index, cvol, null);
        }

        public void toggle_input_mute() {
             if (context.get_state() != Context.State.READY) return;
             input_muted = !input_muted;
             state_changed();
             context.set_source_mute_by_index(default_source_index, input_muted, null);
        }

        public void update_app_volume(uint32 index, double val) {
            if (context.get_state() != Context.State.READY) return;
            CVolume cvol = CVolume();
            cvol.channels = 2;
            var v = (uint32)((val / 100.0) * 65536.0);
            for (int i = 0; i < 2; i++) cvol.values[i] = v;
            context.set_sink_input_volume(index, cvol, null);
        }

        public void set_app_mute(uint32 index, bool muted) {
            if (context.get_state() != Context.State.READY) return;
            context.set_sink_input_mute(index, muted, (c, success) => queue_refresh());
        }

        public void refresh() {
            if (context.get_state() == Context.State.READY) queue_refresh();
        }

        private static int parent_pid(int pid) {
            try {
                string stat;
                FileUtils.get_contents("/proc/%d/stat".printf(pid), out stat);
                int close = stat.last_index_of_char(')');
                if (close < 0) return 0;
                string[] fields = stat.substring(close + 2).split(" ");
                return fields.length > 1 ? int.parse(fields[1]) : 0;
            } catch (FileError e) {
                return 0;
            }
        }

        private static bool descends_from(int pid, int ancestor) {
            for (int depth = 0; pid > 1 && depth < 32; depth++) {
                if (pid == ancestor) return true;
                pid = parent_pid(pid);
            }
            return false;
        }

        private static bool stream_matches(SinkInput input, int pid, string[] hints) {
            if (pid > 0 && input.pid > 0 && descends_from(input.pid, pid)) return true;
            string app = (input.app_name ?? "").down();
            string binary = (input.binary ?? "").down();
            foreach (string hint in hints) {
                string wanted = hint.down();
                if (wanted.length < 3) continue;
                if (app == wanted || app.contains(wanted) || binary.contains(wanted)) return true;
            }
            return false;
        }

        public bool find_streams(int pid, string[] hints, out bool muted) {
            bool found = false;
            muted = true;
            for (unowned List<SinkInput?> l = sink_inputs; l != null; l = l.next) {
                if (l.data == null || !stream_matches(l.data, pid, hints)) continue;
                found = true;
                if (!l.data.is_muted) muted = false;
            }
            if (!found) muted = false;
            return found;
        }

        public void set_streams_muted(int pid, string[] hints, bool muted) {
            for (unowned List<SinkInput?> l = sink_inputs; l != null; l = l.next) {
                if (l.data != null && stream_matches(l.data, pid, hints)) set_app_mute(l.data.index, muted);
            }
        }

        public void set_default_sink(string name) {
            if (context.get_state() != Context.State.READY) return;
            if (mono_enabled) {
                apply_mono(name);
                return;
            }
            context.set_default_sink(name, null);
        }

        public bool mono { get { return mono_enabled; } }

        /**
         * Plays all audio as mono on every output.
         *
         * A one channel remap sink is placed in front of the chosen output
         * and made the default, so stereo streams are mixed down and played
         * on both speakers. Volume, mute and device lists keep referring to
         * the real output, and switching output moves the mono sink with it.
         */
        public void set_mono(bool enabled) {
            if (mono_enabled == enabled) return;
            mono_enabled = enabled;
            if (context.get_state() != Context.State.READY) return;
            if (enabled) {
                queue_refresh();
            } else {
                if (mono_master != null) context.set_default_sink(mono_master, null);
                mono_load_after_unload = false;
                unload_mono_sinks();
                mono_master = null;
                queue_refresh();
            }
        }

        private void unload_mono_sinks() {
            mono_module = PulseAudio.INVALID_INDEX;
            context.get_module_info_list((c, info, eol) => {
                if (eol != 0) {
                    if (mono_load_after_unload) {
                        mono_load_after_unload = false;
                        load_mono();
                    }
                    return;
                }
                if (info == null) return;
                if (info.name == "module-remap-sink" && info.argument != null
                        && info.argument.contains("sink_name=" + MONO_SINK)) {
                    c.unload_module(info.index, null);
                }
            });
        }

        private void apply_mono(string master) {
            if (master == MONO_SINK) return;
            if (mono_module != PulseAudio.INVALID_INDEX && mono_master == master) {
                context.set_default_sink(MONO_SINK, null);
                return;
            }
            mono_pending = true;
            mono_master = master;
            mono_load_after_unload = true;
            unload_mono_sinks();
        }

        private void load_mono() {
            if (!mono_enabled || mono_master == null) {
                mono_pending = false;
                return;
            }
            string argument = "sink_name=%s master=%s channels=1 channel_map=mono".printf(MONO_SINK, mono_master)
                + " sink_properties=device.description=Mono";
            context.load_module("module-remap-sink", argument, (c, index) => {
                mono_pending = false;
                if (index == PulseAudio.INVALID_INDEX) {
                    warning("AudioManager: cannot create the mono output for %s", mono_master ?? "");
                    return;
                }
                if (!mono_enabled) {
                    c.unload_module(index, null);
                    return;
                }
                mono_module = index;
                c.set_default_sink(MONO_SINK, null);
                queue_refresh();
            });
        }

        private static string form_factor_to_icon(string? form_factor) {
            switch (form_factor ?? "") {
                case "headset":    return "audio-headset-symbolic";
                case "headphones": return "audio-headphones-symbolic";
                case "speaker":    return "audio-speakers-symbolic";
                case "tv":         return "video-display-symbolic";
                case "car":        return "audio-card-symbolic";
                case "hands-free":
                case "handsfree":  return "audio-headset-symbolic";
                case "internal":   return "audio-speakers-symbolic";
                case "microphone": return "audio-input-microphone-symbolic";
                default:           return "audio-card-symbolic";
            }
        }

        public static string friendly_description(string? raw, string? form_factor) {
            if (raw == null || raw == "") return "Unknown Device";
            string d = raw;
            string ff = form_factor ?? "";
            // Known exact / prefix matches for internal hardware
            string dl = d.down();
            if (dl.contains("alder lake") || dl.contains("raptor lake") ||
                dl.contains("tiger lake") || dl.contains("ice lake") ||
                dl.contains("comet lake") || dl.contains("whiskey lake") ||
                dl.contains("kaby lake") || dl.contains("skylake") ||
                dl.contains("broadwell") || dl.contains("haswell") ||
                dl.contains("intel") || dl.contains("pch") ||
                dl.contains("high definition audio") || dl.contains("hda ") ||
                ff == "internal") {
                return "Built-in Audio";
            }
            if (dl.contains("usb audio") || dl.contains("usb-audio")) return "USB Audio";
            if (dl.contains("hdmi") || dl.contains("displayport") || dl.contains("dp audio")) return "HDMI / DisplayPort";
            // For named devices (AirPods, EarPods, BT headphones) keep the raw name
            // but strip trailing vendor suffixes after comma/dash
            int comma = d.index_of(",");
            if (comma > 0) d = d.substring(0, comma).strip();
            // Capitalise form-factor prefixes for generic names
            if (ff == "headphones" && d.down().contains("headphone")) return "Headphones";
            if ((ff == "headset" || ff == "hands-free" || ff == "handsfree") &&
                (d.down().contains("headset") || d.down().contains("hands-free"))) return "Headset";
            return d;
        }

        public void set_default_source(string name) {
            if (context.get_state() != Context.State.READY) return;
            context.set_default_source(name, null);
        }
    }
}
