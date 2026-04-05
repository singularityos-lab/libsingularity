# libsingularity

A GTK4 application and widget framework for the [Singularity Desktop Environment](https://github.com/singularityos-lab).

## Requirements

- [Meson](https://mesonbuild.com/) ≥ 1.0
- [Vala](https://vala.dev/) compiler
- GTK4 ≥ 4.6
- gtk4-layer-shell ≥ 0.7
- libgee-0.8 ≥ 0.20
- json-glib-1.0 ≥ 1.6
- libpeas-2 ≥ 2.0

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## Configuration

libsingularity reads desktop preferences from the `dev.sinty.desktop` GSettings schema.
To use a custom schema, override it before constructing any `Application`:

```vala
Singularity.Runtime.desktop_settings_schema = "org.mydesktop.shell";
var app = new Singularity.Application("org.myapp.MyApp");
app.run(args);
```

## License

LGPL-2.1-only — see [LICENSE](LICENSE).
