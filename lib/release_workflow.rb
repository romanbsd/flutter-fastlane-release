# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

module ReleaseWorkflow
  def release_status_path
    File.join(project_root, 'build', 'release', 'status.json')
  end

  # Run status is overwritten by every release attempt; receipts outlive a run so
  # an artifact built earlier can still be uploaded after a later attempt fails.
  def release_receipts_path
    File.join(project_root, 'build', 'release', 'receipts.json')
  end

  def write_release_status(plan, results)
    payload = plan.slice(:run_id, :started_at, :state, :phase, :version, :build_numbers, :commit)
    payload[:updated_at] = Time.now.utc.iso8601
    payload[:platforms] = results
    write_json_atomically(release_status_path, payload)
  end

  def release_receipts
    path = release_receipts_path
    return {} unless File.file?(path)

    parsed = JSON.parse(File.read(path))
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError => error
    FastlaneCore::UI.user_error!("Invalid release receipts JSON: #{error.message}")
  end

  def record_artifact_receipt(plan, platform, result)
    receipts = release_receipts
    platform_receipts = receipts[platform.to_s]
    # A legacy flat receipt (no per-version keys) is replaced by the keyed schema.
    unless platform_receipts.is_a?(Hash) && !platform_receipts.key?('sha256')
      platform_receipts = {}
    end
    platform_receipts["#{plan[:version]}+#{result[:build_number]}"] = {
      'run_id' => plan[:run_id],
      'version' => plan[:version],
      'build_number' => result[:build_number],
      'sha256' => result[:sha256],
      'notes_sha256' => result[:notes_sha256],
      'recorded_at' => Time.now.utc.iso8601
    }
    receipts[platform.to_s] = platform_receipts
    write_json_atomically(release_receipts_path, receipts)
  end

  def write_json_atomically(path, payload)
    FileUtils.mkdir_p(File.dirname(path))
    temporary_path = "#{path}.#{SecureRandom.uuid}.tmp"
    begin
      File.write(temporary_path, JSON.pretty_generate(payload))
      File.rename(temporary_path, path)
    ensure
      FileUtils.rm_f(temporary_path)
    end
  end

  def run_beta_release(platforms, run_checks: false, bump: nil)
    plan = {
      run_id: SecureRandom.uuid, started_at: Time.now.utc.iso8601,
      state: 'running', phase: 'preflight'
    }
    results = platforms.to_h { |platform| [platform, { status: 'planned' }] }
    release_error = nil
    begin
      write_release_status(plan, results)
      plan.merge!(release_plan(platforms, bump: bump))
      plan[:phase] = 'preparing'
      write_release_status(plan, results)
      prepare_release(plan)
      plan[:phase] = 'checking'
      if run_checks
        flutter('analyze')
        flutter('test')
      end
      plan[:phase] = 'building'
      platforms.each do |platform|
        results[platform][:status] = 'building'
        write_release_status(plan, results)
        artifact = if platform == :ios
                     build_signed_ios_ipa(plan[:ios].slice(:api_key_path), plan[:team_id], plan[:build_numbers][:ios])
                   else
                     build_android_aab(plan[:build_numbers][:android])
                   end
        results[platform] = { status: 'built', artifact: artifact,
                              sha256: Digest::SHA256.file(artifact).hexdigest,
                              notes_sha256: Digest::SHA256.hexdigest(platform == :ios ? plan[:ios_notes] : plan[:android_notes]),
                              build_number: plan[:build_numbers][platform] }
        record_artifact_receipt(plan, platform, results[platform])
        write_release_status(plan, results)
      end
      plan[:phase] = 'uploading'
      platforms.each do |platform|
        results[platform][:status] = 'uploading'
        write_release_status(plan, results)
        if platform == :ios
          upload_to_testflight(ipa: results[platform][:artifact], **plan[:ios])
        else
          upload_android_aab(results[platform][:artifact], plan[:android], plan[:android_notes])
        end
        results[platform][:status] = platform == :android && plan[:android][:validate_only] ? 'validated' : 'uploaded'
        write_release_status(plan, results)
      end
      plan[:phase] = 'tagging'
      write_release_status(plan, results)
      tag_release!(plan[:version]) unless plan.dig(:android, :validate_only)
      plan[:state] = 'succeeded'
      plan[:phase] = 'complete'
    rescue StandardError => error
      release_error = error
      plan[:state] = 'failed'
      results.each_value do |result|
        result[:status] = 'upload_outcome_unknown' if result[:status] == 'uploading'
        result[:status] = 'build_failed' if result[:status] == 'building'
      end
      raise
    ensure
      begin
        write_release_status(plan, results)
      rescue StandardError => status_error
        raise unless release_error
        FastlaneCore::UI.error("Could not update build/release/status.json after release failure: #{status_error.message}")
      end
    end
    summary = results.map { |platform, result| "#{platform}: #{result[:status]}" }.join(', ')
    FastlaneCore::UI.success("Release #{plan[:version]} finished (#{summary}). Verify store review and tester availability. See build/release/status.json.")
  end
end
