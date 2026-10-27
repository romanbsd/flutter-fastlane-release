#!/usr/bin/env ruby
# Change only the app's iOS release mode; default is a read-only plan.
require_relative 'app_store_screenshots'

begin
  options = { apply: false }
  OptionParser.new do |p|
    p.banner = 'Usage: bundle exec ruby vendor/flutter-fastlane-release/tools/app_store_release_mode.rb --version VERSION --build NUMBER --mode auto|manual [--apply]'
    p.on('--version VERSION') { |v| options[:version] = v }
    p.on('--build NUMBER') { |v| options[:build] = v }
    p.on('--mode MODE', %w[auto manual]) { |v| options[:mode] = v }
    p.on('--apply', 'Apply the inspected release-mode change') { options[:apply] = true }
    p.on('-h', '--help') { puts p; exit }
  end.parse!
  unless ARGV.empty? && options[:version]&.match?(/\A\d+(?:\.\d+)+\z/) &&
         options[:build]&.match?(/\A[1-9]\d*\z/) && options[:mode]
    raise AppStoreStatus::AuditError, 'Supply --version, --build and --mode with no extra arguments.'
  end
  api = AppStoreScreenshots.new(AppContext.api_key_path)
  apps = api.collection('/v1/apps', 'filter[bundleId]' => AppContext.bundle_id)['data']
  raise AppStoreStatus::AuditError, 'Expected exactly one app for the bundle ID.' unless apps.length == 1
  versions = api.collection("/v1/apps/#{apps.first.fetch('id')}/appStoreVersions")['data']
  matches = versions.select do |v|
    v.dig('attributes', 'platform') == 'IOS' && v.dig('attributes', 'versionString') == options[:version]
  end
  raise AppStoreStatus::AuditError, 'Expected exactly one matching iOS version.' unless matches.length == 1
  version = matches.first
  attrs = version.fetch('attributes')
  unless %w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW WAITING_FOR_REVIEW IN_REVIEW].include?(attrs['appStoreState'])
    raise AppStoreStatus::AuditError, 'Release-mode changes require an unreleased version before approval.'
  end
  unless attrs['earliestReleaseDate'].nil?
    raise AppStoreStatus::AuditError, 'A release date is already scheduled; inspect it before changing the release mode.'
  end
  build = api.get("/v1/appStoreVersions/#{version.fetch('id')}/build")['data']
  unless build && build.dig('attributes', 'version') == options[:build] &&
         build.dig('attributes', 'processingState') == 'VALID' && !build.dig('attributes', 'expired')
    raise AppStoreStatus::AuditError, 'The selected build is missing, invalid, expired or differs from --build.'
  end
  desired = { 'auto' => 'AFTER_APPROVAL', 'manual' => 'MANUAL' }.fetch(options[:mode])
  puts "#{AppContext.bundle_id} #{options[:version]} (#{options[:build]}): #{attrs['releaseType']} -> #{desired}; #{attrs['appStoreState']}."
  if options[:apply] && attrs['releaseType'] != desired
    api.write(:patch, "/v1/appStoreVersions/#{version.fetch('id')}", {
      type: 'appStoreVersions', id: version.fetch('id'), attributes: { releaseType: desired }
    })
    saved = api.get("/v1/appStoreVersions/#{version.fetch('id')}").fetch('data').fetch('attributes')
    raise AppStoreStatus::AuditError, 'Release mode did not match after the update.' unless saved['releaseType'] == desired
    puts "Verified releaseType=#{saved['releaseType']}; state=#{saved['appStoreState']}."
  elsif options[:apply]
    puts 'Release mode already matches; no change made.'
  else
    puts 'Read-only plan; pass --apply to change only releaseType. The review submission is retained.'
  end
rescue AppStoreStatus::AuditError, OptionParser::ParseError, ArgumentError => error
  warn error.message
  exit 1
rescue StandardError => error
  warn "Release-mode operation stopped (#{error.class}); inspect live status before retrying."
  exit 1
end
