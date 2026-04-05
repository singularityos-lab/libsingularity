project('libsingularity', ['vala', 'c'],
  version: '0.1.0',
  license: 'LGPL-2.1-only',
  meson_version: '>= 0.59.0',
)

gnome     = import('gnome')
pkgconfig = import('pkgconfig')

datadir = get_option('datadir')
libdir = get_option('libdir')
girdir = join_paths(datadir, 'gir-1.0')
typelibdir = join_paths(libdir, 'girepository-1.0')

gtk4_dep       = dependency('gtk4',               version: '>= 4.6')
layershell_dep = dependency('gtk4-layer-shell-0', version: '>= 0.7')
gee_dep        = dependency('gee-0.8',            version: '>= 0.20')
json_dep       = dependency('json-glib-1.0',      version: '>= 1.6')
peas_dep       = dependency('libpeas-2',          version: '>= 2.0')
introspection_dep = dependency('gobject-introspection-1.0', required: get_option('introspection'))

libsingularity_deps = [gtk4_dep, layershell_dep, gee_dep, json_dep, peas_dep]

libsingularity_resources = gnome.compile_resources(
  'libsingularity-resources',
  'data/libsingularity.gresource.xml',
  source_dir: 'src/style',
  c_name: 'singularity',
)

libsingularity_sources = files(
  'src/ui/windowing/toolbar.vala',
  'src/ui/navigation/tabbar.vala',
  'src/ui/navigation/tab_container.vala',
  'src/ui/windowing/window.vala',
  'src/ui/controls/icon_button.vala',
  'src/ui/controls/circular_button.vala',
  'src/ui/controls/close_button.vala',
  'src/ui/dialogs/app_dialog.vala',
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
  'src/ui/navigation/menu_row.vala',
  'src/ui/navigation/context_menu.vala',
  'src/shell/shell_dialog.vala',
  'src/ui/navigation/sidebar_section_label.vala',
  'src/shell/global_menu_bar.vala',
  'src/ui/pages/welcome_page.vala',
  'src/shell/osd_overlay.vala',
  'src/shell/screen_flash.vala',
  'src/ui/controls/quick_setting_tile.vala',
  'src/ui/visual/hover_controls.vala',
  'src/ui/visual/chip.vala',
  'src/ui/pages/screenshot_carousel.vala',
  'src/ui/pages/calendar_views.vala',
  'src/calendar/calendar_contract.vala',
  'src/core/environment.vala',
  'src/core/application.vala',
  'src/core/settings_contract.vala',
  'src/core/shell_contract.vala',
  'src/core/app_settings_contract.vala',
  'src/core/plugin_contract.vala',
  'src/core/app_settings_loader.vala',
  'src/animation/animation.vala',
  'src/animation/timed_animation.vala',
  'src/style/style_manager.vala',
  'src/accessibility/accessibility_manager.vala',
  'src/ui/visual/chart_widgets.vala',
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

pkgconfig.generate(
  libsingularity,
  name: 'libsingularity',
  description: 'Singularity Desktop application framework library',
  version: meson.project_version(),
  filebase: 'libsingularity-1.0',
  requires: ['gtk4', 'gtk4-layer-shell-0', 'gee-0.8', 'json-glib-1.0', 'libpeas-2'],
)
