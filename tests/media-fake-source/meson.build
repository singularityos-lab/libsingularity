media_fake_source = shared_module('media-fake-source',
  files('fake_source.vala'),
  dependencies: [libsingularity_dep],
)
configure_file(input: 'fake-source.plugin', output: 'fake-source.plugin', copy: true)
media_test_schemas = custom_target('media-test-schemas',
  input: 'dev.sinty.test.plugins.gschema.xml',
  output: 'gschemas.compiled',
  command: [find_program('glib-compile-schemas'), '--targetdir', meson.current_build_dir(), meson.current_source_dir()],
)
media_fake_source_dir = meson.current_build_dir()
