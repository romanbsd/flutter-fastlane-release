# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'json'
require 'plist'
require 'tmpdir'
require_relative 'lib/pubspec_version'
require_relative 'lib/codex_runner'
require_relative 'lib/release_notes'
require_relative 'lib/ios_signing'
require_relative 'lib/release_workflow'
require_relative 'actions/bump_pubspec_build'

extend ReleaseNotes
extend IosSigning
extend ReleaseWorkflow

# Generic Flutter release lanes. The importing app owns Appfile, release notes,
# signing configuration, credentials and store metadata.
default_platform(:android)

def project_root
  fastlane_dir = FastlaneCore::FastlaneFolder.path
  UI.user_error!('Import this Fastfile from an application fastlane/Fastfile.') if fastlane_dir.to_s.empty?
  File.expand_path('..', fastlane_dir)
end

def flutter(*)
  Dir.chdir(project_root) { sh('flutter', *) }
end

def env_boolean(name, default: false)
  value = ENV[name].to_s.strip.downcase
  return default if value.empty?
  return true if %w[1 true yes on].include?(value)
  return false if %w[0 false no off].include?(value)

  UI.user_error!("#{name} must be true or false.")
end

def env_list(name)
  ENV[name].to_s.split(',').map(&:strip).reject(&:empty?)
end

def build_artifact(pattern, since:)
  matches = Dir[File.join(project_root, pattern)]
  UI.user_error!("Expected exactly one build artifact for #{pattern}; found #{matches.length}.") unless matches.length == 1
  path = matches.first
  UI.user_error!("Build did not produce a fresh artifact: #{path}") if File.mtime(path) < since
  path
end

def existing_artifact(path, extension)
  UI.user_error!("Provide an existing #{extension} using the lane artifact parameter.") if path.to_s.strip.empty?
  path = File.expand_path(path, project_root)
  UI.user_error!("Artifact not found or not #{extension}: #{path}") unless File.file?(path) && File.extname(path) == extension
  path
end

def verify_existing_artifact!(path, platform:, version:, build_number:, notes:, expected_sha: nil)
  actual = Digest::SHA256.file(path).hexdigest
  receipt_path = File.join(project_root, 'build', 'release', 'status.json')
  receipt = JSON.parse(File.read(receipt_path)) if File.file?(receipt_path)
  recorded = receipt&.dig('platforms', platform.to_s)
  matching_receipt = recorded && receipt['version'] == version &&
                     recorded['build_number'].to_i == build_number.to_i &&
                     recorded['sha256'] == actual &&
                     recorded['notes_sha256'] == Digest::SHA256.hexdigest(notes)
  if expected_sha.to_s.empty?
    UI.user_error!('No matching local build receipt. Supply sha256: for an externally built artifact.') unless matching_receipt
  elsif expected_sha != actual
    UI.user_error!("Artifact SHA-256 #{actual} differs from the expected #{expected_sha}.")
  end
  UI.message("Verified #{platform} #{version}+#{build_number}, SHA-256 #{actual}.")
rescue JSON::ParserError => error
  UI.user_error!("Invalid release status JSON: #{error.message}")
end

def app_store_connect_api_key_options(required: false)
  path = ENV['APP_STORE_CONNECT_API_KEY_PATH'].to_s.strip
  UI.user_error!('APP_STORE_CONNECT_API_KEY_PATH is required for CI or TestFlight redistribution.') if (required || is_ci) && path.empty?
  return {} if path.empty?

  expanded_path = File.expand_path(path)
  UI.user_error!("App Store Connect API key not found at #{expanded_path}") unless File.file?(expanded_path)
  { api_key_path: expanded_path }
end

def required_env(name)
  value = ENV[name].to_s.strip
  UI.user_error!("#{name} is required.") if value.empty?
  value
end

def positive_integer(name, value = ENV[name], required: false)
  value = value.to_s.strip
  return nil if value.empty? && !required

  UI.user_error!("#{name} must be a positive integer.") unless value.match?(/\A\d+\z/) && value.to_i.positive?
  value.to_i
end

def app_store_version(value)
  UI.user_error!('App Store version must be major.minor.patch.') unless value.match?(/\A\d+\.\d+\.\d+\z/)
  value
end

def flutter_build_args(build_number)
  ["--build-number=#{build_number}"]
end

def ios_build_args(build_number:)
  args = flutter_build_args(build_number)
  app_store_id = positive_integer('APP_STORE_ID')
  args << "--dart-define=APP_STORE_ID=#{app_store_id}" if app_store_id
  args
