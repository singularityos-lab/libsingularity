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
wayland_dep    = dependency('wayland-client')
gee_dep        = dependency('gee-0.8',            version: '>= 0.20')
json_dep       = dependency('json-glib-1.0',      version: '>= 1.6')
peas_dep       = dependency('libpeas-2',          version: '>= 2.0')
gmodule_dep    = dependency('gmodule-2.0')
gio_unix_dep   = dependency('gio-unix-2.0')
soup_dep       = dependency('libsoup-3.0')
gtksource_dep  = dependency('gtksourceview-5')
enchant_dep    = dependency('enchant-2')
introspection_dep = dependency('gobject-introspection-1.0', required: get_option('introspection'))

cc = meson.get_compiler('c')
m_dep = cc.find_library('m', required: false)

gst_dep        = dependency('gstreamer-1.0')
gst_video_dep  = dependency('gstreamer-video-1.0')
gst_app_dep    = dependency('gstreamer-app-1.0')
libsingularity_deps = [gtk4_dep, wayland_dep, gee_dep, json_dep, peas_dep, gmodule_dep, gio_unix_dep, soup_dep, gtksource_dep, enchant_dep, m_dep]
libsingularity_deps += [gst_dep, gst_video_dep, gst_app_dep]
cups_dep       = dependency('cups')
libsingularity_deps += [cups_dep]
lcms2_dep      = dependency('lcms2')
lcms2_c_args   = ['-I' + lcms2_dep.get_variable(pkgconfig: 'includedir')]
lcms2_link_args = ['-L' + lcms2_dep.get_variable(pkgconfig: 'libdir'), '-llcms2']
libsingularity_requires = ['gtk4', 'gio-unix-2.0', 'gee-0.8', 'json-glib-1.0', 'libpeas-2', 'gtksourceview-5', 'libsoup-3.0']
libsingularity_requires += ['gstreamer-1.0', 'gstreamer-video-1.0', 'gstreamer-app-1.0']

if get_option('layer-shell')
  layershell_dep = dependency('gtk4-layer-shell-0', version: '>= 0.7')
  libsingularity_deps = [layershell_dep] + libsingularity_deps
  libsingularity_requires += ['gtk4-layer-shell-0']
endif

