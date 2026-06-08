#!/usr/bin/env python3
"""Compile a Singularity GTK theme entry and make it follow the live accent.

sassc bakes colours as literals. We rewrite them so the values StyleManager
writes to the user's gtk.css (@accent_color) drive the theme at runtime:

  * the pure accent       -> @accent_color
  * accent alphas         -> alpha(@accent_color, a)
  * the accent-tinted window and titlebar surfaces -> GTK mix() expressions
    referencing @accent_color (GTK resolves mix() dynamically), mirroring
    libsingularity's window_tint = mix(base, accent, 8%) and the toolbar tint.

We also append the Singularity window border (our windows carry a 1px
@border_color edge with a 12px radius), which Orchis does not draw.

Usage: build-css.py <sassc> <accent_hex> <input.scss> <output.css>
"""
import os
import re
import subprocess
import sys

sassc, accent, src, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
dark = "-dark" in os.path.basename(src)

css = subprocess.run(
    [sassc, "-M", "-t", "expanded", src],
    check=True, capture_output=True, text=True,
).stdout


def rgb(h):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def mix(c1, c2, f):
    # GTK/SCSS mix: c1*(1-f) + c2*f, rounded per channel.
    return tuple(int(round(a * (1 - f) + b * f)) for a, b in zip(c1, c2))


def hexs(c):
    return "#%02x%02x%02x" % c


a = rgb(accent)
# Mirror StyleManager apply_accent_color base colours.
base = "#242424" if dark else "#f6f5f4"
tbbase = "#1a1a1a" if dark else "#e8e8e8"
border = "rgba(255, 255, 255, 0.1)" if dark else "rgba(0, 0, 0, 0.08)"

# Baked tint hexes sassc emitted for the default accent, and the GTK mix()
# expressions that reproduce them dynamically from @accent_color.
win_tint = hexs(mix(rgb(base), a, 0.08))
tb_tint = hexs(mix(mix(rgb(tbbase), a, 0.05), rgb(base), 0.25))
win_expr = "mix(%s, @accent_color, 0.08)" % base
tb_expr = "mix(mix(%s, @accent_color, 0.05), %s, 0.25)" % (tbbase, base)

# Accent alphas -> alpha(@accent_color, a) (tolerate sassc's comma spacing).
css = re.sub(
    r"rgba\(\s*%d\s*,\s*%d\s*,\s*%d\s*,\s*([0-9.]+)\s*\)" % a,
    r"alpha(@accent_color, \1)",
    css,
)
# Tinted surfaces -> dynamic mix() (before the pure-accent pass so the tint
# hexes are matched as whole literals).
css = css.replace(win_tint, win_expr).replace(tb_tint, tb_expr)
# Pure accent -> @accent_color (also folds alpha(#hex, a) into the named form).
css = re.sub(r"#%s" % re.escape(accent.lstrip("#")), "@accent_color", css,
             flags=re.IGNORECASE)

header = (
    "/* Singularity accent fallback; overridden at runtime by the user gtk.css\n"
    " * under .config (StyleManager writes the live @accent_color there). */\n"
    "@define-color accent_color %s;\n"
    "@define-color accent_bg_color @accent_color;\n"
    "@define-color accent_fg_color #ffffff;\n"
    "@define-color theme_selected_bg_color @accent_color;\n"
    "@define-color theme_selected_fg_color #ffffff;\n\n"
) % accent

footer = (
    "\n/* Singularity window edge: 1px accent-neutral border and 12px radius,\n"
    " * matching libsingularity's .singularity-app-frame. */\n"
    "decoration {\n"
    "  border-radius: 12px;\n"
    "  border: 1px solid %s;\n"
    "}\n"
    ".maximized decoration,\n"
    ".fullscreen decoration,\n"
    ".tiled decoration {\n"
    "  border-radius: 0;\n"
    "  border: none;\n"
    "}\n"
) % border

with open(out, "w") as f:
    f.write(header + css + footer)