end

def aab_manifest_value(path, attribute)
  jar = ENV['BUNDLETOOL_JAR'].to_s.strip
  command = if jar.empty?
              ['bundletool']
            else
              jar = File.expand_path(jar, project_root)
              UI.user_error!("BUNDLETOOL_JAR not found: #{jar}") unless File.file?(jar)
              ['java', '-jar', jar]
            end
  xpath = attribute == 'package' ? '/manifest/@package' : "/manifest/@android:#{attribute}"
  sh(*command, 'dump', 'manifest', "--bundle=#{path}", '--module=base',
     "--xpath=#{xpath}", log: false).strip
end

def artifact_version(path, platform)
  value = platform == :ios ?
    get_ipa_info_plist_value(ipa: path, key: 'CFBundleShortVersionString').to_s.strip :
    aab_manifest_value(path, 'versionName')
  UI.user_error!('Artifact has no valid version name.') unless value.match?(/\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/)
  value
rescue FastlaneCore::Interface::FastlaneShellError, Errno::ENOENT
  UI.user_error!('Cannot read IPA metadata; inspect its Info.plist before retrying.') if platform == :ios
  UI.user_error!('Cannot read AAB version. Install bundletool (and Java), or set BUNDLETOOL_JAR to its JAR; inspect the artifact before retrying.')
end

def artifact_build_number(path, platform)
  value = platform == :ios ?
    get_ipa_info_plist_value(ipa: path, key: 'CFBundleVersion').to_s.strip :
    aab_manifest_value(path, 'versionCode')
  positive_integer('artifact build number', value, required: true)
rescue FastlaneCore::Interface::FastlaneShellError, Errno::ENOENT
  UI.user_error!('Cannot read artifact build number; inspect the IPA or AAB before retrying.')
end

def verify_artifact_identity!(path, platform:)
  field = platform == :ios ? :app_identifier : :package_name
  expected = expected_app_identifier(field)
  UI.user_error!("Appfile #{field} is required for artifact uploads.") if expected.empty?
  actual = if platform == :ios
             device = get_ipa_info_plist_value(ipa: path, key: 'DTPlatformName').to_s.strip
             UI.user_error!('IPA is not an iPhoneOS device build.') unless device == 'iphoneos'
             get_ipa_info_plist_value(ipa: path, key: 'CFBundleIdentifier').to_s.strip
           else
             aab_manifest_value(path, 'package')
           end
  UI.user_error!("Artifact app ID #{actual.inspect} does not match Appfile #{expected.inspect}.") unless actual == expected
end

def expected_app_identifier(field)
  CredentialsManager::AppfileConfig.try_fetch_value(field).to_s.strip
end

def artifact_encryption(ipa)
  declaration = get_ipa_info_plist_value(ipa: ipa, key: 'ITSAppUsesNonExemptEncryption')
  return declaration if [true, false].include?(declaration)

  declaration = env_boolean('USES_NON_EXEMPT_ENCRYPTION', default: nil)
  UI.user_error!('This IPA has no encryption declaration. Set USES_NON_EXEMPT_ENCRYPTION explicitly for this artifact before uploading.') if declaration.nil?
  declaration
end

def pubspec_version
  PubspecVersion.read(File.join(project_root, 'pubspec.yaml'))
rescue ArgumentError => e
  UI.user_error!(e.message)
end

def prepare_release(plan)
  flutter('clean') if plan[:clean]
  flutter('pub', 'get')
end

def ensure_clean_worktree
  ensure_git_status_clean(show_uncommitted_changes: true) unless env_boolean('ALLOW_DIRTY')
end

def ensure_android_release_signing!
  key_properties_path = File.join(project_root, 'android', 'key.properties')
  properties = {}
  if File.file?(key_properties_path)
    File.foreach(key_properties_path) do |line|
      key, value = line.strip.split(/\s*[=:]\s*/, 2)
      properties[key] = value if value
    end
  end
  fields = {
    'ANDROID_KEYSTORE_PATH' => 'storeFile',
    'ANDROID_KEYSTORE_PASSWORD' => 'storePassword',
    'ANDROID_KEY_ALIAS' => 'keyAlias',
    'ANDROID_KEY_PASSWORD' => 'keyPassword'
  }
  missing = fields.filter_map do |environment, property|
    environment if (ENV[environment].to_s.strip.empty? && properties[property].to_s.strip.empty?)
  end
  UI.user_error!("Android release signing is incomplete: set #{missing.join(', ')} or the corresponding android/key.properties values.") unless missing.empty?
