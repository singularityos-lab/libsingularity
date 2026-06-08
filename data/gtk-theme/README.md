# Singularity GTK theme

The full Singularity GTK3/GTK4 theme for third-party apps, built at
libsingularity compile time. It uses the widget skeleton of
[Orchis](https://github.com/vinceliuice/Orchis-theme) by Vince Liuice
(GPL-3.0, see `COPYING`) and recolours every role with Singularity tokens:
`_sass/_singularity.scss` reassigns the Orchis colour roles to the same visual
tokens libsingularity sculpts in `src/style/style.*.css`, with accent-tinted
window and titlebar surfaces mirroring `StyleManager.apply_accent_color`.

`build-css.py` compiles the entry files with `sassc` and rewrites the accent to
the named `@accent_color` (and the tinted surfaces to GTK `mix()` expressions)
so the live accent StyleManager writes to `~/.config/gtk-*/gtk.css` drives the
theme at runtime without rebuilding.

Vendored Orchis sources live under `_sass/` and `gtk/`; only the GTK3/GTK4
subset is kept. Thanks to the Orchis project for the widget base.
