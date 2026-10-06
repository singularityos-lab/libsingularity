# libsingularity

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

A GTK4 application and widget framework for the [Singularity Desktop Environment](https://github.com/singularityos-lab).

This project ships two libraries from one source tree:

| Library | pkg-config | Contains | Depends on |
|---|---|---|---|
| `libsingularity` | `singularity-1.0` | GTK4 UI toolkit: widgets, windows, dialogs, editor, style/theme, plus pure UI helpers (`ColorUtil`, `TilingLayout`, `GridLayout`, `HotCornerLogic`) | gtk4, optional gtk4-layer-shell, gee, json-glib, libpeas, libsoup, gtksourceview |
| `libsingularity-system` | `singularity-system-1.0` | Headless system backends (no GTK): bluetooth, audio, power, brightness, network, datetime, locale, accounts, gamemode, night light, call monitor, now-playing, session, resource monitor, app-menu registrar, plus helpers (`TimezoneUtil`, `InputSourceUtil`, `AutostartManager`, `HardwareInfo`) | gio, gio-unix, gee, libpulse, gudev, upower-glib, libnm, libsoup |

Both share the `Singularity` namespace. An app links only what it needs: a text editor links `singularity-1.0` and never pulls in NetworkManager, PulseAudio or UPower; the desktop shell links both.

## Requirements

UI toolkit (`libsingularity`):

- [Meson](https://mesonbuild.com/) >= 1.10
- [Vala](https://vala.dev/) compiler
- GTK4 >= 4.6, gtk4-layer-shell >= 0.7 when `-Dlayer-shell=true`
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

Standalone app that does not use system backends or layer-shell widgets:

```sh
meson setup build -Dsystem=false -Dlayer-shell=false
```

When libsingularity is vendored as a subproject, pass the option through from the parent:

```sh
meson setup build -Dlibsingularity:system=false -Dlibsingularity:layer-shell=false
```

`-Dsystem=false` excludes `libsingularity-system` and its dependencies. `-Dlayer-shell=false` excludes `ShellDialog`, `OsdOverlay`, and `ScreenFlash`, and removes gtk4-layer-shell from the library and pkg-config dependencies.

## Configuration

libsingularity reads desktop preferences from the `dev.sinty.desktop` GSettings schema.
To use a custom schema, override it before constructing any `Application`:

```vala
Singularity.Runtime.desktop_settings_schema = "org.mydesktop.shell";
var app = new Singularity.Application("org.myapp.MyApp");
app.run(args);
```

## Third-party code

- `protocols/ext-*.xml`, `protocols/wlr-*.xml`, `protocols/xdg-output-unstable-v1.xml` and `protocols/virtual-keyboard-unstable-v1.xml`: Wayland protocol definitions from [wayland-protocols](https://gitlab.freedesktop.org/wayland/wayland-protocols), [wlr-protocols](https://gitlab.freedesktop.org/wlroots/wlr-protocols) and the virtual keyboard protocol, under the licenses stated in each file.

## License

LGPL-2.1-only, see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on libsingularity. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
