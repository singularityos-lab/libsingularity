namespace Singularity.Core {

    public GLib.Settings? safe_settings (string schema_id) {
        var src = GLib.SettingsSchemaSource.get_default ();
        if (src == null || src.lookup (schema_id, true) == null) {
            return null;
        }
        return new GLib.Settings (schema_id);
    }
}
