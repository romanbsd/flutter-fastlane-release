# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'plist'
require 'rexml/document'
require 'tmpdir'
require_relative 'lib/pubspec_version'
require_relative 'lib/codex_runner'
require_relative 'lib/release_git'
require_relative 'lib/release_numbers'
require_relative 'lib/release_notes'
require_relative 'lib/ios_signing'
require_relative 'lib/release_tags'
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
  recorded = recorded_artifact_receipt(platform, version, build_number)
  matching_receipt = recorded && recorded['version'] == version &&
                     recorded['build_number'].to_i == build_number.to_i &&
                     recorded['sha256'] == actual &&
                     recorded['notes_sha256'] == Digest::SHA256.hexdigest(notes)
  if expected_sha.to_s.empty?
    UI.user_error!('No matching local build receipt. Supply sha256: for an externally built artifact.') unless matching_receipt
  elsif expected_sha != actual
    UI.user_error!("Artifact SHA-256 #{actual} differs from the expected #{expected_sha}.")
  end
  UI.message("Verified #{platform} #{version}+#{build_number}, SHA-256 #{actual}.")
end

# Receipts outlive a single run, so an artifact built by an earlier attempt can
# still be uploaded. Older runs wrote their receipts into status.json.
def recorded_artifact_receipt(platform, version, build_number)
  entry = release_receipts[platform.to_s]
  if entry.is_a?(Hash)
    return entry if entry['sha256'] # legacy flat receipt

    receipt = entry["#{version}+#{build_number}"]
    return receipt if receipt
  end

  path = release_status_path
  return nil unless File.file?(path)

  status = JSON.parse(File.read(path))
  return nil unless status.is_a?(Hash)

  recorded = status.dig('platforms', platform.to_s)
  recorded&.merge('version' => status['version'])
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

def bundletool_command
  jar = ENV['BUNDLETOOL_JAR'].to_s.strip
  return ['bundletool'] if jar.empty?

  jar = File.expand_path(jar, project_root)
  UI.user_error!("BUNDLETOOL_JAR not found: #{jar}") unless File.file?(jar)
  ['java', '-jar', jar]
end

def aab_manifest(path)
  sh(*bundletool_command, 'dump', 'manifest', "--bundle=#{path}", '--module=base', log: false)
end

# Reads every upload-relevant field in one pass: one IPA unzip or one bundletool
# invocation instead of one per field.
def artifact_metadata(path, platform)
  platform == :ios ? ipa_metadata(path) : aab_metadata(path)
end

def ipa_metadata(path)
  plist = begin
    FastlaneCore::IpaFileAnalyser.fetch_info_plist_file(path)
  rescue StandardError => error
    UI.user_error!("Cannot read IPA metadata; inspect its Info.plist before retrying (#{error.message}).")
  end
  UI.user_error!('Cannot read IPA metadata; inspect its Info.plist before retrying.') unless plist.is_a?(Hash)
  validate_artifact_metadata!(
    version: plist['CFBundleShortVersionString'].to_s.strip,
    build_number: plist['CFBundleVersion'].to_s.strip,
    identifier: plist['CFBundleIdentifier'].to_s.strip,
    device: plist['DTPlatformName'].to_s.strip,
    encryption: plist['ITSAppUsesNonExemptEncryption']
  )
end

def aab_metadata(path)
  xml = begin
    aab_manifest(path)
  rescue FastlaneCore::Interface::FastlaneShellError, Errno::ENOENT
    UI.user_error!('Cannot read AAB metadata. Install bundletool (and Java), or set BUNDLETOOL_JAR to its JAR; inspect the artifact before retrying.')
  end
  manifest = begin
    start = xml.index('<manifest')
    raise REXML::ParseException, 'no manifest element' unless start

    REXML::Document.new(xml[start..]).root
  rescue REXML::ParseException
    UI.user_error!('Cannot parse the AAB manifest; inspect the artifact before retrying.')
  end
  validate_artifact_metadata!(
    version: manifest.attributes['android:versionName'].to_s.strip,
    build_number: manifest.attributes['android:versionCode'].to_s.strip,
    identifier: manifest.attributes['package'].to_s.strip,
    device: nil
  )
end

