# frozen_string_literal: true

require 'digest'
require 'fastlane'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'tmpdir'

Fastlane.load_actions

class SharedReleaseCheck < Minitest::Test
  FASTFILE = File.expand_path('../Fastfile', __dir__)

  def setup
    @saved_env = ENV.to_h
    @root = Dir.mktmpdir('flutter-release-check-')
    write('pubspec.yaml', "name: fixture\nversion: 1.1.0+26\n")
    write('fastlane/release_notes/1.1.0+28.txt', "iOS changes\n")
    write('fastlane/release_notes/1.1.0+31.txt', "Android changes\n")
    write('android/key.properties', 'fixture only')
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
    assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.release_plan([:android]) }
    ENV['ANDROID_BUILD_NUMBER'] = '31'
    ENV['IOS_BUILD_NUMBER'] = '27'
    assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.release_plan([:ios]) }
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
  end

  def test_firebase_distribution_is_opt_in_and_uses_app_configuration
    ENV.delete('ENABLE_FIREBASE_DISTRIBUTION')
    assert_raises(FastlaneCore::Interface::FastlaneError) { @fastfile.firebase_distribution_enabled! }
    ENV['ENABLE_FIREBASE_DISTRIBUTION'] = 'true'
    @fastfile.firebase_distribution_enabled!
    assert_equal 'ios-fixture', @fastfile.firebase_app_id(:ios)
    assert_equal 'android-fixture', @fastfile.firebase_app_id(:android)
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

  private

  def write(path, content)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end
end
