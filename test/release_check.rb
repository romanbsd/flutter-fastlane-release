# frozen_string_literal: true

require 'digest'
require 'fastlane'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/codex_runner'

Fastlane.load_actions

class SharedReleaseCheck < Minitest::Test
  FASTFILE = File.expand_path('../Fastfile', __dir__)

  def test_notes_runner_does_not_inherit_release_secrets
    Dir.mktmpdir('codex-runner-check-') do |root|
      log = File.join(root, 'log.txt')
      ENV['ANDROID_KEYSTORE_PASSWORD'] = 'fixture-secret'
      CodexRunner.run([Gem.ruby, '-e', 'puts ENV.fetch("ANDROID_KEYSTORE_PASSWORD", "absent")'],
                      root: root, timeout: 5, log_path: log)
      assert_equal "absent\n", File.read(log)
    ensure
      ENV.delete('ANDROID_KEYSTORE_PASSWORD')
    end
  end

  def test_notes_runner_classifies_non_utf8_failures
    Dir.mktmpdir('codex-runner-check-') do |root|
      log = File.join(root, 'log.txt')
      error = assert_raises(CodexRunner::Error) do
        CodexRunner.run([Gem.ruby, '-e', 'STDOUT.binmode; STDOUT.write("\\xFFHTTP 401"); exit 1'],
                        root: root, timeout: 5, log_path: log)
      end
      assert_match(/authentication failed/, error.message)
    end
  end

  def test_ios_encryption_declaration_uses_embedded_value_and_rejects_conflict
    info_path = File.join(@root, 'ios', 'Runner', 'Info.plist')
    File.write(info_path, '<?xml version="1.0"?><plist version="1.0"><dict><key>ITSAppUsesNonExemptEncryption</key><false/></dict></plist>')
    ENV.delete('USES_NON_EXEMPT_ENCRYPTION')
    assert_equal false, @fastfile.ios_encryption_declaration
    ENV['USES_NON_EXEMPT_ENCRYPTION'] = 'true'
    error = assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.ios_encryption_declaration }
    assert_match(/conflicts/, error.message)
    File.delete(info_path)
    error = assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.ios_encryption_declaration }
    assert_match(/Info.plist is missing/, error.message)
  end

  def setup
    @saved_env = ENV.to_h
    @root = Dir.mktmpdir('flutter-release-check-')
    write('pubspec.yaml', "name: fixture\nversion: 1.1.0+26\n")
    write('fastlane/release_notes/1.1.0+28.txt', "iOS changes\n")
    write('fastlane/release_notes/1.1.0+31.txt', "Android changes\n")
    write('fastlane/release_notes/1.1.0+27.txt', "Earlier iOS changes\n")
    write('fastlane/release_notes/1.1.0+30.txt', "Earlier Android changes\n")
    write('android/key.properties', "storeFile=fixture.jks\nstorePassword=fixture\nkeyAlias=fixture\nkeyPassword=fixture\n")
    write('android/app/google-services.json', '{"client":[{"client_info":{"mobilesdk_app_id":"android-fixture"}}]}')
    FileUtils.mkdir_p(File.join(@root, 'ios/Runner'))
    write('ios/Runner/Info.plist', '<?xml version="1.0"?><plist version="1.0"><dict/></plist>')
    write('ios/Runner/GoogleService-Info.plist', '<?xml version="1.0"?><plist version="1.0"><dict><key>GOOGLE_APP_ID</key><string>ios-fixture</string></dict></plist>')
    system('git', '-C', @root, 'init', '-q', exception: true)
    system('git', '-C', @root, 'add', '.', exception: true)
    system('git', '-C', @root, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
           'commit', '-qm', 'fixture', exception: true)
    ENV['IOS_BUILD_NUMBER'] = '28'
    ENV['ANDROID_BUILD_NUMBER'] = '31'
    ENV['APPLE_TEAM_ID'] = 'TEAM'
    ENV['USES_NON_EXEMPT_ENCRYPTION'] = 'false'
    ENV['PLAY_STORE_BETA_TRACK'] = 'alpha'
    ENV.delete('RELEASE_NOTES_FILE')
    @fastfile = Fastlane::FastFile.new(FASTFILE)
    @fastfile.define_singleton_method(:project_root) { @fixture_root }
    @fastfile.instance_variable_set(:@fixture_root, @root)
    @fastfile.define_singleton_method(:ensure_git_status_clean) { |**_| true }
    @fastfile.define_singleton_method(:is_ci) { false }
    @fastfile.define_singleton_method(:ensure_ios_toolchain!) { true }
    @fastfile.define_singleton_method(:sh) do |*args, **_|
      args.first == 'git' ? "fixture-commit\n" : ''
    end
    @fastfile.define_singleton_method(:latest_testflight_build_number) { |**_| 27 }
    @fastfile.define_singleton_method(:google_play_track_version_codes) { |**_| [30] }
  end

  def teardown
    ENV.replace(@saved_env)
    FileUtils.remove_entry(@root)
  end

  def test_distinct_platform_build_numbers_and_committed_notes
    plan = @fastfile.release_plan(%i[ios android])
    assert_equal({ ios: 28, android: 31 }, plan[:build_numbers])
    assert_equal 'iOS changes', plan[:ios][:changelog]
    assert_equal 'Android changes', plan[:android_notes]
    assert_equal 'fixture-commit', plan[:commit]
  end

  def test_store_number_checks_fail_before_build
    ENV['ANDROID_BUILD_NUMBER'] = '30'
    error = assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.release_plan([:android]) }
    assert_match(/must exceed.*Play tracks/, error.message)
    ENV['ANDROID_BUILD_NUMBER'] = '31'
    ENV['IOS_BUILD_NUMBER'] = '27'
    error = assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.release_plan([:ios]) }
    assert_match(/must exceed.*iOS build/, error.message)
  end

  def test_build_only_requires_its_own_explicit_build_number
    ENV.delete('ANDROID_BUILD_NUMBER')
    assert_raises(FastlaneCore::Interface::FastlaneError) do
      @fastfile.release_plan([:android], for_upload: false)
    end
    ENV['ANDROID_BUILD_NUMBER'] = '31'
    plan = @fastfile.release_plan([:android], for_upload: false)
    assert_equal 31, plan[:build_numbers][:android]
  end

  def test_android_signing_requires_all_configuration_fields
    write('android/key.properties', "storeFile=fixture.jks\n")
    error = assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.ensure_android_release_signing! }
    assert_match(/ANDROID_KEYSTORE_PASSWORD/, error.message)
  end

  def test_ios_toolchain_requires_current_xcode_and_sdk
    @fastfile.singleton_class.remove_method(:ensure_ios_toolchain!)
    @fastfile.define_singleton_method(:sh) do |*args, **_|
      args.first == 'xcodebuild' ? "Xcode 25.4\nBuild version 1\n" : "26.0\n"
    end
    error = assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.ensure_ios_toolchain! }
    assert_match(/Xcode 26/, error.message)
  end

  def test_ios_non_store_preflight_does_not_require_app_store_toolchain
    @fastfile.define_singleton_method(:ensure_ios_toolchain!) { raise 'App Store-only check invoked' }
    plan = @fastfile.release_plan([:ios], for_upload: false)
    assert_equal 28, plan[:build_numbers][:ios]
  end

  def test_missing_or_uncommitted_notes_fail_closed
    ENV['ANDROID_BUILD_NUMBER'] = '32'
    assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.release_plan([:android]) }
    write('fastlane/release_notes/1.1.0+32.txt', 'uncommitted notes')
    assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.release_plan([:android]) }
    ENV['ANDROID_BUILD_NUMBER'] = '31'
    write('fastlane/release_notes/1.1.0+31.txt', 'edited notes')
    assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.release_plan([:android]) }
  end

  def test_receipt_checksums_bind_retry_to_build_and_notes
    artifact = write('build/ios/ipa/fixture.ipa', 'ipa bytes')
    notes = @fastfile.release_notes(version: '1.1.0', build_number: 28)
    status = {
      version: '1.1.0', platforms: {
        ios: { build_number: 28, sha256: Digest::SHA256.file(artifact).hexdigest,
               notes_sha256: Digest::SHA256.hexdigest(notes) }
      }
    }
    write('build/release/status.json', JSON.generate(status))
    @fastfile.verify_existing_artifact!(artifact, platform: :ios, version: '1.1.0', build_number: 28, notes: notes)
    write('build/ios/ipa/fixture.ipa', 'changed bytes')
    assert_raises(FastlaneCore::Interface::FastlaneError) do
      @fastfile.verify_existing_artifact!(artifact, platform: :ios, version: '1.1.0', build_number: 28, notes: notes)
    end
  end

  def test_existing_artifact_must_match_appfile_identity
    @fastfile.define_singleton_method(:expected_app_identifier) { |_field| 'org.example.fixture' }
    @fastfile.define_singleton_method(:get_ipa_info_plist_value) do |ipa:, key:|
      key == 'DTPlatformName' ? 'iphoneos' : 'org.example.other'
    end
    assert_raises(FastlaneCore::Interface::FastlaneError) do
      @fastfile.verify_artifact_identity!('fixture.ipa', platform: :ios)
    end
    @fastfile.define_singleton_method(:aab_manifest_value) { |_path, _attribute| 'org.example.other' }
    assert_raises(FastlaneCore::Interface::FastlaneError) do
      @fastfile.verify_artifact_identity!('fixture.aab', platform: :android)
    end
  end

  def test_explicit_shared_bump_action_only_changes_pubspec
    path = File.join(@root, 'pubspec.yaml')
    action = Fastlane::Actions::BumpPubspecBuildAction
    assert_equal 27, action.run(pubspec_path: path)
    assert_includes File.read(path), 'version: 1.1.0+27'
    assert_raises(FastlaneCore::Interface::FastlaneError) do
      action.run(pubspec_path: path, build_number: 27)
    end
    assert_equal 30, action.run(pubspec_path: path, build_number: 30)
    assert_includes File.read(path), 'version: 1.1.0+30'
    assert_raises(FastlaneCore::Interface::FastlaneError) do
      action.run(pubspec_path: path, build_number: 2_100_000_001)
    end
  end

  def test_firebase_distribution_is_opt_in_and_uses_app_configuration
    ENV.delete('ENABLE_FIREBASE_DISTRIBUTION')
    assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.firebase_distribution_enabled! }
    ENV['ENABLE_FIREBASE_DISTRIBUTION'] = 'true'
    @fastfile.firebase_distribution_enabled!
    assert_equal 'ios-fixture', @fastfile.firebase_app_id(:ios)
    assert_equal 'android-fixture', @fastfile.firebase_app_id(:android)
  end

  def test_external_testflight_requires_beta_test_information
    ENV['TESTFLIGHT_DISTRIBUTE_EXTERNAL'] = 'true'
    ENV['TESTFLIGHT_GROUPS'] = 'External'
    ENV.delete('TESTFLIGHT_BETA_APP_DESCRIPTION')
    ENV.delete('TESTFLIGHT_BETA_APP_FEEDBACK_EMAIL')
    error = assert_raises(FastlaneCore::Interface::FastlaneError) do
      @fastfile.testflight_options(include_compliance: false)
    end
    assert_match(/BETA_APP_DESCRIPTION/, error.message)
    ENV['TESTFLIGHT_BETA_APP_DESCRIPTION'] = 'Try the beta features.'
    ENV['TESTFLIGHT_BETA_APP_FEEDBACK_EMAIL'] = 'feedback@example.test'
    options = @fastfile.testflight_options(include_compliance: false)
    assert_equal 'Try the beta features.', options[:beta_app_description]
    assert_equal 'feedback@example.test', options[:beta_app_feedback_email]
  end

  def test_combined_release_records_confirmed_and_unknown_upload_outcomes
    ipa = write('build/ios/ipa/fixture.ipa', 'ipa bytes')
    aab = write('build/app/outputs/bundle/release/fixture.aab', 'aab bytes')
    @fastfile.define_singleton_method(:prepare_release) { |_| nil }
    @fastfile.define_singleton_method(:build_signed_ios_ipa) { |*_args| ipa }
    @fastfile.define_singleton_method(:build_android_aab) { |_number| aab }
    @fastfile.define_singleton_method(:upload_to_testflight) { |**_options| true }
    @fastfile.define_singleton_method(:upload_android_aab) { |*_args| raise 'simulated upload interruption' }

    assert_raises(RuntimeError) { @fastfile.run_beta_release(%i[ios android]) }
    status = JSON.parse(File.read(File.join(@root, 'build/release/status.json')))
    assert_equal 'failed', status['state']
    assert_equal 'uploaded', status.dig('platforms', 'ios', 'status')
    assert_equal 'upload_outcome_unknown', status.dig('platforms', 'android', 'status')
    assert_equal Digest::SHA256.file(aab).hexdigest, status.dig('platforms', 'android', 'sha256')
    assert_equal 28, status.dig('build_numbers', 'ios')
    assert_equal 31, status.dig('build_numbers', 'android')
  end

  def test_status_write_failure_preserves_original_release_error
    @fastfile.define_singleton_method(:release_plan) { |_platforms| raise 'original release failure' }
    @fastfile.define_singleton_method(:write_release_status) do |plan, _results|
      raise 'status write failure' if plan[:state] == 'failed'
    end
    error = assert_raises(RuntimeError) { @fastfile.run_beta_release([:android]) }
    assert_equal 'original release failure', error.message
  end

  private

  def write(path, content)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end
end