def validate_artifact_metadata!(metadata)
  UI.user_error!('Artifact has no valid version name.') unless metadata[:version].match?(/\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/)
  unless metadata[:build_number].match?(/\A\d+\z/) && metadata[:build_number].to_i.positive?
    UI.user_error!('Artifact has no valid build number.')
  end
  UI.user_error!('Artifact has no app identifier.') if metadata[:identifier].empty?
  metadata.merge(build_number: metadata[:build_number].to_i)
end

def verify_artifact_identity!(metadata, platform:)
  field = platform == :ios ? :app_identifier : :package_name
  expected = expected_app_identifier(field)
  UI.user_error!("Appfile #{field} is required for artifact uploads.") if expected.empty?
  UI.user_error!('IPA is not an iPhoneOS device build.') if platform == :ios && metadata[:device] != 'iphoneos'
  return if metadata[:identifier] == expected

  UI.user_error!("Artifact app ID #{metadata[:identifier].inspect} does not match Appfile #{expected.inspect}.")
end

def expected_app_identifier(field)
  CredentialsManager::AppfileConfig.try_fetch_value(field).to_s.strip
end

def artifact_encryption(metadata)
  declaration = metadata[:encryption]
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
  # flutter clean removes build/, which holds receipts for artifacts still awaiting upload.
  receipts = plan[:clean] ? release_receipts : {}
  flutter('clean') if plan[:clean]
  write_json_atomically(release_receipts_path, receipts) unless receipts.empty?
  flutter('pub', 'get')
  # Dependency resolution can rewrite the lockfile; never build inputs that no
  # longer match the recorded commit.
  ensure_release_inputs_committed
  plan[:commit] = current_commit
end

def ensure_release_inputs_committed
  %w[pubspec.yaml pubspec.lock].each do |file|
    path = File.join(project_root, file)
    next unless File.file?(path)

    committed = ReleaseGit.head_bytes(project_root, file)
    next if committed == File.read(path)

    UI.user_error!("#{file} changed during release preparation; commit or revert it before building.")
  end
end

def current_commit
  ReleaseGit.current_commit(project_root)
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

# supply updates metadata on an existing release, so target an explicit version when
# configured and otherwise the track's latest release. Changelogs are only uploaded
# for an explicit version to avoid publishing stale notes.
def play_store_listing_options(metadata_path)
  track = ENV.fetch('PLAY_STORE_LISTING_TRACK', 'production')
  requested = positive_integer('PLAY_STORE_VERSION_CODE') ||
              positive_integer('SUPPLY_VERSION_CODE', ENV['SUPPLY_VERSION_CODE'])
  version_code = requested || google_play_track_version_codes(track: track).max
  options = {
    metadata_path: metadata_path,
    track: track,
    skip_upload_apk: true,
    skip_upload_aab: true,
    skip_upload_changelogs: requested.nil?,
    skip_upload_metadata: false,
    skip_upload_images: !env_boolean('PLAY_STORE_UPLOAD_IMAGES'),
    skip_upload_screenshots: !env_boolean('PLAY_STORE_UPLOAD_SCREENSHOTS'),
    sync_image_upload: true,
    validate_only: env_boolean('PLAY_STORE_VALIDATE_ONLY')
  }
  options[:version_code] = version_code if version_code
  options
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

def latest_play_version_code(track)
  tracks = (%w[internal alpha beta production] + [track]).uniq
  tracks.flat_map { |name| google_play_track_version_codes(track: name) }.max || 0
end

def explicit_build_numbers(platforms)
  platforms.to_h do |platform|
    [platform, positive_integer("#{platform.to_s.upcase}_BUILD_NUMBER")]
  end.compact
end

def latest_store_builds(platforms, version:)
  latest = {}
  if platforms.include?(:android)
    latest[:android] = latest_play_version_code(play_store_options[:track])
  end
  if platforms.include?(:ios)
    ios = testflight_options
    latest[:ios] = latest_testflight_build_number(
      version: version, initial_build_number: 0, **ios.slice(:api_key_path)
    )
  end
  latest
end

def release_version_for(current_version, bump)
  requested = bump.to_s.strip
  requested = ENV['VERSION_BUMP'].to_s.strip if requested.empty?
  return current_version if requested.empty?

  part = requested.downcase
  unless %w[major minor patch].include?(part)
    UI.user_error!("Version bump must be major, minor, or patch (got #{requested.inspect}).")
  end
  PubspecVersion.next_version(current_version, part)
rescue ArgumentError => error
  UI.user_error!(error.message)
