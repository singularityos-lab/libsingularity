# libsingularity

A GTK4 application and widget framework for the [Singularity Desktop Environment](https://github.com/singularityos-lab).

This project ships two libraries from one source tree:

| Library | pkg-config | Contains | Depends on |
|---|---|---|---|
| `libsingularity` | `singularity-1.0` | GTK4 UI toolkit: widgets, windows, dialogs, editor, style/theme, plus pure UI helpers (`ColorUtil`, `TilingLayout`, `GridLayout`, `HotCornerLogic`) | gtk4, gtk4-layer-shell, gee, json-glib, libpeas, libsoup, gtksourceview |
| `libsingularity-system` | `singularity-system-1.0` | Headless system backends (no GTK): bluetooth, audio, power, brightness, network, datetime, locale, accounts, gamemode, night light, call monitor, now-playing, session, resource monitor, app-menu registrar, plus helpers (`TimezoneUtil`, `InputSourceUtil`, `AutostartManager`, `HardwareInfo`) | gio, gio-unix, gee, libpulse, gudev, upower-glib, libnm, libsoup |

Both share the `Singularity` namespace. An app links only what it needs: a text editor links `singularity-1.0` and never pulls in NetworkManager, PulseAudio or UPower; the desktop shell links both.

## Requirements

UI toolkit (`libsingularity`):

- [Meson](https://mesonbuild.com/) >= 1.10
- [Vala](https://vala.dev/) compiler
- GTK4 >= 4.6, gtk4-layer-shell >= 0.7
- libgee-0.8 >= 0.20, json-glib-1.0 >= 1.6, libpeas-2 >= 2.0, libsoup >= 3.0, gtksourceview-5 >= 5.0

System backends (`libsingularity-system`, only when `-Dsystem=true`, the default):

- gio-2.0, gio-unix-2.0, gee, libpulse, libpulse-mainloop-glib, gudev-1.0, upower-glib >= 0.99, libnm >= 1.0, libsoup >= 3.0

## Build & Install

Full build (both libraries, the desktop's default):

```sh
meson setup build
meson compile -C build
meson install -C build
```

Standalone app that needs only the UI toolkit (skip the heavy system deps):

```sh
meson setup build -Dsystem=false
```

When libsingularity is vendored as a subproject, pass the option through from the parent:

```sh
meson setup build -Dlibsingularity:system=false
```

With `-Dsystem=false` the `libsingularity-system` target and its dependencies (libpulse, gudev, upower-glib) are not built or required at all.

## Configuration

libsingularity reads desktop preferences from the `dev.sinty.desktop` GSettings schema.
To use a custom schema, override it before constructing any `Application`:

```vala
Singularity.Runtime.desktop_settings_schema = "org.mydesktop.shell";
var app = new Singularity.Application("org.myapp.MyApp");
app.run(args);
```

## License

LGPL-2.1-only, see [LICENSE](LICENSE).
