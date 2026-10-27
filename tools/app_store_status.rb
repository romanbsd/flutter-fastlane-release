#!/usr/bin/env ruby
# Read-only App Store Connect audit. Never print keys or review credentials.
require 'json'
require 'jwt'
require 'openssl'
require 'net/http'
require 'uri'
require 'dotenv'
require 'optparse'
require 'time'
require_relative 'app_context'

class AppStoreStatus
  API = 'https://api.appstoreconnect.apple.com'.freeze
  class AuditError < StandardError; end

  def initialize(key_path)
    key = JSON.parse(File.read(key_path))
    raise AuditError, 'Use a Team App Store Connect API key with an issuer_id.' if key['issuer_id'].to_s.empty?

    now = Time.now.to_i
    @token = JWT.encode(
      { iss: key.fetch('issuer_id'), iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' },
      OpenSSL::PKey.read(key.fetch('key')), 'ES256', { kid: key.fetch('key_id'), typ: 'JWT' }
    )
  end

  def get(path, params = {}, allow_missing: false)
    uri = URI.join(API, path)
    # Never send the bearer token to another host through a pagination link.
    unless uri.scheme == 'https' && uri.host == URI(API).host && uri.port == 443
      raise AuditError, 'Unexpected App Store Connect pagination URL.'
    end
    uri.query = URI.encode_www_form(params) unless params.empty?
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{@token}"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 30) do |http|
      http.request(request)
    end
    return { 'data' => nil } if allow_missing && response.code == '404'
    # Provider bodies can contain account or review data.
    raise AuditError, "App Store Connect GET failed (HTTP #{response.code})." unless response.code == '200'

    JSON.parse(response.body)
  end

  def collection(path, params = {})
    result = { 'data' => [], 'included' => [] }
    seen = {}
    loop do
      page = get(path, params)
      result['data'].concat(page.fetch('data'))
      result['included'].concat(page.fetch('included', []))
      path = page.dig('links', 'next')
      break unless path
      raise AuditError, 'Repeated App Store Connect pagination link.' if seen[path]

      seen[path] = true
      params = {}
    end
    result['included'].uniq! { |item| [item['type'], item['id']] }
    result
  end

  def attributes(item, *names)
    (item || {}).fetch('attributes', {}).slice(*names)
  end

  def presence(item, *names)
    attrs = attributes(item, *names)
    names.to_h { |name| [name, !attrs[name].nil? && !attrs[name].to_s.strip.empty?] }
  end

  def report(bundle_id)
    app = collection('/v1/apps', 'filter[bundleId]' => bundle_id, 'limit' => 10)['data'].first
    raise AuditError, 'No App Store Connect app found for that bundle ID.' unless app

    id = app.fetch('id')
    versions = collection("/v1/apps/#{id}/appStoreVersions", 'limit' => 50,
                          'include' => 'appStoreVersionLocalizations,build')
    builds = collection('/v1/builds', 'filter[app]' => id, 'limit' => 50,
                        'include' => 'preReleaseVersion,buildBetaDetail', 'sort' => '-uploadedDate')
    infos = collection("/v1/apps/#{id}/appInfos", 'limit' => 50,
                       'include' => 'appInfoLocalizations,ageRatingDeclaration,primaryCategory')
    groups = collection("/v1/apps/#{id}/betaGroups", 'limit' => 50)
    lookup = (versions['included'] + builds['included'] + infos['included']).to_h do |item|
      [[item['type'], item['id']], item]
    end
    related = lambda do |item, name|
      rel = item.dig('relationships', name, 'data')
      rel && lookup[[rel['type'], rel['id']]]
    end

    {
      'checked_at' => Time.now.utc.iso8601,
      'app' => { 'id' => id }.merge(attributes(app, 'name', 'bundleId', 'primaryLocale', 'contentRightsDeclaration')),
      'builds' => builds['data'].map do |build|
        { 'id' => build['id'], 'build' => attributes(build, 'version', 'uploadedDate', 'processingState',
                                                    'expired', 'usesNonExemptEncryption', 'buildAudienceType'),
          'release' => attributes(related.call(build, 'preReleaseVersion'), 'version', 'platform'),
          'testflight' => attributes(related.call(build, 'buildBetaDetail'), 'internalBuildState', 'externalBuildState') }
      end,
      'store_versions' => versions['data'].map do |version|
        review = get("/v1/appStoreVersions/#{version['id']}/appStoreReviewDetail", {}, allow_missing: true)['data']
        locales = (version.dig('relationships', 'appStoreVersionLocalizations', 'data') || []).map do |ref|
          locale = lookup.fetch([ref['type'], ref['id']])
          sets = collection("/v1/appStoreVersionLocalizations/#{locale['id']}/appScreenshotSets", 'limit' => 200)
          { 'locale' => locale.dig('attributes', 'locale'),
            'fields_present' => presence(locale, 'description', 'promotionalText', 'keywords', 'supportUrl', 'marketingUrl', 'whatsNew'),
            'screenshots' => sets['data'].map do |set|
              screenshots = collection("/v1/appScreenshotSets/#{set['id']}/appScreenshots", 'limit' => 200)
              { 'display_type' => set.dig('attributes', 'screenshotDisplayType'), 'count' => screenshots['data'].length }
            end }
        end
        { 'id' => version['id'], 'version' => attributes(version, 'versionString', 'platform', 'appStoreState'),
          'copyright_present' => presence(version, 'copyright')['copyright'],
          'selected_build_id' => version.dig('relationships', 'build', 'data', 'id'),
          'localizations' => locales,
          'review_fields_present' => presence(review, 'contactFirstName', 'contactLastName', 'contactEmail',
                                             'contactPhone', 'demoAccountName', 'demoAccountPassword', 'notes'),
          'demo_account_required' => attributes(review, 'demoAccountRequired')['demoAccountRequired'] }
      end,
      'app_information' => infos['data'].map do |info|
        rating = related.call(info, 'ageRatingDeclaration')
        { 'id' => info['id'], 'state' => attributes(info, 'appStoreState'),
          'primary_category_id' => info.dig('relationships', 'primaryCategory', 'data', 'id'),
          'age_rating' => attributes(rating, 'appStoreAgeRating'),
          'age_rating_unanswered_fields' => (rating || {}).fetch('attributes', {}).select { |_name, value| value.nil? }.keys,
          'localizations' => (info.dig('relationships', 'appInfoLocalizations', 'data') || []).map do |ref|
            locale = lookup.fetch([ref['type'], ref['id']])
            { 'locale' => locale.dig('attributes', 'locale'),
              'fields_present' => presence(locale, 'name', 'subtitle', 'privacyPolicyUrl') }
          end }
      end,
      'testflight_groups' => groups['data'].map { |group| attributes(group, 'name', 'isInternalGroup') },
      'not_checked' => ['App Privacy disclosures', 'agreements', 'pricing and availability', 'device testing']
    }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {}
    OptionParser.new do |parser|
      parser.banner = 'Usage: bundle exec ruby vendor/flutter-fastlane-release/tools/app_store_status.rb [--bundle-id ID]'
      parser.on('--bundle-id ID', 'App bundle ID (default: the Appfile app_identifier)') { |value| options[:bundle_id] = value }
      parser.on('-h', '--help', 'Show help; no API request') { puts parser; exit }
    end.parse!
    raise AppStoreStatus::AuditError, 'Unexpected command arguments.' unless ARGV.empty?

    bundle_id = options[:bundle_id] || AppContext.bundle_id
    puts JSON.pretty_generate(AppStoreStatus.new(AppContext.api_key_path).report(bundle_id))
  rescue AppStoreStatus::AuditError, OptionParser::ParseError, ArgumentError => error
    warn error.message
    exit 1
  rescue StandardError => error
    # Exceptions from key parsing/signing may contain sensitive values.
    warn "App Store status check failed (#{error.class}); check credentials and connectivity."
    exit 1
  end
end
