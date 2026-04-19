# Contributing to libsingularity

## Development setup

```bash
git clone https://github.com/singularityos-lab/libsingularity
cd libsingularity
meson setup build
ninja -C build
```

To enable GObject Introspection:

```bash
meson setup build -Dintrospection=true
ninja -C build
```

## Code style

- Language: **Vala** only.
- Indentation: **4 spaces** no tabs, no trailing whitespace.
- Namespace: all public symbols must live under `Singularity`, `Singularity.Widgets`,
  `Singularity.Shell`, or `Singularity.Core`.
- **Doc comments are required on every public API** classes, properties, signals,
  and methods. Use the `/** .. */` form.
- Keep files focused: one primary class per `.vala` file, named after the class
  (e.g. `SwitchRow` -> `switch_row.vala`). Redundant suffixes in the filename 
  (like `_manager` or `_provider`) should be avoided.

## License

By contributing you agree your code will be released under [LGPL-2.1-only](LICENSE).

