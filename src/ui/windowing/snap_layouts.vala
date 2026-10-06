namespace Singularity.Widgets.SnapLayouts {

    [CCode (cname = "singularity_snap_button_available", cheader_filename = "wayland/snap_button.h")]
    private extern bool native_snap_button_available(Gtk.Widget widget);

    [CCode (cname = "singularity_snap_button_enter", cheader_filename = "wayland/snap_button.h")]
    private extern void native_snap_button_enter(Gtk.Widget widget);

    [CCode (cname = "singularity_snap_button_leave", cheader_filename = "wayland/snap_button.h")]
    private extern void native_snap_button_leave(Gtk.Widget widget);

    private const string ATTACHED_KEY = "singularity-snap-layouts";

    /**
     * Returns `true` when the compositor accepts maximize button hovers
     * from the display of `widget`.
     */
    public bool is_available(Gtk.Widget widget) {
        return native_snap_button_available(widget);
    }

    /**
     * Connects a client drawn maximize button to the desktop snap layout
     * picker.
     *
     * Resting the pointer on the button shows the layout picker of the
     * desktop shell, exactly like the maximize button of a compositor
     * drawn titlebar. Where the compositor does not offer the
     * `singularity-snap-unstable-v1` protocol (version 2 or later), or the
     * picker is turned off, the button keeps behaving as a plain maximize
     * button. Where the picker can be offered the button tooltip is
     * dropped, since the picker takes its place. Repeated calls on the
     * same button are ignored.
     */
    public void attach_maximize_button(Gtk.Widget button) {
        if (button.get_data<bool>(ATTACHED_KEY)) return;
        button.set_data<bool>(ATTACHED_KEY, true);

        var motion = new Gtk.EventControllerMotion();
        motion.enter.connect(() => native_snap_button_enter(button));
        motion.leave.connect(() => native_snap_button_leave(button));
        button.add_controller(motion);

        var press = new Gtk.GestureClick();
        press.button = 0;
        press.propagation_phase = Gtk.PropagationPhase.CAPTURE;
        press.pressed.connect(() => native_snap_button_leave(button));
        button.add_controller(press);

        button.unmap.connect(() => native_snap_button_leave(button));
        button.realize.connect(() => {
            if (is_available(button)) button.has_tooltip = false;
        });
    }
}