end

def ensure_ios_toolchain!
  xcode = sh('xcodebuild', '-version', log: false)[/^Xcode\s+(\d+)/, 1].to_i
  sdk = sh('xcrun', '--sdk', 'iphoneos', '--show-sdk-version', log: false).strip.split('.').first.to_i
  UI.user_error!('App Store uploads require Xcode 26 or later with an iOS 26 or later SDK.') if xcode < 26 || sdk < 26
rescue FastlaneCore::Interface::FastlaneShellError, Errno::ENOENT
  UI.user_error!('Cannot verify the selected Xcode/iOS SDK; select Xcode 26 or later before building for App Store Connect.')
end

def play_store_options
  status = ENV.fetch('PLAY_STORE_RELEASE_STATUS', 'completed').strip
  allowed_statuses = %w[completed draft halted inProgress]
  unless allowed_statuses.include?(status)
    UI.user_error!("PLAY_STORE_RELEASE_STATUS must be one of #{allowed_statuses.join(', ')}.")
  end

  options = {
    track: ENV.fetch('PLAY_STORE_BETA_TRACK', 'internal').strip,
    release_status: status,
    validate_only: env_boolean('PLAY_STORE_VALIDATE_ONLY')
  }

  UI.user_error!('PLAY_STORE_BETA_TRACK must not be empty.') if options[:track].empty?
  UI.user_error!('Beta lanes accept only internal, alpha, or beta tracks.') unless %w[internal alpha beta].include?(options[:track])
  rollout = ENV['PLAY_STORE_ROLLOUT'].to_s.strip
  unless rollout.empty?
    rollout_value = Float(rollout)
    unless rollout_value.positive? && rollout_value <= 1
      UI.user_error!('PLAY_STORE_ROLLOUT must be greater than 0 and no greater than 1.')
    end
    options[:rollout] = rollout_value
  end

  options
rescue ArgumentError
  UI.user_error!('PLAY_STORE_ROLLOUT must be a number greater than 0 and no greater than 1.')
end

def testflight_options(include_compliance: true, require_api_key: false)
  api_key_options = app_store_connect_api_key_options(required: require_api_key)
  groups = env_list('TESTFLIGHT_GROUPS')
  external = env_boolean('TESTFLIGHT_DISTRIBUTE_EXTERNAL')
  UI.user_error!('TESTFLIGHT_GROUPS is required when TESTFLIGHT_DISTRIBUTE_EXTERNAL is true.') if external && groups.empty?
  description = ENV['TESTFLIGHT_BETA_APP_DESCRIPTION'].to_s.strip
  feedback_email = ENV['TESTFLIGHT_BETA_APP_FEEDBACK_EMAIL'].to_s.strip
  if external && (description.empty? || feedback_email.empty?)
    UI.user_error!('External TestFlight testing requires TESTFLIGHT_BETA_APP_DESCRIPTION and TESTFLIGHT_BETA_APP_FEEDBACK_EMAIL.')
  end
  options = {
    skip_waiting_for_build_processing: false,
    distribute_external: external, submit_beta_review: external,
    **api_key_options
  }
  options[:uses_non_exempt_encryption] = ios_encryption_declaration if include_compliance
  options[:groups] = groups unless groups.empty?
  options[:beta_app_description] = description unless description.empty?
  options[:beta_app_feedback_email] = feedback_email unless feedback_email.empty?
  notify = env_boolean('TESTFLIGHT_NOTIFY_EXTERNAL_TESTERS')
  options[:notify_external_testers] = notify if external
  options
end