wayland_scanner = find_program('wayland-scanner')
effect_protocol_xml = 'protocols/singularity-blur-unstable-v1.xml'
effect_protocol_c = custom_target(
  'singularity-blur-unstable-v1-client-protocol.c',
  input: effect_protocol_xml,
  output: 'singularity-blur-unstable-v1-client-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)
effect_protocol_h = custom_target(
  'singularity-blur-unstable-v1-client-protocol.h',
  input: effect_protocol_xml,
  output: 'singularity-blur-unstable-v1-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)
snap_protocol_xml = 'protocols/singularity-snap-unstable-v1.xml'
snap_protocol_c = custom_target(
  'singularity-snap-unstable-v1-client-protocol.c',
  input: snap_protocol_xml,
  output: 'singularity-snap-unstable-v1-client-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)
snap_protocol_h = custom_target(
  'singularity-snap-unstable-v1-client-protocol.h',
  input: snap_protocol_xml,
  output: 'singularity-snap-unstable-v1-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)

foreign_toplevel_protocol_c = custom_target(
  'wlr-foreign-toplevel-management-unstable-v1-client-protocol.c',
  input: 'protocols/wlr-foreign-toplevel-management-unstable-v1.xml',
  output: 'wlr-foreign-toplevel-management-unstable-v1-client-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)

libsingularity_resources = gnome.compile_resources(
  'libsingularity-resources',
  'data/libsingularity.gresource.xml',
  source_dir: 'src/style',
  c_name: 'singularity',
)

libsingularity_sources = files(
  'src/ui/windowing/toolbar.vala',
  'src/ui/windowing/snap_layouts.vala',
  'src/ui/windowing/titlebar_inset.vala',
  'src/ui/navigation/tabbar.vala',
  'src/ui/navigation/tab_container.vala',
  'src/ui/windowing/window.vala',
  'src/ui/controls/icon_button.vala',
  'src/ui/controls/circular_button.vala',
  'src/ui/controls/close_button.vala',
  'src/ui/dialogs/about_dialog.vala',
  'src/ui/dialogs/app_dialog.vala',
  'src/ui/dialogs/confirm_dialog.vala',
  'src/launch/app_chooser.vala',
  'src/ui/dialogs/shortcuts_dialog.vala',
  'src/ui/preferences/preferences.vala',
  'src/ui/preferences/preferences_window.vala',
  'src/ui/preferences/preferences_page.vala',
  'src/ui/pages/status_page.vala',
  'src/ui/controls/search_entry.vala',
  'src/ui/controls/bubble_switcher.vala',
  'src/ui/controls/segmented_control.vala',
  'src/ui/controls/swipe_navigation.vala',
  'src/ui/controls/time_picker.vala',
  'src/ui/controls/color_picker_button.vala',
  'src/ui/controls/recent_colors.vala',
  'src/ui/editor/style_chooser.vala',
  'src/ui/editor/floating_format_bar.vala',
  'src/ui/editor/ruler.vala',
  'src/ui/editor/find_replace_bar.vala',
  'src/ui/editor/page_canvas.vala',
  'src/ui/editor/source_view.vala',
  'src/ui/navigation/menu_row.vala',
  'src/ui/navigation/context_menu.vala',
  'src/ui/navigation/tool_palette.vala',
  'src/ui/navigation/control_strip.vala',
  'src/ui/navigation/inspector_panel.vala',
  'src/ui/navigation/app_sidebar.vala',
  'src/ui/navigation/context_ribbon.vala',
  'src/ui/navigation/sidebar_tabs.vala',
  'src/ui/navigation/sidebar_section_label.vala',
  'src/shell/global_menu_bar.vala',
  'src/ui/pages/welcome_page.vala',
  'src/ui/controls/quick_setting_tile.vala',
  'src/ui/controls/search_entry.vala',
  'src/ui/visual/hover_controls.vala',
  'src/ui/visual/bubble_overflow.vala',
  'src/ui/visual/step_island.vala',
  'src/ui/visual/sectioned_list.vala',
  'src/ui/visual/search_bubble.vala',
  'src/ui/visual/floating_panel.vala',
  'src/ui/visual/avatar.vala',
  'src/ui/visual/large_icon.vala',
  'src/ui/visual/clamp.vala',
  'src/ui/visual/theme_preview.vala',
  'src/ui/visual/data_list_view.vala',
  'src/ui/visual/data_grid_view.vala',
  'src/ui/visual/column_browser.vala',
  'src/ui/navigation/sidebar_row.vala',
  'src/ui/visual/overlay_search.vala',
  'src/ui/visual/command_palette.vala',
  'src/ui/visual/carousel.vala',
  'src/ui/visual/chip.vala',
  'src/ui/visual/toast.vala',
  'src/ui/visual/skeleton.vala',
  'src/ui/visual/banner.vala',
  'src/ui/pages/screenshot_carousel.vala',
  'src/ui/pages/image_viewer.vala',
  'src/ui/pages/calendar_views.vala',
  'src/calendar/calendar_contract.vala',
  'src/calendar/recurrence.vala',
  'src/calendar/ics.vala',
  'src/calendar/local_provider.vala',
  'src/calendar/web_provider.vala',
  'src/accounts/types.vala',
  'src/accounts/service_bus.vala',
  'src/accounts/account.vala',
  'src/accounts/manager.vala',
  'src/accounts/http.vala',
  'src/accounts/dav.vala',
  'src/accounts/content_lines.vala',
  'src/accounts/converters.vala',
  'src/accounts/remote_collection.vala',
  'src/accounts/api_collection.vala',
  'src/accounts/ews_collection.vala',
  'src/accounts/mirror_lock.vala',
  'src/accounts/synced_collection.vala',
  'src/accounts/collections.vala',
  'src/accounts/cloud_drive.vala',
  'src/accounts/cloud_file.vala',
  'src/accounts/cloud_mounts.vala',
  'src/accounts/share_links.vala',
  'src/accounts/cloud_share.vala',
  'src/notes/note.vala',
  'src/notes/note_store.vala',
  'src/notes/line_merge.vala',
  'src/notes/note_picker.vala',
  'src/collab/client.vala',
  'src/collab/document.vala',
  'src/collab/text.vala',
  'src/collab/session.vala',
  'src/util/qr_code.vala',
  'src/util/qr_decoder.vala',
  'src/share/share_content.vala',
  'src/share/share_target.vala',
  'src/share/share_sheet.vala',
  'src/share/nearby_client.vala',
  'src/share/nearby_target.vala',
  'src/share/live_session.vala',
  'src/text_recognition/recognized_text.vala',
  'src/text_recognition/text_recognizer.vala',
  'src/text_recognition/live_text_view.vala',
  'src/markup/markup_document.vala',
  'src/markup/markup_canvas.vala',
  'src/markup/markup_editor.vala',
  'src/markup/markup_window.vala',
  'src/print/ipp.vala',
  'src/print/model.vala',
  'src/print/media.vala',
  'src/print/layout.vala',
  'src/print/options.vala',
  'src/print/extra_options.vala',
  'src/print/presets.vala',
  'src/print/backend.vala',
  'src/print/sources.vala',
  'src/print/text_source.vala',
  'src/print/snapshot_source.vala',
  'src/print/render.vala',
  'src/print/preview.vala',
  'src/print/printer_widgets.vala',
  'src/print/dialog.vala',
  'src/print/monitor.vala',
  'src/print/print.vala',
  'src/print/page_setup.vala',
  'src/charts/chart_model.vala',
  'src/charts/chart_math.vala',
  'src/charts/chart_xml.vala',
  'src/charts/chart_painter.vala',
  'src/charts/chart_drawingml.vala',
  'src/charts/chart_odf.vala',
  'src/charts/chart_table.vala',
  'src/vector/geometry.vala',
  'src/vector/boolean.vala',
  'src/vector/curves.vala',
  'src/vector/offset.vala',
  'src/vector/stroke.vala',
  'src/vector/path_ops.vala',
  'src/vector/curve_boolean.vala',
  'src/vector/curve_offset.vala',
  'src/vector/path_shape.vala',
  'src/vector/warp.vala',
  'src/vector/planar.vala',
  'src/vector/trace.vala',
  'src/assets/asset_library.vala',
  'src/calendar/account_provider.vala',
  'src/core/environment.vala',
  'src/core/capabilities.vala',
  'src/core/settings_util.vala',
  'src/core/application.vala',
  'src/core/action_accels.vala',
  'src/core/shell_application.vala',
  'src/core/settings_contract.vala',
  'src/core/shell_contract.vala',
  'src/core/app_settings_contract.vala',
  'src/core/plugin_contract.vala',
  'src/core/files_plugin_contract.vala',
  'src/core/overview_widget_registry.vala',
  'src/core/shell_surface_contract.vala',
  'src/core/search_provider.vala',
  'src/core/search_provider_service.vala',
  'src/core/quick_tile.vala',
  'src/core/focus_status.vala',
  'src/core/dock_menu.vala',
  'src/core/plugin_preferences.vala',
  'src/core/app_plugin_host.vala',
  'src/core/camera_clients.vala',
  'src/core/microphone_clients.vala',
  'src/core/vpn_provider.vala',
  'src/core/wallpaper_provider.vala',
  'src/core/app_settings_loader.vala',
  'src/core/webkit_sockets.vala',
  'src/animation/animation.vala',
  'src/animation/timed_animation.vala',
  'src/animation/motion.vala',
  'src/animation/motion_math.vala',
  'src/animation/spring_animation.vala',
  'src/animation/keyframe_animation.vala',
  'src/animation/animation_group.vala',
  'src/animation/motion_bin.vala',
  'src/animation/list_animator.vala',
  'src/animation/child_transform.vala',
  'src/animation/page_transition.vala',
  'src/animation/control_motion.vala',
  'src/animation/snapshot_crossfade.vala',
  'src/animation/focus_ring.vala',
  'src/animation/drag_lift.vala',
  'src/animation/widget_morph.vala',
  'src/animation/motion_debug.vala',
  'src/style/accent_icons.vala',
  'src/style/style_manager.vala',
  'src/text/spell_checker.vala',
  'src/text/spell_integration.vala',
  'src/style/theme_mode.vala',
  'src/style/background_effect.vala',
  'src/accessibility/accessibility_manager.vala',
  'src/accessibility/screen_reader_settings.vala',
  'src/ui/visual/chart_widgets.vala',
  'src/ui/visual/circular_progress.vala',
  'src/ui/visual/media_player_card.vala',
  'src/ui/pages/browser_pill.vala',
  'src/core/terminal_themes.vala',
  'src/util/color_util.vala',
  'src/util/tiling_layout.vala',
  'src/util/tile_tree.vala',
  'src/util/grid_layout.vala',
  'src/util/hot_corner_logic.vala',
  'src/file_system/file_provider.vala',
  'src/file_system/recent_provider.vala',
  'src/file_system/samba_provider.vala',
  'src/file_system/thumbnail_cache.vala',
  'src/file_system/video_thumbnailer.vala',
  'src/media/video_paintable.vala',
  'src/media/media_playback.vala',
  'src/media/media_view.vala',
  'src/media/sources/types.vala',
  'src/media/sources/interfaces.vala',
  'src/media/sources/lyrics.vala',
  'src/media/sources/registry.vala',
  'src/media/sources/web.vala',
  'src/media/sources/app_host.vala',
  'src/media/sources/account_link.vala',
  'src/remote/des.vala',
  'src/remote/session.vala',
  'src/remote/rfb.vala',
  'src/remote/display.vala',
  'src/parental/parental_policy.vala',
  'src/parental/parental_store.vala',
  'src/parental/usage_store.vala',
  'src/equations/math_xml.vala',
  'src/equations/omml.vala',
  'src/equations/autocorrect.vala',
  'src/equations/numbering.vala',
  'src/equations/speech.vala',
  'src/equations/gallery.vala',
  'src/equations/equation.vala',
)

parental_policy_dir = get_option('prefix') / get_option('localstatedir') / 'lib' / 'singularity' / 'parental'
parental_c_args = [
  '-DSINGULARITY_PARENTAL_SYSCONFDIR="@0@"'.format(get_option('prefix') / get_option('sysconfdir')),
  '-DSINGULARITY_PARENTAL_DIR="@0@"'.format(parental_policy_dir),
  '-DSINGULARITY_PARENTAL_COMMAND="@0@"'.format('pkexec ' + get_option('prefix') / get_option('libexecdir') / 'singularity-parental-helper'),
]

libsingularity_vala_args = ['--vapidir', meson.current_source_dir() / 'src/vapi', '--pkg', 'gdkextra']
libsingularity_sources += files(
  'src/vapi/lcms2.vapi',
  'src/imaging/parallel.vala',
  'src/imaging/transfer.vala',
  'src/imaging/float_image.vala',
  'src/imaging/filters.vala',
  'src/imaging/blend.vala',
  'src/imaging/icc.vala',
  'src/imaging/tracking.vala',
  'src/keyframes/animated_value.vala',
  'src/audio/dsp.vala',
  'src/audio/loudness.vala',
)
if gtk4_dep.version().version_compare('>= 4.16')
  libsingularity_vala_args += ['-D', 'HAVE_TEXTURE_BUILDER']
endif

if get_option('layer-shell')
  libsingularity_sources += files(
    'src/shell/shell_dialog.vala',
    'src/shell/osd_overlay.vala',
    'src/shell/screen_flash.vala',
  )
endif

libsingularity = shared_library('singularity',
  libsingularity_sources + libsingularity_resources + [
    'src/wayland/surface_effect.c',
    'src/wayland/snap_button.c',
    'src/print/ipp_transport.c',
    'src/share/live_tls.c',
    'src/util/qr_decode.c',
    effect_protocol_c,
    effect_protocol_h,
    snap_protocol_c,
    snap_protocol_h,
    foreign_toplevel_protocol_c,
  ],
  dependencies: libsingularity_deps + [dependency('gnutls')],
  c_args: parental_c_args + lcms2_c_args,
  link_args: lcms2_link_args,
  vala_args: libsingularity_vala_args,
  include_directories: include_directories('src'),
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
  requires: libsingularity_requires,
)

install_data(
  'singularity-1.0.deps',
  install_dir: get_option('datadir') / 'vala' / 'vapi',
)

install_data('data/schemas/dev.sinty.toolbar.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas',
)

if get_option('system')
  gio_dep        = dependency('gio-2.0')
  giounix_dep    = dependency('gio-unix-2.0')
  pulse_dep      = dependency('libpulse')
  pulse_glib_dep = dependency('libpulse-mainloop-glib')
  gudev_dep      = dependency('gudev-1.0')
  upower_dep     = dependency('upower-glib', version: '>= 0.99.0')
  libnm_dep      = dependency('libnm', version: '>= 1.0.0')
  soup_sys_dep   = dependency('libsoup-3.0')

  libsingularity_system_deps = [
    gio_dep, giounix_dep, gee_dep,
    pulse_dep, pulse_glib_dep, gudev_dep, upower_dep,
    libnm_dep, soup_sys_dep, json_dep, m_dep,
  ]

  libsingularity_system_sources = files(
    'src/system/bluetooth_manager.vala',
    'src/system/datetime_manager.vala',
    'src/system/locale_manager.vala',
    'src/system/accounts_service.vala',
    'src/system/app_menu_registrar.vala',
    'src/system/shared_clock.vala',
    'src/system/power_profiles_manager.vala',
    'src/system/gamemode_manager.vala',
    'src/system/audio_manager.vala',
    'src/system/brightness_manager.vala',
    'src/system/ddc.vala',
    'src/system/kbd_brightness_manager.vala',
    'src/system/power_manager.vala',
    'src/system/dynamic_internet_socket.c',
    'src/system/dynamic_internet.vala',
    'src/system/nm_dynamic_internet_backend.vala',
    'src/system/nm_wrapper.vala',
    'src/system/call_monitor.vala',
    'src/system/now_playing_cache.vala',
    'src/system/session_manager.vala',
    'src/system/timezone_util.vala',
    'src/system/input_source_util.vala',
    'src/system/resource_monitor.vala',
    'src/system/night_light_manager.vala',
    'src/system/sun_times.vala',
    'src/system/color_profiles.vala',
    'src/system/autostart_manager.vala',
    'src/system/hardware_info.vala',
    'src/system/sensor.vala',
    'src/system/process_usage.vala',
    'src/system/utilization.vala',
    'src/system/fan_control_manager.vala',
    'src/system/permission_store.vala',
    'src/system/background_apps.vala',
    'src/system/portal_permissions.vala',
    'src/system/sandbox/sandbox_backend.vala',
    'src/system/sandbox/sandbox_catalog.vala',
    'src/system/sandbox/flatpak_backend.vala',
    'src/system/sandbox/cpak_backend.vala',
    'src/system/power_backends.vala',
    'src/system/battery_health.vala',
    'src/system/updates/update_provider.vala',
    'src/system/updates/update_config.vala',
    'src/system/updates/packagekit_provider.vala',
    'src/system/updates/atomic_provider.vala',
    'src/system/updates/firmware_client.vala',
    'src/system/updates/device_security.vala',
    'src/system/firewall.vala',
    'src/system/hostname_manager.vala',
    'src/system/equalizer.vala',
  )

  power_libexecdir = get_option('prefix') / get_option('libexecdir')
  power_charge_command = get_option('charge-limit-command')
  if power_charge_command == ''
    power_charge_command = 'pkexec ' + power_libexecdir / 'singularity-power-helper'
  endif
  firewall_helper_command = get_option('firewall-helper-command')
  if firewall_helper_command == ''
    firewall_helper_command = 'pkexec ' + power_libexecdir / 'singularity-firewall-helper'
  endif
  power_c_args = [
    '-DSINGULARITY_SYSCONFDIR="@0@"'.format(get_option('prefix') / get_option('sysconfdir')),
    '-DSINGULARITY_SUSPEND_COMMAND="@0@"'.format(get_option('suspend-command')),
    '-DSINGULARITY_CHARGE_LIMIT_COMMAND="@0@"'.format(power_charge_command),
    '-DSINGULARITY_FIREWALL_HELPER="@0@"'.format(firewall_helper_command),
    '-DSINGULARITY_FIREWALL_STATE="@0@"'.format(get_option('firewall-state-file')),
  ]
  updates_c_args = [
    '-DSINGULARITY_DEFAULT_UPDATES_BACKEND="@0@"'.format(get_option('updates-backend')),
    '-DSINGULARITY_DEFAULT_SANDBOX_BACKENDS="@0@"'.format(';'.join(get_option('sandbox-backends'))),
  ]

  libsingularity_system = shared_library('singularity-system',
    libsingularity_system_sources,
    dependencies: libsingularity_system_deps,
    vala_args: ['--pkg', 'posix', '--vapidir', meson.current_source_dir() / 'src/vapi'],
    c_args: power_c_args + updates_c_args,
    vala_header: 'singularity-system.h',
    vala_vapi: 'singularity-system-1.0.vapi',
    install: true,
    install_dir: [get_option('libdir'), true, true],
    soversion: '0',
    version: meson.project_version(),
  )

  libsingularity_system_dep = declare_dependency(
    link_with: libsingularity_system,
    include_directories: include_directories('.'),
    dependencies: libsingularity_system_deps,
  )

  libsingularity_system_vapi = meson.current_build_dir() / 'singularity-system-1.0.vapi'
  libsingularity_system_vapidir = meson.current_source_dir() / 'src' / 'vapi'

  pkgconfig.generate(
    libsingularity_system,
    name: 'libsingularity-system',
    description: 'Singularity Desktop headless system backends',
    version: meson.project_version(),
    filebase: 'singularity-system-1.0',
    requires: ['gio-2.0', 'gio-unix-2.0', 'gee-0.8', 'libpulse', 'libpulse-mainloop-glib', 'gudev-1.0', 'upower-glib', 'libnm', 'libsoup-3.0', 'json-glib-1.0'],
  )

  install_data(
    'singularity-system-1.0.deps',
    install_dir: get_option('datadir') / 'vala' / 'vapi',
  )

  hardware_info_test = executable(
    'hardware-info-test',
    files(
      'tests/hardware_info_test.vala',
      'src/system/hardware_info.vala',
    ),
    dependencies: [gio_dep, gee_dep],
  )
  test('hardware-info', hardware_info_test)

  autostart_test = executable(
    'autostart-test',
    files(
      'tests/autostart_test.vala',
      'src/system/autostart_manager.vala',
    ),
    dependencies: [gio_dep, giounix_dep, gee_dep],
  )
  test('autostart', autostart_test, env: ['TMPDIR=' + meson.current_build_dir()])

  sensor_test = executable(
    'sensor-test',
    files(
      'tests/sensor_test.vala',
      'src/system/sensor.vala',
    ),
    dependencies: [gio_dep, gee_dep],
  )
  test('sensor', sensor_test)

  process_usage_test = executable(
    'process-usage-test',
    files(
      'tests/process_usage_test.vala',
      'src/system/process_usage.vala',
    ),
    dependencies: [gio_dep, gee_dep],
  )
  test('process-usage', process_usage_test)

  ddc_test = executable(
    'ddc-test',
    files(
      'tests/ddc_test.vala',
      'src/system/ddc.vala',
    ),
    dependencies: [gio_dep],
    vala_args: ['--pkg', 'posix'],
  )
  test('ddc', ddc_test)

  brightness_test = executable(
    'brightness-test',
    files(
      'tests/brightness_test.vala',
      'src/system/brightness_manager.vala',
      'src/system/ddc.vala',
    ),
    dependencies: [gio_dep, gee_dep, gudev_dep],
    vala_args: ['--pkg', 'posix'],
  )
  test('brightness', brightness_test)

  utilization_test = executable(
    'utilization-test',
    files(
      'tests/utilization_test.vala',
      'src/system/utilization.vala',
      'src/system/sensor.vala',
    ),
    # giounix_dep: utilization.vala's is_real_filesystem() consults
    # GLib.UnixMountEntry (gio-unix-2.0) when proc_root is unset. The
    # fixture tests always set proc_root, so this path never actually runs
    # under test -- but the file still needs to LINK, and every valac
    # invocation compiles the whole file regardless of which branch a test
    # exercises.
    dependencies: [gio_dep, giounix_dep, gee_dep],
  )
  test('utilization', utilization_test)

  power_test = executable(
    'power-test',
    files(
      'tests/power_test.vala',
      'src/system/power_backends.vala',
      'src/system/battery_health.vala',
      'src/system/session_manager.vala',
    ),
    c_args: power_c_args,
    dependencies: [gio_dep, gee_dep, m_dep],
  )
  test('power', power_test, env: ['TMPDIR=' + meson.current_build_dir()])

  dynamic_internet_test = executable(
    'dynamic-internet-test',
    files(
      'tests/dynamic_internet_test.vala',
      'src/system/dynamic_internet.vala',
    ),
    dependencies: [gio_dep, gee_dep],
  )
  test('dynamic-internet', dynamic_internet_test)

  screen_reader_test = executable(
    'screen-reader-test',
    files(
      'tests/screen_reader_test.vala',
      'src/accessibility/screen_reader_settings.vala',
    ),
    dependencies: [gio_dep, gee_dep, json_dep, m_dep],
  )
  test('screen-reader', screen_reader_test, args: [meson.current_source_dir() / 'tests' / 'fixtures' / 'screen-reader'], env: ['TMPDIR=' + meson.current_build_dir()])

  privacy_test = executable(
    'privacy-test',
    files(
      'tests/privacy_test.vala',
      'src/system/permission_store.vala',
      'src/system/background_apps.vala',
      'src/core/camera_clients.vala',
      'src/core/microphone_clients.vala',
    ),
    dependencies: [gio_dep, giounix_dep, json_dep],
  )
  test('privacy', privacy_test)

  sandbox_test = executable(
    'sandbox-test',
    files(
      'tests/sandbox_test.vala',
      'src/system/permission_store.vala',
      'src/system/portal_permissions.vala',
      'src/system/sandbox/sandbox_backend.vala',
      'src/system/sandbox/sandbox_catalog.vala',
      'src/system/sandbox/flatpak_backend.vala',
      'src/system/sandbox/cpak_backend.vala',
    ),
    c_args: power_c_args + updates_c_args,
    dependencies: [gio_dep, giounix_dep, gee_dep, json_dep],
  )
  test('sandbox', sandbox_test, env: ['TMPDIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory'])

  updates_test = executable(
    'updates-test',
    files(
      'tests/updates_test.vala',
      'src/system/hardware_info.vala',
      'src/system/updates/update_provider.vala',
      'src/system/updates/update_config.vala',
      'src/system/updates/packagekit_provider.vala',
      'src/system/updates/atomic_provider.vala',
      'src/system/updates/firmware_client.vala',
      'src/system/updates/device_security.vala',
    ),
    c_args: power_c_args + updates_c_args,
    dependencies: [gio_dep, giounix_dep, gee_dep, soup_sys_dep],
    vala_args: ['--pkg', 'posix'],
  )
  test('updates', updates_test, env: ['TMPDIR=' + meson.current_build_dir()])

  firewall_test = executable(
    'firewall-test',
    files(
      'tests/firewall_test.vala',
      'src/system/firewall.vala',
      'src/system/hostname_manager.vala',
    ),
    c_args: power_c_args,
    dependencies: [gio_dep, giounix_dep, gee_dep],
  )
  test('firewall', firewall_test, env: ['TMPDIR=' + meson.current_build_dir()])

  equalizer_test = executable(
    'equalizer-test',
    files(
      'tests/equalizer_test.vala',
      'src/system/equalizer.vala',
      'src/system/audio_manager.vala',
    ),
    c_args: power_c_args,
    vala_args: ['--pkg', 'posix'],
    dependencies: [gio_dep, giounix_dep, gee_dep, pulse_dep, pulse_glib_dep, m_dep],
  )
  test('equalizer', equalizer_test, env: ['TMPDIR=' + meson.current_build_dir()])

  sun_times_test = executable(
    'sun-times-test',
    files(
      'tests/sun_times_test.vala',
      'src/system/sun_times.vala',
    ),
    dependencies: [gio_dep, m_dep],
  )
  test('sun-times', sun_times_test, args: [meson.current_source_dir() / 'tests' / 'fixtures' / 'zoneinfo'])

  color_profiles_test = executable(
    'color-profiles-test',
    files(
      'tests/color_profiles_test.vala',
      'src/system/color_profiles.vala',
    ),
    vala_args: ['--pkg', 'posix'],
    dependencies: [gio_dep, giounix_dep, gee_dep],
  )
  test('color-profiles', color_profiles_test, env: ['TMPDIR=' + meson.current_build_dir()])

  night_light_test = executable(
    'night-light-test',
    files(
      'tests/night_light_test.vala',
      'src/system/night_light_manager.vala',
      'src/system/sun_times.vala',
    ),
    vala_args: ['--pkg', 'posix'],
    dependencies: [gio_dep, gee_dep, m_dep],
  )
  test('night-light', night_light_test, env: ['TMPDIR=' + meson.current_build_dir()])

  install_data('data/dbus-1/dev.sinty.UpdateProvider1.xml',
    install_dir: get_option('datadir') / 'dbus-1' / 'interfaces')
endif

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

install_subdir('data/avatars', install_dir: get_option('datadir') / 'singularity')

calendar_test = executable(
  'calendar-test',
  files(
    'tests/calendar_test.vala',
    'src/calendar/calendar_contract.vala',
    'src/calendar/recurrence.vala',
    'src/calendar/ics.vala',
    'src/calendar/local_provider.vala',
    'src/calendar/web_provider.vala',
  ),
  dependencies: [gee_dep, json_dep, soup_dep, dependency('gio-2.0')],
)
test('calendar', calendar_test, env: ['TZ=Europe/Rome'])

extension_api_test = executable(
  'extension-api-test',
  files('tests/extension_api_test.vala'),
  dependencies: [libsingularity_dep],
)
test('extension-api', extension_api_test, env: ['TMPDIR=' + meson.current_build_dir(), 'GDK_BACKEND=wayland', 'WAYLAND_DISPLAY=singularity-test-no-display', 'DISPLAY='])

collab_test = executable(
  'collab-test',
  files('tests/collab_test.vala'),
  dependencies: [libsingularity_dep],
)
test('collab', collab_test, env: ['GSETTINGS_BACKEND=memory'])

widget_layout_test = executable(
  'widget-layout-test',
  files('tests/widget_layout_test.vala'),
  dependencies: [libsingularity_dep],
  vala_args: ['--pkg', 'posix'],
)
test('widget-layout', widget_layout_test, env: ['TMPDIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory'])

file_opener_test = executable(
  'file-opener-test',
  files('tests/file_opener_test.vala'),
  dependencies: [libsingularity_dep],
)
test('file-opener', file_opener_test, env: ['TMPDIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory'])

webkit_sockets_test = executable(
  'webkit-sockets-test',
  files('tests/webkit_sockets_test.vala'),
  dependencies: [libsingularity_dep],
)
test('webkit-sockets', webkit_sockets_test, env: ['TMPDIR=' + meson.current_build_dir()])

toolbar_test_schemas = custom_target('toolbar-test-schemas',
  input: 'data/schemas/dev.sinty.toolbar.gschema.xml',
  output: 'toolbar-schemas',
  command: ['sh', '-c', 'mkdir -p "$1" && glib-compile-schemas --strict --targetdir "$1" "$2"', 'sh', '@OUTPUT@', meson.current_source_dir() / 'data' / 'schemas'],
)

context_ribbon_test = executable(
  'context-ribbon-test',
  files('tests/context_ribbon_test.vala'),
  dependencies: [libsingularity_dep],
  vala_args: ['--pkg', 'posix'],
)
test('context-ribbon', context_ribbon_test, depends: [toolbar_test_schemas],
  env: ['TMPDIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory', 'GSETTINGS_SCHEMA_DIR=' + meson.current_build_dir() / 'toolbar-schemas',
        'XDG_DATA_DIRS=' + meson.current_build_dir() / 'toolbar-schemas', 'XDG_DATA_HOME=' + meson.current_build_dir() / 'toolbar-schemas'])

motion_test = executable(
  'motion-test',
  files('tests/motion_test.vala'),
  dependencies: [libsingularity_dep],
)
test('motion', motion_test, args: [meson.current_source_dir() / 'tests' / 'fixtures' / 'motion'], env: ['TMPDIR=' + meson.current_build_dir()])

motion_capture_test = executable(
  'motion-capture-test',
  files('tests/motion_capture_test.vala'),
  dependencies: [libsingularity_dep],
  vala_args: ['--pkg', 'posix'],
)
test('motion-capture', motion_capture_test, env: ['TMPDIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory'])

thumbnail_cache_test = executable(
  'thumbnail-cache-test',
  files('tests/thumbnail_cache_test.vala'),
  dependencies: [libsingularity_dep],
)
test('thumbnail-cache', thumbnail_cache_test, env: ['TMPDIR=' + meson.current_build_dir()], timeout: 120)

media_engine_test = executable(
  'media-engine-test',
  files('tests/media_engine_test.vala'),
  dependencies: [libsingularity_dep],
)
test('media-engine', media_engine_test)

subdir('tests/media-fake-source')
media_sources_test = executable(
  'media-sources-test',
  files('tests/media_sources_test.vala'),
  dependencies: [libsingularity_dep],
)
test('media-sources', media_sources_test, depends: [media_fake_source, media_test_schemas],
  env: ['TMPDIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory', 'GSETTINGS_SCHEMA_DIR=' + media_fake_source_dir,
        'SINGULARITY_MUSIC_PLUGIN_PATH=' + media_fake_source_dir, 'SINGULARITY_APP_PLUGIN_PATH=' + meson.current_build_dir() / 'tests'])

imaging_test = executable(
  'imaging-test',
  files('tests/imaging_test.vala'),
  dependencies: [libsingularity_dep],
)
test('imaging', imaging_test)

accounts_test = executable(
  'accounts-test',
  files('tests/accounts_test.vala'),
  dependencies: [libsingularity_dep],
)
test('accounts', accounts_test, env: ['TMPDIR=' + meson.current_build_dir(), 'TZ=Europe/Rome'])

account_tokens_test = executable(
  'account-tokens-test',
  files('tests/account_tokens_test.vala'),
  dependencies: [libsingularity_dep],
)
test('account-tokens', account_tokens_test, env: ['TMPDIR=' + meson.current_build_dir()])

tile_tree_test = executable(
  'tile-tree-test',
  files(
    'tests/tile_tree_test.vala',
    'src/util/tile_tree.vala',
  ),
  dependencies: [gtk4_dep, json_dep, m_dep],
)
test('tile-tree', tile_tree_test)

qr_code_test = executable(
  'qr-code-test',
  files(
    'tests/qr_code_test.vala',
    'src/util/qr_code.vala',
  ),
  dependencies: [gtk4_dep, gee_dep, m_dep],
)
test('qr-code', qr_code_test, args: [meson.current_source_dir() / 'tests' / 'fixtures' / 'qr'])

remote_test = executable(
  'remote-test',
  files('tests/remote_test.vala'),
  dependencies: [libsingularity_dep],
)
test('remote', remote_test)

mirror_lock_test = executable(
  'mirror-lock-test',
  files('tests/mirror_lock_test.vala'),
  dependencies: [libsingularity_dep],
)
test('mirror-lock', mirror_lock_test, timeout: 120)

parental_test = executable(
  'parental-test',
  files(
    'tests/parental_test.vala',
    'src/parental/parental_policy.vala',
    'src/parental/parental_store.vala',
    'src/parental/usage_store.vala',
  ),
  c_args: parental_c_args,
  vala_args: ['--pkg', 'posix'],
  dependencies: [dependency('gio-2.0'), gee_dep, json_dep],
)
test('parental', parental_test, env: ['TMPDIR=' + meson.current_build_dir(), 'TZ=Europe/Rome'])

share_links_test = executable(
  'share-links-test',
  files('tests/share_links_test.vala'),
  dependencies: [libsingularity_dep],
)
test('share-links', share_links_test, env: ['TMPDIR=' + meson.current_build_dir()], timeout: 120)

print_test = executable(
  'print-test',
  files('tests/print_test.vala'),
  dependencies: [libsingularity_dep],
)
test('print', print_test, env: ['TMPDIR=' + meson.current_build_dir()])

if get_option('sharing-host')
  sharing_host_protocols = []
  sharing_host_headers = []
  foreach proto : ['ext-foreign-toplevel-list-v1', 'ext-image-capture-source-v1', 'ext-image-copy-capture-v1',
                   'wlr-virtual-pointer-unstable-v1', 'virtual-keyboard-unstable-v1', 'ext-data-control-v1',
                   'xdg-output-unstable-v1']
    sharing_host_protocols += custom_target('sharing-host-' + proto + '-code',
      input: 'protocols' / proto + '.xml', output: proto + '-protocol.c',
      command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'])
    sharing_host_headers += custom_target('sharing-host-' + proto + '-header',
      input: 'protocols' / proto + '.xml', output: proto + '-client-protocol.h',
      command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'])
  endforeach
  sharing_host_protocols += sharing_host_headers

  sharing_host_glib_deps = [dependency('glib-2.0'), dependency('gobject-2.0'), dependency('gio-2.0'), dependency('gio-unix-2.0')]
  sharing_host_c_lib = static_library('singularity-sharing-host-wayland',
    files(
      'src/sharing_host/rd_wayland.c',
      'src/sharing_host/rd_keymap.c',
      'src/sharing_host/rd_encode.c',
      'src/sharing_host/rd_tls.c',
    ) + sharing_host_protocols,
    dependencies: sharing_host_glib_deps + [wayland_dep, dependency('xkbcommon'), dependency('gnutls'), dependency('zlib'), m_dep],
    pic: true,
  )
  sharing_host_lib = static_library('singularity-sharing-host',
    files('src/sharing_host/media_server.vala'),
    dependencies: sharing_host_glib_deps,
    vala_header: 'singularity-sharing-host.h',
    vala_vapi: 'singularity-sharing-host.vapi',
    pic: true,
  )
  sharing_host_vapidir = meson.current_source_dir() / 'src' / 'sharing_host'
  libsingularity_sharing_host_dep = declare_dependency(
    link_with: [sharing_host_lib, sharing_host_c_lib],
    sources: sharing_host_headers,
    include_directories: include_directories('src/sharing_host', '.'),
    dependencies: sharing_host_glib_deps,
  )

  sharing_host_test = executable('sharing-host-test',
    files('tests/sharing_host_test.c'),
    dependencies: [libsingularity_sharing_host_dep, dependency('xkbcommon'), dependency('zlib')],
  )
  test('sharing-host', sharing_host_test, env: ['XKB_DEFAULT_LAYOUT=', 'XKB_DEFAULT_VARIANT='])
endif

equations_test = executable(
  'equations-test',
  files('tests/equations_test.vala'),
  dependencies: [libsingularity_dep],
)
test('equations', equations_test,
  args: [meson.current_source_dir() / 'tests' / 'fixtures' / 'equations'],
  env: ['TMPDIR=' + meson.current_build_dir(), 'LANGUAGE=en', 'LC_ALL=C.UTF-8'],
)

vector_test = executable(
  'vector-test',
  files('tests/vector_test.vala'),
  dependencies: [libsingularity_dep],
)
test('vector', vector_test, env: ['TMPDIR=' + meson.current_build_dir()])

markup_test = executable(
  'markup-test',
  files('tests/markup_test.vala'),
  dependencies: [libsingularity_dep],
)
test('markup', markup_test, env: ['TMPDIR=' + meson.current_build_dir()])

text_recognition_test = executable(
  'text-recognition-test',
  files('tests/text_recognition_test.vala'),
  dependencies: [libsingularity_dep],
)
test('text-recognition', text_recognition_test,
  args: [meson.current_source_dir() / 'tests' / 'fixtures' / 'text-recognition'],
  env: ['TMPDIR=' + meson.current_build_dir(), 'LANGUAGE=en', 'LC_ALL=C.UTF-8'],
  timeout: 120,
)

text_recognition_conf = configuration_data()
text_recognition_conf.set('ENGINE', get_option('text-recognition-engine'))
text_recognition_conf.set('TESSERACT', get_option('tesseract'))
hint = get_option('text-recognition-install-hint')
text_recognition_conf.set('INSTALL_HINT', hint != '' ? 'InstallHint=' + hint : '')
configure_file(
  input: 'data/text-recognition/text-recognition.conf.in',
  output: 'text-recognition.conf',
  configuration: text_recognition_conf,
  install_dir: get_option('sysconfdir') / 'xdg' / 'singularity',
)

pdf_deps = [dependency('glib-2.0'), dependency('gobject-2.0'), dependency('gio-2.0'), gee_dep, dependency('gdk-pixbuf-2.0'), m_dep]
pdf_native_deps = [dependency('glib-2.0'), dependency('fontconfig'), dependency('harfbuzz'), dependency('harfbuzz-subset'), dependency('lcms2')]
pdf_native_lib = static_library('singularity-pdf-native',
  files('src/pdf/pdf_native.c'),
  dependencies: pdf_native_deps,
  pic: true,
)
pdf_lib = static_library('singularity-pdf',
  files(
    'src/pdf/pdf_object.vala',
    'src/pdf/pdf_encodings.vala',
    'src/pdf/pdf_lexer.vala',
    'src/pdf/pdf_filters.vala',
    'src/pdf/pdf_crypto.vala',
    'src/pdf/pdf_document.vala',
    'src/pdf/pdf_font.vala',
    'src/pdf/pdf_content.vala',
    'src/pdf/pdf_pages.vala',
    'src/pdf/pdf_outline.vala',
    'src/pdf/pdf_annots.vala',
    'src/pdf/pdf_attachments.vala',
    'src/pdf/pdf_forms.vala',
    'src/pdf/pdf_script.vala',
    'src/pdf/pdf_images.vala',
    'src/pdf/pdf_edit.vala',
    'src/pdf/pdf_redact.vala',
    'src/pdf/pdf_sanitize.vala',
    'src/pdf/pdf_optimize.vala',
    'src/pdf/pdf_standards.vala',
    'src/pdf/pdf_tags.vala',
    'src/pdf/pdf_stamp.vala',
    'src/pdf/pdf_sign.vala',
    'src/pdf/pdf_compare.vala',
    'src/pdf/pdf_scan.vala',
    'src/pdf/pdf_linearize.vala',
  ),
  dependencies: pdf_deps,
  vala_args: ['--vapidir', meson.current_source_dir() / 'src' / 'pdf', '--pkg', 'pdf-native'],
  c_args: ['-I' + meson.current_source_dir() / 'src' / 'pdf'],
  vala_header: 'singularity-pdf.h',
  vala_vapi: 'singularity-pdf.vapi',
  pic: true,
)
libsingularity_pdf_dep = declare_dependency(
  link_with: [pdf_lib, pdf_native_lib],
  include_directories: include_directories('.', 'src/pdf'),
  dependencies: pdf_deps,
)

pdf_engine_test = executable('pdf-engine-test',
  files('tests/pdf_engine_test.vala'),
  dependencies: [libsingularity_pdf_dep, dependency('cairo')],
  vala_args: ['--pkg', 'cairo'],
)
test('pdf-engine', pdf_engine_test, env: ['TMPDIR=' + meson.current_build_dir()], timeout: 120)
