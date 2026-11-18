# Contributing to libsingularity

## Issues

Report bugs and request features in the
[Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

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


## Commit messages

Commits follow Conventional Commits:

```
<type>: <subject>
```

`<type>` is one of `feat`, `fix`, `chore`, `docs`, `build`, `ci`, `refactor`, `perf`, `style`, `test`, `revert`. Keep `<subject>` short, lowercase and in English. An optional scope is allowed: `<type>(<scope>): <subject>`.

When a commit closes an issue, use `<type>[closes #ID]: <issue title>`, for example:

```
fix[closes #2]: Discord doesn't open on Singularity desktop
```

Do not add co-author or attribution trailers.

## Device- and environment-specific code

Code that exists only because of a specific device, architecture, firmware or environment must be marked on the line above it:

```
DEVICE-FIX(<scope>): <what breaks without this>
```

- `<scope>` is one of: `arm64`, `x86_64`, `uno-q`, `jetson`, `msm`, `nvidia`, `intel`, `amd`, `no-tpm`, `vm`, `u-boot`, `uefi`. A new scope is added to this list in the same pull request that first uses it.
- The text states what fails on that device without the code, not what the code does.
- Use the comment syntax of the file's language.
- This covers driver names, hardware probes, architecture constants, firmware quirks, boot-chain differences and anything gated on a specific environment.
- A pull request that adds or changes such code without the marker is not merged.
- `git grep -n "DEVICE-FIX("` lists every marker in the repository.
