project('libsingularity', ['vala', 'c'],
  version: '0.1.0',
  license: 'LGPL-2.1-only',
  meson_version: '>= 1.10.0',
)

gnome     = import('gnome')
pkgconfig = import('pkgconfig')
i18n      = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="libsingularity"', language: 'c')
subdir('po')

datadir = get_option('datadir')
libdir = get_option('libdir')
girdir = join_paths(datadir, 'gir-1.0')
typelibdir = join_paths(libdir, 'girepository-1.0')

gtk4_dep       = dependency('gtk4',               version: '>= 4.6')
layershell_dep = dependency('gtk4-layer-shell-0', version: '>= 0.7')
gee_dep        = dependency('gee-0.8',            version: '>= 0.20')
json_dep       = dependency('json-glib-1.0',      version: '>= 1.6')
peas_dep       = dependency('libpeas-2',          version: '>= 2.0')
gmodule_dep    = dependency('gmodule-2.0')
soup_dep       = dependency('libsoup-3.0')
gtksource_dep  = dependency('gtksourceview-5')
introspection_dep = dependency('gobject-introspection-1.0', required: get_option('introspection'))

libsingularity_deps = [gtk4_dep, layershell_dep, gee_dep, json_dep, peas_dep, gmodule_dep, soup_dep, gtksource_dep]

libsingularity_resources = gnome.compile_resources(
  'libsingularity-resources',
  'data/libsingularity.gresource.xml',
  source_dir: 'src/style',
  c_name: 'singularity',
)

libsingularity_sources = files(
  'src/ui/windowing/toolbar.vala',
  'src/ui/windowing/titlebar_inset.vala',
  'src/ui/navigation/tabbar.vala',
  'src/ui/navigation/tab_container.vala',
  'src/ui/windowing/window.vala',
  'src/ui/controls/icon_button.vala',
  'src/ui/controls/circular_button.vala',
  'src/ui/controls/close_button.vala',
  'src/ui/dialogs/app_dialog.vala',
  'src/ui/dialogs/confirm_dialog.vala',
  'src/ui/preferences/preferences.vala',
  'src/ui/preferences/preferences_window.vala',
  'src/ui/preferences/preferences_page.vala',
  'src/ui/pages/status_page.vala',
  'src/ui/controls/search_entry.vala',
  'src/ui/controls/segmented_control.vala',
  'src/ui/controls/color_picker_button.vala',
  'src/ui/editor/style_chooser.vala',
  'src/ui/editor/floating_format_bar.vala',
  'src/ui/editor/ruler.vala',
  'src/ui/editor/find_replace_bar.vala',
  'src/ui/editor/page_canvas.vala',
  'src/ui/editor/source_view.vala',
  'src/ui/navigation/menu_row.vala',
  'src/ui/navigation/context_menu.vala',
  'src/ui/navigation/app_sidebar.vala',
  'src/shell/shell_dialog.vala',
  'src/ui/navigation/sidebar_section_label.vala',
  'src/shell/global_menu_bar.vala',
  'src/ui/pages/welcome_page.vala',
  'src/shell/osd_overlay.vala',
  'src/shell/screen_flash.vala',
  'src/ui/controls/quick_setting_tile.vala',
  'src/ui/controls/search_entry.vala',
  'src/ui/visual/hover_controls.vala',
  'src/ui/visual/search_bubble.vala',
  'src/ui/visual/data_list_view.vala',
  'src/ui/visual/data_grid_view.vala',
  'src/ui/visual/column_browser.vala',
  'src/ui/navigation/sidebar_row.vala',
  'src/ui/visual/overlay_search.vala',
  'src/ui/visual/command_palette.vala',
  'src/ui/visual/carousel.vala',
  'src/ui/visual/chip.vala',
  'src/ui/pages/screenshot_carousel.vala',
  'src/ui/pages/calendar_views.vala',
  'src/calendar/calendar_contract.vala',
  'src/core/environment.vala',
  'src/core/settings_util.vala',
  'src/core/application.vala',
  'src/core/shell_application.vala',
  'src/core/settings_contract.vala',
  'src/core/shell_contract.vala',
  'src/core/app_settings_contract.vala',
  'src/core/plugin_contract.vala',
  'src/core/files_plugin_contract.vala',
  'src/core/overview_widget_registry.vala',
  'src/core/shell_surface_contract.vala',
  'src/core/search_provider.vala',
  'src/core/vpn_provider.vala',
  'src/core/app_settings_loader.vala',
  'src/animation/animation.vala',
  'src/animation/timed_animation.vala',
  'src/style/style_manager.vala',
  'src/accessibility/accessibility_manager.vala',
  'src/ui/visual/chart_widgets.vala',
  'src/ui/visual/circular_progress.vala',
  'src/ui/visual/media_player_card.vala',
  'src/ui/pages/browser_pill.vala',
  'src/core/terminal_themes.vala',
  'src/file_system/file_provider.vala',
  'src/file_system/recent_provider.vala',
  'src/file_system/samba_provider.vala',
)

