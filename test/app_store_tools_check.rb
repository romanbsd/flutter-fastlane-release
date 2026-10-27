# frozen_string_literal: true

# Offline checks for tools/: no credentials, Apple requests or uploads.
require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/app_store_screenshots'

class AppStoreToolsCheck < Minitest::Test
  PNG = ("\x89PNG\r\n\x1a\n".b + [13].pack('N') + 'IHDR' + [1206, 2622].pack('NN') + ("\x00".b * 13)).freeze
  OP = { 'url' => 'https://upload.apple.com/asset', 'method' => 'PUT', 'offset' => 0, 'length' => 33,
         'requestHeaders' => [{ 'name' => 'Content-Type', 'value' => 'image/png' }] }.freeze

  def test_png_header_and_dimensions
    AppStoreScreenshots.validate_png!(PNG, [1206, 2622])
    [
      -> { AppStoreScreenshots.validate_png!(PNG.byteslice(0, 20), [1206, 2622]) },
      -> { AppStoreScreenshots.validate_png!(PNG, [2064, 2752]) },
      -> { AppStoreScreenshots.validate_png!(PNG.byteslice(0, 8) + [12].pack('N') + PNG.byteslice(12..), [1206, 2622]) },
      -> { AppStoreScreenshots.validate_png!('invalid'.b + PNG, [1206, 2622]) }
    ].each { |check| assert_raises(AppStoreStatus::AuditError, &check) }
  end

  def test_upload_operations_stay_on_apple_hosts_and_cover_the_file
    AppStoreScreenshots.validate_operations!([OP], 33)
    unsafe = %w[https://apple.com.attacker.example/asset http://upload.apple.com/asset
                https://upload.apple.com:444/asset https://user@upload.apple.com/asset].map { |url| [OP.merge('url' => url)] }
    unsafe += [[OP.merge('method' => 'POST')], [OP.merge('offset' => 1)]]
    unsafe.each { |ops| assert_raises(AppStoreStatus::AuditError) { AppStoreScreenshots.validate_operations!(ops, 33) } }
    assert_raises(AppStoreStatus::AuditError) { AppStoreScreenshots.validate_operations!([OP], 34) }
    %w[Authorization Proxy-Authorization Cookie Host].each do |name|
      ops = [OP.merge('length' => 16),
             OP.merge('offset' => 16, 'length' => 17, 'requestHeaders' => [{ 'name' => name, 'value' => 'blocked' }])]
      assert_raises(AppStoreStatus::AuditError) { AppStoreScreenshots.validate_operations!(ops, 33) }
    end
  end

  def test_app_context_reads_the_appfile_and_env_from_any_app_subdirectory
    in_app("app_identifier('org.example.app')\n") do |root|
      Dir.chdir(File.join(root, 'lib')) do
        assert_equal File.realpath(root), File.realpath(AppContext.root)
        assert_equal 'org.example.app', AppContext.bundle_id
        assert_equal File.realpath(File.join(root, 'keys')), File.realpath(File.dirname(AppContext.api_key_path))
      end
    end
  end

  def test_app_identifier_env_wins_and_a_computed_appfile_is_rejected
    in_app("app_identifier(ENV['BUNDLE'])\n") do |root|
      Dir.chdir(root) do
        assert_raises(ArgumentError) { AppContext.bundle_id }
        with_env('APP_IDENTIFIER' => 'org.example.override') { assert_equal 'org.example.override', AppContext.bundle_id }
      end
    end
  end

  def test_screenshot_manifest_lists_each_slot_folder_in_order
    in_app("app_identifier('org.example.app')\n") do |root|
      slot = File.join(root, 'fastlane', 'screenshots', 'en-US', 'iphone-medium')
      FileUtils.mkdir_p(slot)
      File.binwrite(File.join(slot, '02-b.png'), PNG)
      File.binwrite(File.join(slot, '01-a.png'), PNG)
      Dir.chdir(root) do
        tool = AppStoreScreenshots.allocate
        assert_equal %w[01-a.png 02-b.png], tool.manifest.map { |file| file[:name] }
      end
    end
  end

  private

  def in_app(appfile)
    Dir.mktmpdir('app-store-tools-') do |root|
      FileUtils.mkdir_p(File.join(root, 'fastlane'))
      FileUtils.mkdir_p(File.join(root, 'lib'))
      File.write(File.join(root, 'pubspec.yaml'), "name: fixture\nversion: 1.0.0+1\n")
      File.write(File.join(root, 'fastlane', 'Fastfile'), "# frozen_string_literal: true\n")
      File.write(File.join(root, 'fastlane', 'Appfile'), appfile)
      File.write(File.join(root, 'fastlane', '.env'), "APP_STORE_CONNECT_API_KEY_PATH=keys/asc.json\n")
      FileUtils.mkdir_p(File.join(root, 'keys'))
      with_env('APP_IDENTIFIER' => nil, 'APP_STORE_CONNECT_API_KEY_PATH' => nil) { yield root }
    end
  end

  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end
