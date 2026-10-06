namespace Singularity.Widgets {

    /**
     * Returns the icon to show when an icon is drawn larger than 24 px.
     *
     * Large icons inside apps use the full-color version from the Singularity
     * icon theme; symbolic glyphs are kept for small chrome. When the theme
     * has no color version of `name`, the symbolic name is returned unchanged.
     */
    public string large_icon_name (string name) {
        if (!name.has_suffix ("-symbolic")) return name;
        string color = name.substring (0, name.length - "-symbolic".length);
        var display = Gdk.Display.get_default ();
        if (display == null) return name;
        var paintable = Gtk.IconTheme.get_for_display (display).lookup_icon (color, null, 64, 1, Gtk.TextDirection.NONE, 0);
        var file = paintable.get_file ();
        string? path = file != null ? file.get_path () : null;
        if (path == null || path.has_suffix ("-symbolic.svg") || !path.contains ("/icons/Singularity")) return name;
        return color;
    }
}
