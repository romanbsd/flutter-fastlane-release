#!/usr/bin/env ruby
# Validate an explicitly selected IPA of this app. Upload only with --upload.
require 'fastlane'
require 'fastlane/actions/upload_to_testflight'
Fastlane.load_actions
require 'fastlane_core/ipa_file_analyser'
require 'dotenv'
require 'optparse'
require 'digest'
require_relative 'app_context'

begin
  options = {}
  OptionParser.new do |parser|
    parser.banner = 'Usage: bundle exec ruby vendor/flutter-fastlane-release/tools/upload_existing_ios.rb --ipa PATH --version VERSION --build NUMBER [--upload]'
    parser.on('--ipa PATH') { |value| options[:ipa] = value }
    parser.on('--version VERSION') { |value| options[:version] = value }
    parser.on('--build NUMBER') { |value| options[:build] = value }
    parser.on('--upload') { options[:upload] = true }
    parser.on('-h', '--help') { puts parser; exit }
  end.parse!
  abort 'Specify --ipa, --version and --build; no positional arguments.' unless
    ARGV.empty? && %i[ipa version build].all? { |key| !options[key].to_s.empty? }
  root = AppContext.root
  bundle_id = AppContext.bundle_id
  ipa = File.expand_path(options[:ipa], root)
  abort 'IPA must be an existing file.' unless File.file?(ipa)
  info = FastlaneCore::IpaFileAnalyser.fetch_info_plist_file(ipa)
  abort 'IPA differs from the requested app, iOS version or build.' unless info &&
    info['CFBundleIdentifier'] == bundle_id && info['DTPlatformName'] == 'iphoneos' &&
    info['CFBundleShortVersionString'] == options[:version] && info['CFBundleVersion'] == options[:build]
  puts "Verified #{bundle_id} #{options[:version]} (#{options[:build]}), SHA256 #{Digest::SHA256.file(ipa).hexdigest}"
  exit unless options[:upload]

  action = Fastlane::Actions::UploadToTestflightAction
  values = FastlaneCore::Configuration.create(action.available_options, {
    ipa: ipa, api_key_path: AppContext.api_key_path, app_identifier: bundle_id,
    app_version: options[:version], build_number: options[:build],
    skip_submission: true, skip_waiting_for_build_processing: true,
    distribute_external: false, notify_external_testers: false,
    uses_non_exempt_encryption: false
  })
  action.run(values)
  puts 'Upload finished. Verify processing with tools/app_store_status.rb before selecting the build.'
rescue OptionParser::ParseError, ArgumentError => error
  warn error.message
  exit 1
rescue StandardError => error
  warn "Missing Ruby constant: #{error.name}" if error.is_a?(NameError)
  warn "IPA validation/upload failed (#{error.class}); check the upload status before retrying."
  exit 1
end