end

def validate_explicit_numbers!(explicit, latest, current)
  explicit.each do |platform, number|
    name = "#{platform.to_s.upcase}_BUILD_NUMBER"
    ReleaseNumbers.validate_pubspec_floor!(name, number, current[:build_number])
    ReleaseNumbers.validate_play_version_code!(number) if platform == :android
    UI.user_error!("#{name} must exceed the build already on the store.") if number <= latest[platform].to_i
  end
end

# Assigns the next store build when a platform number is omitted, raises pubspec to the
# lowest build in this release, generates missing notes with Codex, and commits both.
# With prepare: false it only computes and validates the numbers (preflight).
def prepare_automatic_release(platforms, current, version:, prepare: true)
  explicit = explicit_build_numbers(platforms)
  missing = platforms - explicit.keys
  bumping = version != current[:version]
  if !missing.empty? && env_boolean('PLAY_STORE_VALIDATE_ONLY')
    names = missing.map { |platform| "#{platform.to_s.upcase}_BUILD_NUMBER" }
    UI.user_error!("#{names.join(' and ')} is required when PLAY_STORE_VALIDATE_ONLY is set.")
  end

  ensure_clean_worktree if prepare
  latest = latest_store_builds(platforms, version: version)
  # Validate every explicit number before anything is written or committed.
  validate_explicit_numbers!(explicit, latest, current)
  chosen = ReleaseNumbers.next_store_build(current[:build_number], latest.values.max || 0)
  ReleaseNumbers.validate_play_version_code!(chosen) if missing.include?(:android)
  numbers = explicit.merge(missing.to_h { |platform| [platform, chosen] })

  # Reusing a build requires committed notes. A version bump starts a new
  # changelog, so the notes for it are generated instead.
  unless bumping
    explicit.each_value do |build|
      release_notes(version: version, build_number: build)
    end
  end
  return numbers unless prepare
  return numbers if env_boolean('PLAY_STORE_VALIDATE_ONLY')

  notes_paths = numbers.values.uniq.map do |build|
    release_notes_path(version: version, build_number: build)
  end
  notes_paths.each do |path|
    next if File.file?(path)

    generate_release_notes(path, ReleaseNotes::MAX_LENGTH)
  end
  baseline = numbers.values.min
  pubspec_path = File.join(project_root, 'pubspec.yaml')
  changed = bumping || baseline > current[:build_number]
  if changed
    File.write(pubspec_path, PubspecVersion.rewrite(current[:content], version: version, build: baseline))
  end
  message = if bumping
              "Release #{version}+#{baseline}."
            elsif changed
              "Bump build to #{version}+#{baseline}."
            else
              "Add release notes for #{version}+#{numbers.values.max}."
            end
  commit_release_changes([pubspec_path, *notes_paths], message)
  numbers
end

def commit_release_changes(paths, message)
  root = File.realpath(project_root)
  relative = paths.map do |path|
    full = File.realpath(File.expand_path(path))
    UI.user_error!("Release file is outside the repository: #{path}") unless full.start_with?("#{root}#{File::SEPARATOR}")
    full.delete_prefix("#{root}#{File::SEPARATOR}")
  end
  ReleaseGit.commit_paths(root, relative, message)
rescue ReleaseGit::Error => error
  UI.user_error!(error.message)
end

def release_plan(platforms, for_upload: true, prepare: true, bump: nil)
  current = pubspec_version
  version = for_upload ? release_version_for(current[:version], bump) : current[:version]
  if version != current[:version] && env_boolean('PLAY_STORE_VALIDATE_ONLY')
    UI.user_error!('Version bumps cannot be combined with PLAY_STORE_VALIDATE_ONLY.')
  end
  automatic = for_upload ? prepare_automatic_release(platforms, current, version: version, prepare: prepare) : {}
  current = pubspec_version
  plan = current.merge(
    version: version,
    build_numbers: {},
    clean: env_boolean('FLUTTER_CLEAN'),
    platforms: platforms
  )
  plan[:commit] = current_commit
  platforms.each do |platform|
    name = "#{platform.to_s.upcase}_BUILD_NUMBER"
    selected = automatic[platform] || positive_integer(name, required: true)
    ReleaseNumbers.validate_pubspec_floor!(name, selected, current[:build_number])
    ReleaseNumbers.validate_play_version_code!(selected) if platform == :android
    plan[:build_numbers][platform] = selected
  end
  if platforms.include?(:android)
    plan[:android] = play_store_options
    if plan[:android][:validate_only]
      UI.user_error!('PLAY_STORE_VALIDATE_ONLY cannot be combined with iOS deployment; use android beta.') if platforms.include?(:ios)
    end
  end
  ensure_clean_worktree
  if platforms.include?(:android)
    ensure_android_release_signing! if for_upload || !plan[:android][:validate_only]
  end
  if platforms.include?(:ios)
    ensure_ios_toolchain! if for_upload
    app_store_version(plan[:version])
    plan[:ios] = for_upload ? testflight_options : app_store_connect_api_key_options
    plan[:team_id] = required_env('APPLE_TEAM_ID')
    positive_integer('APP_STORE_ID')
  end
  load_release_notes!(plan, platforms) if for_upload && prepare
  plan