libsingularity = shared_library('singularity',
  libsingularity_sources + libsingularity_resources,
  dependencies: libsingularity_deps,
  vala_header: 'singularity.h',
  vala_vapi: 'singularity-1.0.vapi',
  vala_gir: 'Singularity-1.0.gir',
  install: true,
  install_dir: [get_option('libdir'), true, true, true],
  soversion: '0',
  version: meson.project_version(),
)

libsingularity_gir = libsingularity.vala_gir()

if get_option('introspection') and introspection_dep.found()
  g_ir_compiler = find_program('g-ir-compiler')
  custom_target('libsingularity-typelib',
    input: libsingularity.vala_gir(),
    output: 'Singularity-1.0.typelib',
    command: [g_ir_compiler, '--output', '@OUTPUT@', '@INPUT@'],
    build_by_default: true,
    install: true,
    install_dir: typelibdir,
  )
endif

libsingularity_dep = declare_dependency(
  link_with: libsingularity,
  include_directories: [include_directories('src'), include_directories('.')],
  dependencies: libsingularity_deps,
)

libsingularity_vapi = meson.current_build_dir() / 'singularity-1.0.vapi'

pkgconfig.generate(
  libsingularity,
  name: 'libsingularity',
  description: 'Singularity Desktop application framework library',
  version: meson.project_version(),
  filebase: 'singularity-1.0',
  requires: ['gtk4', 'gtk4-layer-shell-0', 'gee-0.8', 'json-glib-1.0', 'libpeas-2', 'gtksourceview-5'],
)

install_data(
  'singularity-1.0.deps',
  install_dir: get_option('datadir') / 'vala' / 'vapi',
)

# Build the Singularity GTK3/GTK4 theme for third-party apps. Orchis supplies
# only the widget skeleton; data/gtk-theme/_sass/_singularity.scss reassigns
# every colour role to a Singularity token (accent-tinted surfaces, our accent
# everywhere) mirroring StyleManager and the style.*.css tokens. sassc bakes the
# default accent; the live accent still reaches apps via the portal and the
# ~/.config/gtk-*/gtk.css overrides StyleManager writes. Our own apps pin the
# empty SingularityShell theme and keep reading style.css at PRIORITY_USER.
sassc_exe = find_program('sassc')
python3_exe = find_program('python3')
sing_build_css = files('data/gtk-theme/build-css.py')
# Default baked accent (the 'blue' swatch). build-css.py rewrites it to the
# named @accent_color so the live accent still wins at runtime.
sing_accent = '#3584e4'
sing_theme_dir = get_option('datadir') / 'themes' / 'Singularity'
# Every partial the entry scss pulls in; a change to any retriggers sassc.
sing_theme_sass = files(
  'data/gtk-theme/_sass/_singularity.scss',
  'data/gtk-theme/_sass/_colors.scss',
  'data/gtk-theme/_sass/_variables.scss',
  'data/gtk-theme/_sass/_tweaks.scss',
  'data/gtk-theme/_sass/_tweaks-temp.scss',
  'data/gtk-theme/_sass/_color-palette.scss',
  'data/gtk-theme/_sass/_color-palette-default.scss',
  'data/gtk-theme/build-css.py',
)
# Separate subdirs so each toolkit emits its own gtk.css / gtk-dark.css into a
# distinct build path (otherwise the two gtk.css ninja targets collide).
subdir('data/gtk-theme/gtk/3.0')
subdir('data/gtk-theme/gtk/4.0')

# Widget assets (png) plus scalable (svg) the generated CSS references as
# assets/... and assets/scalable/..., installed beside each toolkit's gtk.css.
foreach dir : ['gtk-3.0', 'gtk-4.0']
  install_subdir('data/gtk-theme/gtk/assets', install_dir: sing_theme_dir / dir)
  install_subdir('data/gtk-theme/gtk/scalable', install_dir: sing_theme_dir / dir / 'assets')
endforeach

install_data('data/gtk-theme/index.theme', install_dir: sing_theme_dir)
