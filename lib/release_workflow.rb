# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

module ReleaseWorkflow
  def write_release_status(plan, results)
    path = File.join(project_root, 'build', 'release', 'status.json')
    FileUtils.mkdir_p(File.dirname(path))
    payload = plan.slice(:run_id, :started_at, :state, :phase, :version, :build_numbers, :commit)
    payload[:updated_at] = Time.now.utc.iso8601
    payload[:platforms] = results
    temporary_path = "#{path}.#{plan[:run_id]}.tmp"
    begin
      File.write(temporary_path, JSON.pretty_generate(payload))
      File.rename(temporary_path, path)
    ensure
      FileUtils.rm_f(temporary_path)
    end
  end

  def run_beta_release(platforms, run_checks: false)
    plan = {
      run_id: SecureRandom.uuid, started_at: Time.now.utc.iso8601,
      state: 'running', phase: 'preflight'
    }
    results = platforms.to_h { |platform| [platform, { status: 'planned' }] }
    release_error = nil
    begin
      write_release_status(plan, results)
      plan.merge!(release_plan(platforms))
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
        artifact = if platform == :ios
                     build_signed_ios_ipa(plan[:ios].slice(:api_key_path), plan[:team_id], plan[:build_numbers][:ios])
                   else
                     build_android_aab(plan[:build_numbers][:android])
                   end
        results[platform] = { status: 'built', artifact: artifact,
                              sha256: Digest::SHA256.file(artifact).hexdigest,
                              notes_sha256: Digest::SHA256.hexdigest(platform == :ios ? plan[:ios_notes] : plan[:android_notes]),
                              build_number: plan[:build_numbers][platform] }
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
    FastlaneCore::UI.success("Release #{plan[:version]} builds #{plan[:build_numbers]} uploaded; verify store review and tester availability. See build/release/status.json.")
  end
end