end

# prepare_automatic_release already generated and committed the notes for an
# automatic release, and validated the notes of explicit builds.
def load_release_notes!(plan, platforms)
  platforms.each do |platform|
    notes = release_notes(version: plan[:version], build_number: plan[:build_numbers][platform])
    platform == :ios ? plan[:ios_notes] = notes : plan[:android_notes] = notes
  end
  plan[:ios][:changelog] = plan[:ios_notes] if plan[:ios] && plan[:ios_notes]
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
    identifier = expected_app_identifier(:app_identifier)
    FastlaneCore::UI.user_error!('Appfile app_identifier is required to redistribute a TestFlight build.') if identifier.empty?
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
    path = File.expand_path(path, project_root)
    value = begin
      parsed = Plist.parse_xml(path)
      parsed.is_a?(Hash) ? parsed['GOOGLE_APP_ID'] : nil
    rescue StandardError => error
      UI.user_error!("Cannot read iOS Firebase configuration #{path}: #{error.message}")
    end
  else
    path = File.join(project_root, 'android/app/google-services.json')
    value = begin
      JSON.parse(File.read(path)).dig('client', 0, 'client_info', 'mobilesdk_app_id')
    rescue StandardError => error
      UI.user_error!("Cannot read Android Firebase configuration #{path}: #{error.message}")
    end
  end
  UI.user_error!("Missing #{platform} Firebase app ID in #{path}.") if value.to_s.empty?
  value
end

def run_build_only(platform)
  plan = release_plan([platform], for_upload: false)
  prepare_release(plan)
  if platform == :ios
    build_signed_ios_ipa(plan[:ios].slice(:api_key_path), plan[:team_id], plan[:build_numbers][platform])
  else
    build_android_aab(plan[:build_numbers][platform])
  end
end

def run_firebase_release(platform)
  firebase_distribution_enabled!
  plan = release_plan([platform], for_upload: false)
  notes = release_notes(version: plan[:version], build_number: plan[:build_numbers][platform])
  prepare_release(plan)
  if platform == :ios
    ipa = build_signed_ios_adhoc_ipa(plan[:ios].slice(:api_key_path), plan[:team_id],
                                    plan[:build_numbers][platform])
    firebase_app_distribution(app: firebase_app_id(:ios), ipa_path: ipa,
                              groups: ENV.fetch('FIREBASE_IOS_GROUPS', 'beta-testers'),
                              release_notes: notes)
  else
    started_at = Time.now
    flutter('build', 'apk', '--release', *flutter_build_args(plan[:build_numbers][platform]))
    apk = build_artifact('build/app/outputs/flutter-apk/app-release.apk', since: started_at)
    firebase_app_distribution(app: firebase_app_id(:android), apk_path: apk,
                              groups: ENV.fetch('FIREBASE_ANDROID_GROUPS', 'beta-testers'),
                              release_notes: notes)
  end
end

def verify_existing_upload!(path, platform, expected_sha)
  metadata = artifact_metadata(path, platform)
  verify_artifact_identity!(metadata, platform: platform)
  notes = release_notes(version: metadata[:version], build_number: metadata[:build_number])
  verify_existing_artifact!(path, platform: platform, version: metadata[:version],
                            build_number: metadata[:build_number], notes: notes,
                            expected_sha: expected_sha)
  [metadata, notes]
end