def release_plan(platforms, for_upload: true)
  current = pubspec_version
  plan = current.merge(
    build_numbers: {},
    clean: env_boolean('FLUTTER_CLEAN'),
    platforms: platforms
  )
  plan[:commit] = Dir.chdir(project_root) { sh('git', 'rev-parse', 'HEAD', log: false).strip }
  platforms.each do |platform|
    name = "#{platform.to_s.upcase}_BUILD_NUMBER"
    selected = positive_integer(name, required: true)
    UI.user_error!("#{name} must not be below the pubspec build number.") if selected < current[:build_number]
    UI.user_error!('Google Play version codes must be below 2,100,000,001.') if platform == :android && selected > 2_100_000_000
    plan[:build_numbers][platform] = selected
  end
  if platforms.include?(:android)
    plan[:android] = play_store_options
    if plan[:android][:validate_only]
      UI.user_error!('PLAY_STORE_VALIDATE_ONLY cannot be combined with iOS deployment; use android beta.') if platforms.include?(:ios)
    end
  end
  ensure_clean_worktree
  if for_upload
    plan[:android_notes] = release_notes(version: plan[:version], build_number: plan[:build_numbers][:android]) if platforms.include?(:android)
    plan[:ios_notes] = release_notes(version: plan[:version], build_number: plan[:build_numbers][:ios]) if platforms.include?(:ios)
  end
  if platforms.include?(:android)
    if for_upload
      tracks = (%w[internal alpha beta production] + [plan[:android][:track]]).uniq
      latest = tracks.flat_map { |track| google_play_track_version_codes(track: track) }.max || 0
      UI.user_error!('ANDROID_BUILD_NUMBER must exceed the version codes already on Play tracks.') if plan[:build_numbers][:android] <= latest
    end
    ensure_android_release_signing! if for_upload || !plan[:android][:validate_only]
  end
  if platforms.include?(:ios)
    ensure_ios_toolchain!
    app_store_version(plan[:version])
    plan[:ios] = for_upload ? testflight_options : app_store_connect_api_key_options
    plan[:team_id] = required_env('APPLE_TEAM_ID')
    positive_integer('APP_STORE_ID')
    if for_upload
      latest = latest_testflight_build_number(version: plan[:version], initial_build_number: 0,
                                              **plan[:ios].slice(:api_key_path))
      UI.user_error!('IOS_BUILD_NUMBER must exceed the latest uploaded iOS build.') if plan[:build_numbers][:ios] <= latest
    end
  end
  if for_upload
    plan[:ios][:changelog] = plan[:ios_notes] if platforms.include?(:ios)
  end
  plan
end

def build_android_aab(build_number)
  started_at = Time.now
  flutter('build', 'appbundle', '--release', *flutter_build_args(build_number))
  build_artifact('build/app/outputs/bundle/release/*.aab', since: started_at)
end

def upload_android_aab(aab, options, notes)
  # Supply applies default.txt to the version code extracted from the AAB.
  Dir.mktmpdir('play-release-notes-') do |metadata_path|
    changelogs = File.join(metadata_path, 'en-US', 'changelogs')
    FileUtils.mkdir_p(changelogs)
    File.write(File.join(changelogs, 'default.txt'), notes)
    upload_to_play_store(
      aab: aab, metadata_path: metadata_path,
      skip_upload_metadata: true, skip_upload_changelogs: false,
      skip_upload_images: true, skip_upload_screenshots: true, **options
    )
  end
  UI.success(options[:validate_only] ? 'Android Play edit validated; no release published.' : 'Android bundle uploaded; verify track/review availability in Play Console.')
end

def existing_testflight_encryption(version, build_number, api_options)
  require 'spaceship'
  path = api_options[:api_key_path]
  UI.user_error!('APP_STORE_CONNECT_API_KEY_PATH is required for TestFlight redistribution.') if path.to_s.empty?
  previous_client = Spaceship::ConnectAPI.client
  previous_token = Spaceship::ConnectAPI.token
  begin
    Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.from_json_file(path)
    identifier = CredentialsManager::AppfileConfig.try_fetch_value(:app_identifier)
    app = Spaceship::ConnectAPI::App.find(identifier)
    UI.user_error!("App Store Connect app not found: #{identifier}") unless app
    build = Spaceship::ConnectAPI::Build.all(app_id: app.id, version: version,
                                            build_number: build_number.to_s, platform: 'IOS').first
    UI.user_error!('Selected TestFlight build not found.') unless build
    declaration = build.uses_non_exempt_encryption
    UI.user_error!('Complete export compliance for the selected build in App Store Connect before redistributing.') unless [true, false].include?(declaration)
    declaration
  ensure
    Spaceship::ConnectAPI.token = previous_token
    Spaceship::ConnectAPI.client = previous_client
  end
end

def firebase_distribution_enabled!
  UI.user_error!('Firebase App Distribution is not enabled for this app.') unless env_boolean('ENABLE_FIREBASE_DISTRIBUTION')
end

def firebase_app_id(platform)
  if platform == :ios
    path = ENV['GOOGLESERVICE_INFO_PLIST_PATH'].to_s.strip
    path = File.join(project_root, 'ios/Runner/GoogleService-Info.plist') if path.empty?
    value = Plist.parse_xml(path)&.fetch('GOOGLE_APP_ID', nil)
  else
    path = File.join(project_root, 'android/app/google-services.json')
    value = JSON.parse(File.read(path)).dig('client', 0, 'client_info', 'mobilesdk_app_id')
  end
  UI.user_error!("Missing #{platform} Firebase app ID in #{path}.") if value.to_s.empty?
  value
