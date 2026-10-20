# frozen_string_literal: true

require 'digest'
require 'fastlane'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'plist'
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
           '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture', exception: true)
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
    assert_includes File.read(File.join(@root, 'pubspec.yaml')), 'version: 1.1.0+26'
  end

  def test_release_plan_bumps_pubspec_and_commits_existing_notes
    ENV.delete('ANDROID_BUILD_NUMBER')
    configure_git_identity
    called = false
    @fastfile.define_singleton_method(:generate_release_notes) { |*_args| called = true }
    plan = @fastfile.release_plan([:android])
    assert_equal 31, plan[:build_numbers][:android]
    assert_equal 'Android changes', plan[:android_notes]
    refute called
    assert_includes File.read(File.join(@root, 'pubspec.yaml')), 'version: 1.1.0+31'
    assert_equal 'Bump build to 1.1.0+31.', git_stdout('log', '-1', '--format=%s').strip
    assert_includes git_stdout('show', 'HEAD:pubspec.yaml'), 'version: 1.1.0+31'
  end

  def test_release_plan_generates_missing_notes_and_commits_them
    ENV.delete('ANDROID_BUILD_NUMBER')
    configure_git_identity
    File.delete(File.join(@root, 'fastlane/release_notes/1.1.0+31.txt'))
    @fastfile.define_singleton_method(:generate_release_notes) do |path, _max|
      File.write(path, "Fixed the Android startup hang.\n")
    end
    plan = @fastfile.release_plan([:android])
    assert_equal 'Fixed the Android startup hang.', plan[:android_notes]
    assert_equal "Fixed the Android startup hang.\n", git_stdout('show', 'HEAD:fastlane/release_notes/1.1.0+31.txt')
    assert_includes git_stdout('show', 'HEAD:pubspec.yaml'), 'version: 1.1.0+31'
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
    receipts = JSON.parse(File.read(File.join(@root, 'build/release/receipts.json')))
    assert_equal Digest::SHA256.file(ipa).hexdigest, receipts.dig('ios', '1.1.0+28', 'sha256')
    assert_equal 31, receipts.dig('android', '1.1.0+31', 'build_number')
  end

  def test_receipts_survive_a_later_run_that_fails_before_building
    artifact = write('build/ios/ipa/fixture.ipa', 'ipa bytes')
    notes = @fastfile.release_notes(version: '1.1.0', build_number: 28)
    @fastfile.record_artifact_receipt({ run_id: 'run-1', version: '1.1.0' }, :ios,
                                      build_number: 28,
                                      sha256: Digest::SHA256.file(artifact).hexdigest,
                                      notes_sha256: Digest::SHA256.hexdigest(notes))
    # A later attempt overwrites status.json before preflight can fail.
    @fastfile.write_release_status({ run_id: 'run-2', state: 'running', phase: 'preflight' },
                                   { ios: { status: 'planned' } })
    @fastfile.verify_existing_artifact!(artifact, platform: :ios, version: '1.1.0',
                                        build_number: 28, notes: notes)
  end

  def test_prepare_release_rechecks_dependency_files_after_pub_get
    events = []
    @fastfile.define_singleton_method(:flutter) { |*args| events << args.first }
    @fastfile.define_singleton_method(:ensure_release_inputs_committed) { events << :inputs_check }
    @fastfile.define_singleton_method(:current_commit) { 'fixture-commit' }
    plan = { clean: true, run_id: 'run' }

    @fastfile.prepare_release(plan)

    assert_equal %w[clean pub], events.first(2)
    assert_equal :inputs_check, events.last
    assert_equal 'fixture-commit', plan[:commit]
  end

  def test_release_inputs_must_match_the_committed_files
    @fastfile.ensure_release_inputs_committed
    write('pubspec.yaml', "name: fixture\nversion: 1.1.0+27\n")
    error = assert_raises(FastlaneCore::Interface::FastlaneError) do
      @fastfile.ensure_release_inputs_committed
    end
    assert_match(/pubspec.yaml changed/, error.message)
  end

  def test_next_store_build_uses_the_next_unused_number
    assert_equal 31, @fastfile.next_store_build(26, 30)
    assert_equal 31, @fastfile.next_store_build(30, 30)
    assert_equal 35, @fastfile.next_store_build(35, 30)
  end

  def test_plan_only_release_does_not_write_or_commit
    ENV.delete('IOS_BUILD_NUMBER')
    ENV.delete('ANDROID_BUILD_NUMBER')
    configure_git_identity
    @fastfile.define_singleton_method(:generate_release_notes) do |*_args|
      raise 'notes must not be generated by a plan-only run'
    end
    commits_before = git_stdout('rev-list', '--count', 'HEAD').to_i

    plan = @fastfile.release_plan(%i[ios android], prepare: false)

    assert_equal({ ios: 31, android: 31 }, plan[:build_numbers])
    assert_includes File.read(File.join(@root, 'pubspec.yaml')), 'version: 1.1.0+26'
    assert_equal commits_before, git_stdout('rev-list', '--count', 'HEAD').to_i
    assert_equal 'fixture', git_stdout('log', '-1', '--format=%s').strip
  end

  def test_automatic_release_reuses_the_committed_build_on_retry
    ENV.delete('ANDROID_BUILD_NUMBER')
    configure_git_identity

    first = @fastfile.release_plan([:android])
    second = @fastfile.release_plan([:android])

    assert_equal 31, first[:build_numbers][:android]
    assert_equal 31, second[:build_numbers][:android]
    assert_equal 2, git_stdout('rev-list', '--count', 'HEAD').to_i
    assert_includes git_stdout('show', 'HEAD:pubspec.yaml'), 'version: 1.1.0+31'
  end

  def test_release_commit_leaves_unrelated_staged_changes_alone
    configure_git_identity
    write('app.txt', "v1\n")
    system('git', '-C', @root, 'add', 'app.txt', exception: true)
    system('git', '-C', @root, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'add app', exception: true)
    write('app.txt', "v2\n")
    system('git', '-C', @root, 'add', 'app.txt', exception: true)
    write('pubspec.yaml', "name: fixture\nversion: 1.1.0+32\n")

    @fastfile.commit_release_changes([File.join(@root, 'pubspec.yaml')], 'Bump build to 1.1.0+32.')

    assert_equal 'Bump build to 1.1.0+32.', git_stdout('log', '-1', '--format=%s').strip
    assert_equal "v1\n", git_stdout('show', 'HEAD:app.txt')
    assert_equal "v2\n", git_stdout('show', ':app.txt')
  end

  def test_receipts_keep_older_builds
    artifact = write('build/ios/ipa/fixture.ipa', 'ipa bytes')
    notes = @fastfile.release_notes(version: '1.1.0', build_number: 28)
    sha = Digest::SHA256.file(artifact).hexdigest
    @fastfile.record_artifact_receipt({ run_id: 'run-1', version: '1.1.0' }, :ios,
                                      build_number: 28, sha256: sha,
                                      notes_sha256: Digest::SHA256.hexdigest(notes))
    @fastfile.record_artifact_receipt({ run_id: 'run-2', version: '1.2.0' }, :ios,
                                      build_number: 40, sha256: 'newer',
                                      notes_sha256: 'notes')

    receipts = JSON.parse(File.read(File.join(@root, 'build/release/receipts.json')))
    assert_equal sha, receipts.dig('ios', '1.1.0+28', 'sha256')
    assert_equal 'newer', receipts.dig('ios', '1.2.0+40', 'sha256')
    @fastfile.verify_existing_artifact!(artifact, platform: :ios, version: '1.1.0',
                                        build_number: 28, notes: notes)
  end

  def test_store_listing_targets_latest_release_and_skips_changelogs
    ENV.delete('PLAY_STORE_VERSION_CODE')
    ENV.delete('SUPPLY_VERSION_CODE')
    @fastfile.define_singleton_method(:google_play_track_version_codes) { |**_options| [40, 41] }

    options = @fastfile.play_store_listing_options('/tmp/metadata')

    assert_equal 41, options[:version_code]
    assert options[:skip_upload_changelogs]
    assert options[:skip_upload_apk]
  end

  def test_store_listing_uses_explicit_version_and_uploads_changelogs
    ENV['PLAY_STORE_VERSION_CODE'] = '40'
    @fastfile.define_singleton_method(:google_play_track_version_codes) do |**_options|
      raise 'track lookup must be skipped'
    end

    options = @fastfile.play_store_listing_options('/tmp/metadata')

    assert_equal 40, options[:version_code]
    refute options[:skip_upload_changelogs]
  end

  def test_plan_only_validates_notes_for_explicit_numbers_in_a_mixed_release
    ENV.delete('ANDROID_BUILD_NUMBER')
    ENV['IOS_BUILD_NUMBER'] = '29'

    error = assert_raises(FastlaneCore::Interface::FastlaneError) do
      @fastfile.release_plan(%i[ios android], prepare: false)
    end
    assert_match(/Release notes missing/, error.message)
  end

  def test_ios_firebase_build_requests_adhoc_export
    write('ios/Runner.xcodeproj/project.pbxproj', 'fixture project')
    stub_signing
    calls = []
    @fastfile.define_singleton_method(:flutter) { |*args| calls << args }

    assert_equal 'fixture.ipa', @fastfile.build_signed_ios_adhoc_ipa({}, 'TEAM', 28)
    assert_equal ['build', 'ipa', '--release', '--export-method', 'ad-hoc', '--build-number=28'],
                 calls.first
    assert_equal 'fixture project',
                 File.read(File.join(@root, 'ios/Runner.xcodeproj/project.pbxproj'))
    refute File.exist?(File.join(@root, 'ios/Runner.xcodeproj/project.pbxproj.fastlane-backup'))
  end

  def test_ios_app_store_build_writes_export_options
    write('ios/Runner.xcodeproj/project.pbxproj', 'fixture project')
    stub_signing
    @fastfile.define_singleton_method(:ensure_ios_toolchain!) { true }
    calls = []
    @fastfile.define_singleton_method(:flutter) { |*args| calls << args }
    export_path = File.join(@root, 'build/ios/fastlane/ExportOptions.plist')

    assert_equal 'fixture.ipa', @fastfile.build_signed_ios_ipa({}, 'TEAM', 28)
    assert_equal ['build', 'ipa', '--release', "--export-options-plist=#{export_path}",
                  '--build-number=28'], calls.first
    export = Plist.parse_xml(export_path)
    assert_equal 'app-store-connect', export['method']
    assert_equal 'manual', export['signingStyle']
  end

  def test_release_notes_must_stay_inside_the_application_repository
    outside = File.join(Dir.tmpdir, 'outside-release-notes.txt')
    ENV['RELEASE_NOTES_FILE'] = outside
    error = assert_raises(FastlaneCore::Interface::FastlaneError) do
      @fastfile.release_notes(version: '1.1.0', build_number: 28)
    end
    assert_match(/inside the application repository/, error.message)
  end

  def test_artifact_identity_reports_unreadable_ipa
    @fastfile.define_singleton_method(:expected_app_identifier) { |_field| 'org.example.fixture' }
    @fastfile.define_singleton_method(:get_ipa_info_plist_value) do |**_options|
      raise Errno::ENOENT
    end

    error = assert_raises(FastlaneCore::Interface::FastlaneError) do
      @fastfile.verify_artifact_identity!('missing.ipa', platform: :ios)
    end
    assert_match(/Cannot read artifact identity/, error.message)
  end

  def test_ios_firebase_config_path_is_relative_to_the_project
    ENV['GOOGLESERVICE_INFO_PLIST_PATH'] = 'ios/Runner/GoogleService-Info.plist'

    assert_equal 'ios-fixture', @fastfile.firebase_app_id(:ios)
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

  def stub_signing
    @fastfile.define_singleton_method(:expected_app_identifier) { |_field| 'org.example.fixture' }
    @fastfile.define_singleton_method(:match) { |**_options| nil }
    @fastfile.define_singleton_method(:lane_context) do
      { Fastlane::Actions::SharedValues::MATCH_PROVISIONING_PROFILE_MAPPING =>
        { 'org.example.fixture' => 'Fixture Distribution' } }
    end
    @fastfile.define_singleton_method(:update_code_signing_settings) { |**_options| true }
    @fastfile.define_singleton_method(:build_artifact) { |*_args, **_options| 'fixture.ipa' }
    @fastfile.define_singleton_method(:is_ci) { false }
  end

  def write(path, content)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end

  def configure_git_identity
    system('git', '-C', @root, 'config', 'user.name', 'Fixture', exception: true)
    system('git', '-C', @root, 'config', 'user.email', 'fixture@example.test', exception: true)
    system('git', '-C', @root, 'config', 'commit.gpgsign', 'false', exception: true)
  end

  def git_stdout(*args)
    IO.popen(['git', '-C', @root, *args], &:read)
  end
end