def tag_release!(version)
  tag = ReleaseTags.create(project_root, version)
  if tag
    UI.success("Tagged release #{tag}. Push it with: git push origin #{tag}")
  else
    UI.message("No release tag for #{version}: not a new major.minor.patch version or already tagged.")
  end
rescue ReleaseGit::Error => error
  UI.user_error!("Could not tag release #{version}: #{error.message}")
end

platform :ios do
  desc 'Assign the next TestFlight build, optionally bump the version, commit pubspec and notes, then upload'
  lane :beta do |options|
    run_beta_release([:ios], bump: options[:bump])
  end

  desc 'Build a signed IPA without uploading or changing pubspec'
  lane :build do
    run_build_only(:ios)
  end

  desc 'Upload an existing IPA to TestFlight without rebuilding or bumping'
  lane :upload do |options|
    ipa = existing_artifact(options[:ipa], '.ipa')
    metadata, notes = verify_existing_upload!(ipa, :ios, options[:sha256])
    upload = testflight_options(include_compliance: false)
    upload[:changelog] = notes
    upload[:uses_non_exempt_encryption] = artifact_encryption(metadata)
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
  lane :release do |options|
    if ENV['IOS_RELEASE_MODE'] == 'testflight_alias'
      run_beta_release([:ios], bump: options[:bump])
      next
    end
    UI.user_error!('App Store submission is disabled for this app.') unless ENV['IOS_RELEASE_MODE'] == 'app_store_submission'
    version = app_store_version(required_env('APP_STORE_VERSION'))
    build_number = positive_integer('APP_STORE_BUILD_NUMBER', required: true).to_s
    api_key_options = app_store_connect_api_key_options
    notes = release_notes(version: version, build_number: build_number)
    locale = ENV.fetch('APP_STORE_NOTES_LOCALE', 'en-US').to_s.strip
    UI.user_error!('APP_STORE_NOTES_LOCALE must not be empty.') if locale.empty?
    # deliver applies release_type during its metadata phase. Include only the
    # Codex-authored release notes and preserve other console-managed text.
    Dir.mktmpdir('flutter-app-store-') do |metadata_path|
      locale_path = File.join(metadata_path, locale)
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
    run_firebase_release(:ios)
  end
end

platform :android do
  desc 'Assign the next Play build, optionally bump the version, commit pubspec and notes, then upload'
  lane :beta do |options|
    run_beta_release([:android], bump: options[:bump])
  end

  desc 'Compatibility alias for the configured Google Play beta track'
  lane :release do |options|
    UI.user_error!('Android release alias is disabled for this app.') unless ENV['ANDROID_RELEASE_MODE'] == 'beta_alias'
    run_beta_release([:android], bump: options[:bump])
  end

  desc 'Build an Android App Bundle without uploading or changing pubspec'
  lane :build do
    run_build_only(:android)
  end

  desc 'Upload or validate an existing AAB without rebuilding or bumping'
  lane :upload do |options|
    aab = existing_artifact(options[:aab], '.aab')
    _, notes = verify_existing_upload!(aab, :android, options[:sha256])
    upload_android_aab(aab, play_store_options, notes)
  end

  desc 'Upload Play Store metadata and optional images without an app build'
  lane :store_listing do
    metadata_path = File.join(project_root, 'fastlane', 'metadata', 'android')
    UI.user_error!("Play Store metadata not found at #{metadata_path}") unless Dir.exist?(metadata_path)

    upload_to_play_store(**play_store_listing_options(metadata_path))
  end

  desc 'Build a signed APK and distribute it through Firebase when enabled'
  lane :firebase_beta do
    run_firebase_release(:android)
  end
end

desc 'Run Flutter static analysis and tests'
lane :test do
  flutter('analyze')
  flutter('test')
end

desc 'Check release numbers, signing, source state and live store versions without writing; previews a version bump'
lane :beta_preflight do |options|
  plan = release_plan(%i[ios android], prepare: false, bump: options[:bump])
  UI.success("Ready for iOS #{plan[:version]}+#{plan[:build_numbers][:ios]} and Android #{plan[:version]}+#{plan[:build_numbers][:android]}. Run beta_all to build and upload them.")
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

desc 'Validate once, then deploy betas to TestFlight and Google Play, optionally bumping the version'
lane :beta_all do |options|
  run_beta_release(%i[ios android], run_checks: true, bump: options[:bump])
end

error do |lane, exception|
  UI.error("Error in lane #{lane}: #{exception.message}")
end
