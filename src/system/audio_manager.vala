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
        }
        public double volume { get; private set; default = 50.0; }
        public bool is_muted { get; private set; default = false; }
        public string icon_name { get; private set; default = "audio-volume-medium-symbolic"; }
        public double input_volume { get; private set; default = 50.0; }
        public bool input_muted { get; private set; default = false; }
        public List<AudioDevice?> sinks;
        public List<AudioDevice?> sources;
        public List<SinkInput?> sink_inputs;
        public signal void state_changed();
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

        public AudioManager() {
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
                    c.subscribe(Context.SubscriptionMask.SINK | Context.SubscriptionMask.SOURCE | Context.SubscriptionMask.SERVER, null);
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
                    get_sink_info(info.default_sink_name);
                    get_source_info(info.default_source_name);
                    sinks = new List<AudioDevice?>();
                    context.get_sink_info_list((c, info, eol) => {
                        if (eol != 0) {
                            _refreshing = false;
                            devices_changed();
                            return;
                        }
                        if (info != null) {
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
                            sink_inputs.append(input);
                        }
                    });
                }
            });
        }

        private void get_sink_info(string name) {
            context.get_sink_info_by_name(name, (c, info, eol) => {
                if (eol != 0 || info == null) return;
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
                if (volume > 100) volume = 100;
                is_muted = (info.mute != 0);
                update_icon();
                state_changed();
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

        public void set_default_sink(string name) {
            if (context.get_state() != Context.State.READY) return;
            context.set_default_sink(name, null);
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
