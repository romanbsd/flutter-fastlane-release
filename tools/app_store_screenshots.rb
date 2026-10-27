#!/usr/bin/env ruby
# Upload the en-US App Store screenshots in fastlane/screenshots/en-US/<slot>/; default is a read-only plan.
require_relative 'app_store_status'
require 'digest/md5'
require 'optparse'
require 'dotenv'
require 'json'
require 'uri'
require 'net/http'

class AppStoreScreenshots < AppStoreStatus
  SLOTS = {
    'iphone-medium' => ['APP_IPHONE_61', [1206, 2622]],
    'ipad' => ['APP_IPAD_PRO_3GEN_129', [2064, 2752]]
  }.freeze

  def write(method, path, data)
    uri = URI.join(API, path)
    unless uri.scheme == 'https' && uri.host == URI(API).host && uri.port == 443
      raise AuditError, 'Unexpected App Store Connect API URL.'
    end
    request = (method == :post ? Net::HTTP::Post : Net::HTTP::Patch).new(uri)
    request['Authorization'] = "Bearer #{@token}"
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate('data' => data)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20,
                              read_timeout: 30, write_timeout: 30) { |http| http.request(request) }
    unless response.is_a?(Net::HTTPSuccess)
      codes = JSON.parse(response.body).fetch('errors', []).map { |e| e['code'] }.compact rescue []
      safe_codes = codes.select { |code| code.match?(/\A[A-Z0-9_.-]+\z/) }
      raise AuditError, "Apple #{method.upcase} failed (HTTP #{response.code}; #{safe_codes.join(', ')})."
    end
    JSON.parse(response.body).fetch('data')
  end

  def manifest
    SLOTS.flat_map do |folder, (display, dimensions)|
      Dir[File.join(AppContext.fastlane_dir, 'screenshots', 'en-US', folder, '*.png')].sort.map do |path|
        name = File.basename(path)
        bytes = File.binread(path)
        self.class.validate_png!(bytes, dimensions, label: "#{folder}/#{name}")
        { folder: folder, name: name, display: display, bytes: bytes,
          checksum: Digest::MD5.hexdigest(bytes) }
      end
    end
  end

  def draft(version_string, build_number)
    apps = collection('/v1/apps', 'filter[bundleId]' => AppContext.bundle_id)['data']
    raise AuditError, 'Expected exactly one app for the bundle ID.' unless apps.length == 1
    versions = collection("/v1/apps/#{apps.first.fetch('id')}/appStoreVersions")['data']
    matches = versions.select do |v|
      v.dig('attributes', 'platform') == 'IOS' && v.dig('attributes', 'versionString') == version_string
    end
    raise AuditError, 'Expected exactly one matching iOS draft.' unless matches.length == 1
    version = matches.first
    unless version.dig('attributes', 'appStoreState') == 'PREPARE_FOR_SUBMISSION'
      raise AuditError, 'Screenshot upload requires a Prepare for Submission draft.'
    end
    build = get("/v1/appStoreVersions/#{version.fetch('id')}/build")['data']
    unless build && build.dig('attributes', 'version') == build_number &&
           build.dig('attributes', 'processingState') == 'VALID' && !build.dig('attributes', 'expired')
      raise AuditError, 'The selected build is missing, invalid, expired, or differs from --build.'
    end
    locales = collection("/v1/appStoreVersions/#{version.fetch('id')}/appStoreVersionLocalizations")['data']
    matches = locales.select { |l| l.dig('attributes', 'locale') == 'en-US' }
    raise AuditError, 'Expected exactly one en-US localization.' unless matches.length == 1
    matches.first
  end

  def existing_screenshots(set_id)
    collection("/v1/appScreenshotSets/#{set_id}/appScreenshots", 'limit' => 200)['data']
  end

  def compatible!(items, files)
    names = items.map { |i| i.dig('attributes', 'fileName') }
    if names.uniq.length != names.length || (names - files.map { |f| f[:name] }).any?
      raise AuditError, 'Slot contains unexpected or duplicate screenshots; inspect it manually.'
    end
    items.each do |item|
      attrs = item.fetch('attributes')
      file = files.find { |f| f[:name] == attrs.fetch('fileName') }
      if attrs['fileSize'] != file[:bytes].bytesize ||
         (attrs['sourceFileChecksum'] && attrs['sourceFileChecksum'] != file[:checksum]) ||
         attrs.dig('assetDeliveryState', 'state') == 'FAILED'
        raise AuditError, "Existing #{file[:name]} differs or failed; inspect it manually."
      end
    end
  end

  def self.validate_png!(bytes, dimensions, label: 'PNG')
    unless bytes.bytesize >= 33 && bytes.start_with?("\x89PNG\r\n\x1a\n".b) &&
           bytes[8, 4].unpack1('N') == 13 && bytes[12, 4] == 'IHDR' &&
           bytes[16, 8].unpack('NN') == dimensions
      raise AuditError, "Unexpected or truncated PNG header/dimensions: #{label}."
    end
  end

  def self.validate_operations!(operations, byte_count)
    raise AuditError, 'Screenshot has no upload operations.' if !operations || operations.empty?
    offset = 0
    operations.sort_by { |o| o.fetch('offset') }.each do |op|
      uri = URI(op.fetch('url'))
      unless uri.scheme == 'https' && uri.host&.end_with?('.apple.com') && uri.port == 443 &&
             !uri.userinfo && op['method'] == 'PUT' && op['offset'] == offset &&
             op['length'].is_a?(Integer) && op['length'].positive?
        raise AuditError, 'Unexpected Apple asset upload operation.'
      end
      op.fetch('requestHeaders').each do |header|
        if %w[authorization proxy-authorization cookie host].include?(header.fetch('name').downcase)
          raise AuditError, 'Unexpected credential or host header in an asset operation.'
        end
      end
      offset += op['length']
    end
    raise AuditError, 'Upload parts do not cover the complete PNG.' unless offset == byte_count
  end

  def upload_parts(item, file)
    operations = item.dig('attributes', 'uploadOperations')
    # Validate all parts and headers before sending any bytes. No API JWT on assets.
    self.class.validate_operations!(operations, file[:bytes].bytesize)
    operations.each do |op|
      uri = URI(op.fetch('url'))
      request = Net::HTTP::Put.new(uri)
      op.fetch('requestHeaders').each do |header|
        request[header.fetch('name')] = header.fetch('value')
      end
      request.body = file[:bytes].byteslice(op.fetch('offset'), op.fetch('length'))
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20,
                                read_timeout: 30, write_timeout: 30) { |http| http.request(request) }
      raise AuditError, "Asset upload failed (HTTP #{response.code}); rerun to resume." unless response.is_a?(Net::HTTPSuccess)
    end
    write(:patch, "/v1/appScreenshots/#{item.fetch('id')}", {
      type: 'appScreenshots', id: item.fetch('id'),
      attributes: { uploaded: true, sourceFileChecksum: file[:checksum] }
    })
  end

  def run(version, build, upload: false)
    files = manifest
    raise AuditError, 'No screenshots found under fastlane/screenshots/en-US/<slot>/.' if files.empty?
    locale = draft(version, build)
    sets = collection("/v1/appStoreVersionLocalizations/#{locale.fetch('id')}/appScreenshotSets")['data']
    pending = []
    files.group_by { |f| f[:display] }.each do |display, group|
      matches = sets.select { |s| s.dig('attributes', 'screenshotDisplayType') == display }
      raise AuditError, "Duplicate slot #{display}." if matches.length > 1
      set = matches.first
      items = set ? existing_screenshots(set.fetch('id')) : []
      compatible!(items, group)
      puts "#{display}: #{items.length} existing; #{group.length} planned for iOS #{version} (#{build})."
      next unless upload
      set ||= write(:post, '/v1/appScreenshotSets', {
        type: 'appScreenshotSets', attributes: { screenshotDisplayType: display },
        relationships: { appStoreVersionLocalization: { data: {
          type: 'appStoreVersionLocalizations', id: locale.fetch('id')
        } } }
      })
      group.each do |file|
        item = items.find { |i| i.dig('attributes', 'fileName') == file[:name] }
        item ||= write(:post, '/v1/appScreenshots', {
          type: 'appScreenshots', attributes: { fileSize: file[:bytes].bytesize, fileName: file[:name] },
          relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set.fetch('id') } } }
        })
        state = item.dig('attributes', 'assetDeliveryState', 'state')
        unless %w[AWAITING_UPLOAD UPLOAD_COMPLETE COMPLETE].include?(state)
          item = get("/v1/appScreenshots/#{item.fetch('id')}").fetch('data')
          state = item.dig('attributes', 'assetDeliveryState', 'state')
        end
        if state == 'AWAITING_UPLOAD'
          upload_parts(item, file)
        elsif !%w[UPLOAD_COMPLETE COMPLETE].include?(state)
          raise AuditError, "#{file[:folder]}/#{file[:name]}: unexpected screenshot state #{state.inspect}; inspect Apple before retrying."
        end
        puts "#{file[:folder]}/#{file[:name]}: #{state == 'COMPLETE' ? 'already complete' : 'uploaded; checking processing'}."
        pending << [item.fetch('id'), file]
      end
    end
    return puts 'Read-only plan; pass --upload to upload exactly these files. No screenshots are deleted.' unless upload
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
    until pending.empty?
      pending.reject! do |id, file|
        attrs = get("/v1/appScreenshots/#{id}").fetch('data').fetch('attributes')
        state = attrs.dig('assetDeliveryState', 'state')
        raise AuditError, "#{file[:folder]}/#{file[:name]} processing failed; inspect Apple manually." if state == 'FAILED'
        next false unless state == 'COMPLETE'
        raise AuditError, 'Processed screenshot checksum mismatch.' unless attrs['sourceFileChecksum'] == file[:checksum]
        puts "Verified COMPLETE: #{file[:folder]}/#{file[:name]}."
        true
      end
      break if pending.empty?
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise AuditError, 'Processing is still pending after two minutes; rerun to verify without duplicates.'
      end
      sleep 5
    end
    puts 'All screenshots processed successfully and match their local PNG checksums.'
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  begin
    options = { upload: false }
    OptionParser.new do |p|
      p.banner = 'Usage: bundle exec ruby vendor/flutter-fastlane-release/tools/app_store_screenshots.rb --version VERSION --build NUMBER [--upload]'
      p.on('--version VERSION', 'Explicit iOS store draft version') { |v| options[:version] = v }
      p.on('--build NUMBER', 'Expected selected build number') { |v| options[:build] = v }
      p.on('--upload', 'Upload the planned files; default is read-only') { options[:upload] = true }
      p.on('-h', '--help') { puts p; exit }
    end.parse!
    unless ARGV.empty? && options[:version]&.match?(/\A\d+(?:\.\d+)+\z/) && options[:build]&.match?(/\A[1-9]\d*\z/)
      raise AppStoreStatus::AuditError, 'Supply --version and --build with no extra arguments.'
    end
    AppStoreScreenshots.new(AppContext.api_key_path).run(options[:version], options[:build], upload: options[:upload])
  rescue AppStoreStatus::AuditError, OptionParser::ParseError, ArgumentError => error
    warn error.message
    exit 1
  rescue StandardError => error
    # Key parsing, signed URLs, and provider bodies may contain secrets.
    warn "Screenshot upload stopped (#{error.class}); check connectivity and rerun to inspect/resume."
    exit 1
  end
end