rescue Errno::ENOENT, JSON::ParserError
  UI.user_error!("Cannot read #{platform} Firebase configuration: #{path}.")
end

platform :ios do
  desc 'Build an App Store-signed IPA and upload it to TestFlight'
  lane :beta do
    run_beta_release([:ios])
  end

  desc 'Build a signed IPA without uploading or changing pubspec'
  lane :build do
    plan = release_plan([:ios], for_upload: false)
    prepare_release(plan)
    build_signed_ios_ipa(plan[:ios].slice(:api_key_path), plan[:team_id], plan[:build_numbers][:ios])
  end

  desc 'Upload an existing IPA to TestFlight without rebuilding or bumping'
  lane :upload do |options|
    ipa = existing_artifact(options[:ipa], '.ipa')
    verify_artifact_identity!(ipa, platform: :ios)
    version = artifact_version(ipa, :ios)
    build_number = artifact_build_number(ipa, :ios)
    notes = release_notes(version: version, build_number: build_number)
    verify_existing_artifact!(ipa, platform: :ios, version: version, build_number: build_number,
                              notes: notes, expected_sha: options[:sha256])
    encryption = artifact_encryption(ipa)
    upload = testflight_options(include_compliance: false)
    upload[:changelog] = notes
    upload[:uses_non_exempt_encryption] = encryption
    upload_to_testflight(ipa: ipa, **upload)
  end

  desc 'Distribute an existing TestFlight version/build without uploading'
  lane :distribute do |options|
    version = app_store_version(options[:version].to_s.empty? ? required_env('TESTFLIGHT_VERSION') : options[:version].to_s)
    build_number = positive_integer('TESTFLIGHT_BUILD_NUMBER', options[:build_number] || ENV['TESTFLIGHT_BUILD_NUMBER'], required: true)
    distribution = testflight_options(include_compliance: false, require_api_key: true)
    distribution[:uses_non_exempt_encryption] = existing_testflight_encryption(version, build_number, distribution.slice(:api_key_path))
    upload_to_testflight(distribute_only: true, app_version: version, build_number: build_number.to_s, **distribution)
  end

  desc 'Submit a tested TestFlight build for App Review with manual release after approval'
  lane :release do
    if ENV['IOS_RELEASE_MODE'] == 'testflight_alias'
      run_beta_release([:ios])
      next
    end
    UI.user_error!('App Store submission is disabled for this app.') unless ENV['IOS_RELEASE_MODE'] == 'app_store_submission'
    version = app_store_version(required_env('APP_STORE_VERSION'))
    build_number = positive_integer('APP_STORE_BUILD_NUMBER', required: true).to_s
    api_key_options = app_store_connect_api_key_options
    notes = release_notes(version: version, build_number: build_number)
    # deliver applies release_type during its metadata phase. Include only the
    # Codex-authored release notes and preserve other console-managed text.
    Dir.mktmpdir('flutter-app-store-') do |metadata_path|
      locale_path = File.join(metadata_path, 'en-US')
      FileUtils.mkdir_p(locale_path)
      File.write(File.join(locale_path, 'release_notes.txt'), notes)
      upload_to_app_store(
        app_version: version, build_number: build_number,
        skip_binary_upload: true, skip_metadata: false, skip_screenshots: true,
        metadata_path: metadata_path, force: true,
        submit_for_review: true,
        automatic_release: false,
        precheck_include_in_app_purchases: false,
        **api_key_options
      )
    end
    UI.success('Build submitted for App Review. Release manually in App Store Connect after approval.')
  end

  desc 'Build an Ad Hoc IPA and distribute it through Firebase when enabled'
  lane :firebase_beta do
    firebase_distribution_enabled!
    plan = release_plan([:ios], for_upload: false)
    notes = release_notes(version: plan[:version], build_number: plan[:build_numbers][:ios])
    prepare_release(plan)
    match(type: 'adhoc', readonly: true, **plan[:ios].slice(:api_key_path))
    started_at = Time.now
    flutter('build', 'ipa', '--release', *ios_build_args(build_number: plan[:build_numbers][:ios]))
    ipa = build_artifact('build/ios/ipa/*.ipa', since: started_at)
    firebase_app_distribution(app: firebase_app_id(:ios), ipa_path: ipa,
                              groups: ENV.fetch('FIREBASE_IOS_GROUPS', 'beta-testers'),
                              release_notes: notes)
  end
end

platform :android do
  desc 'Build an Android App Bundle and upload it to a Google Play testing track'
  lane :beta do
    run_beta_release([:android])
  end

  desc 'Compatibility alias for the configured Google Play beta track'
  lane :release do
    UI.user_error!('Android release alias is disabled for this app.') unless ENV['ANDROID_RELEASE_MODE'] == 'beta_alias'
    run_beta_release([:android])
  end

  desc 'Build an Android App Bundle without uploading or changing pubspec'
  lane :build do
    plan = release_plan([:android], for_upload: false)
    prepare_release(plan)
    build_android_aab(plan[:build_numbers][:android])
  end

  desc 'Upload or validate an existing AAB without rebuilding or bumping'
  lane :upload do |options|
    aab = existing_artifact(options[:aab], '.aab')
    verify_artifact_identity!(aab, platform: :android)
    play_options = play_store_options
    version = artifact_version(aab, :android)
    build_number = artifact_build_number(aab, :android)
    notes = release_notes(version: version, build_number: build_number)
    verify_existing_artifact!(aab, platform: :android, version: version, build_number: build_number,
                              notes: notes, expected_sha: options[:sha256])
    upload_android_aab(aab, play_options, notes)
  end

  desc 'Upload Play Store metadata and optional images without an app build'
  lane :store_listing do
    metadata_path = File.join(project_root, 'fastlane', 'metadata', 'android')
    UI.user_error!("Play Store metadata not found at #{metadata_path}") unless Dir.exist?(metadata_path)

    upload_to_play_store(
      metadata_path: metadata_path,
      track: ENV.fetch('PLAY_STORE_LISTING_TRACK', 'production'),
      skip_upload_apk: true,
      skip_upload_aab: true,
      skip_upload_changelogs: false,
      skip_upload_metadata: false,
      skip_upload_images: !env_boolean('PLAY_STORE_UPLOAD_IMAGES'),
      skip_upload_screenshots: !env_boolean('PLAY_STORE_UPLOAD_SCREENSHOTS'),
      sync_image_upload: true,
      validate_only: env_boolean('PLAY_STORE_VALIDATE_ONLY')
    )
  end

  desc 'Build a signed APK and distribute it through Firebase when enabled'
  lane :firebase_beta do
    firebase_distribution_enabled!
    plan = release_plan([:android], for_upload: false)
    notes = release_notes(version: plan[:version], build_number: plan[:build_numbers][:android])
    prepare_release(plan)
    started_at = Time.now
    flutter('build', 'apk', '--release', *flutter_build_args(plan[:build_numbers][:android]))
    apk = build_artifact('build/app/outputs/flutter-apk/app-release.apk', since: started_at)
    firebase_app_distribution(app: firebase_app_id(:android), apk_path: apk,
                              groups: ENV.fetch('FIREBASE_ANDROID_GROUPS', 'beta-testers'),
                              release_notes: notes)
  end
end

desc 'Run Flutter static analysis and tests'
lane :test do
  flutter('analyze')
  flutter('test')
end

desc 'Check release numbers, notes, signing, source state and live store versions'
lane :beta_preflight do
  plan = release_plan(%i[ios android])
  UI.success("Ready for iOS #{plan[:version]}+#{plan[:build_numbers][:ios]} and Android #{plan[:version]}+#{plan[:build_numbers][:android]}.")
end

desc 'Draft user-facing notes for an app-owned build; review and commit before release'
lane :draft_release_notes do |options|
  version = pubspec_version[:version]
  build = positive_integer('NOTES_BUILD_NUMBER', options[:build_number] || ENV['NOTES_BUILD_NUMBER'], required: true)
  path = release_notes_path(version: version, build_number: build)
  UI.user_error!("Release notes already exist: #{path}") if File.exist?(path)
  generate_release_notes(path, ReleaseNotes::MAX_LENGTH)
  UI.success("Review and commit #{path} before release.")
end

desc 'Explicitly raise the pubspec build number; review and commit the result'
lane :bump_build_version do |options|
  ensure_clean_worktree
  bump_pubspec_build(pubspec_path: File.join(project_root, 'pubspec.yaml'),
                     build_number: options[:build_number])
end

desc 'Validate once, then deploy betas to TestFlight and Google Play'
lane :beta_all do
  run_beta_release(%i[ios android], run_checks: true)
end

error do |lane, exception|
  UI.error("Error in lane #{lane}: #{exception.message}")
end
