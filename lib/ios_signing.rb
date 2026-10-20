# frozen_string_literal: true

require 'fileutils'
require 'plist'

module IosSigning
  def ios_encryption_declaration
    configured = env_boolean('USES_NON_EXEMPT_ENCRYPTION', default: nil)
    info_path = File.join(project_root, 'ios', 'Runner', 'Info.plist')
    FastlaneCore::UI.user_error!('ios/Runner/Info.plist is missing.') unless File.file?(info_path)
    begin
      info = Plist.parse_xml(info_path)
    rescue StandardError => error
      FastlaneCore::UI.user_error!("Read ios/Runner/Info.plist before declaring export compliance: #{error.message}")
    end
    FastlaneCore::UI.user_error!('ios/Runner/Info.plist could not be parsed.') unless info.is_a?(Hash)
    embedded = info && info['ITSAppUsesNonExemptEncryption']
    if [true, false].include?(embedded)
      if !configured.nil? && configured != embedded
        FastlaneCore::UI.user_error!('USES_NON_EXEMPT_ENCRYPTION conflicts with ITSAppUsesNonExemptEncryption in Info.plist.')
      end
      return embedded
    end
    return configured unless configured.nil?

    FastlaneCore::UI.user_error!('Declare export compliance with USES_NON_EXEMPT_ENCRYPTION or ITSAppUsesNonExemptEncryption in Info.plist.')
  end

  def build_signed_ios_ipa(api_key_options, team_id, build_number)
    ensure_ios_toolchain!
    build_signed_ios_artifact(api_key_options, team_id, build_number,
                              match_type: 'appstore', export_method: nil)
  end

  # Firebase distribution needs an Ad Hoc export. Flutter's default export
  # method is app-store, so the method has to be requested explicitly.
  def build_signed_ios_adhoc_ipa(api_key_options, team_id, build_number)
    build_signed_ios_artifact(api_key_options, team_id, build_number,
                              match_type: 'adhoc', export_method: 'ad-hoc')
  end

  def build_signed_ios_artifact(api_key_options, team_id, build_number, match_type:, export_method:)
    started_at = Time.now
    setup_ci if is_ci
    identifier = expected_app_identifier(:app_identifier)
    FastlaneCore::UI.user_error!('Appfile app_identifier is required for iOS builds.') if identifier.empty?
    match(type: match_type, readonly: true, app_identifier: identifier, team_id: team_id, **api_key_options)
    profiles = lane_context[Fastlane::Actions::SharedValues::MATCH_PROVISIONING_PROFILE_MAPPING]
    profile = profiles && profiles[identifier]
    FastlaneCore::UI.user_error!("match did not provide a #{match_type} provisioning profile for the app.") if profile.to_s.empty?

    project_path = File.join(project_root, 'ios', 'Runner.xcodeproj')
    settings_path = File.join(project_path, 'project.pbxproj')
    unless File.file?(settings_path)
      FastlaneCore::UI.user_error!("Xcode project not found: #{settings_path}")
    end
    export_args = if export_method
                    ['--export-method', export_method]
                  else
                    ["--export-options-plist=#{write_ios_export_options(profiles, team_id)}"]
                  end

    original_settings = File.binread(settings_path)
    # Keep an on-disk copy first: a killed process cannot run the ensure block.
    backup_path = "#{settings_path}.fastlane-backup"
    File.binwrite(backup_path, original_settings)

    build_error = nil
    begin
      update_code_signing_settings(
        path: project_path, use_automatic_signing: false,
        targets: ['Runner'], build_configurations: ['Release'],
        sdk: 'iphoneos*',
        team_id: team_id, bundle_identifier: identifier,
        code_sign_identity: 'Apple Distribution', profile_name: profile
      )
      flutter('build', 'ipa', '--release', *export_args, *ios_build_args(build_number: build_number))
    rescue StandardError => error
      build_error = error
      raise
    ensure
      restore_ios_project_settings(settings_path, original_settings, backup_path, build_error)
    end

    build_artifact('build/ios/ipa/*.ipa', since: started_at)
  end

  # Flutter reads the export method from the plist, so it must not be combined
  # with --export-method.
  def write_ios_export_options(profiles, team_id)
    export_path = File.join(project_root, 'build', 'ios', 'fastlane', 'ExportOptions.plist')
    FileUtils.mkdir_p(File.dirname(export_path))
    File.write(export_path, Plist::Emit.dump({
      'method' => 'app-store-connect',
      'destination' => 'export',
      'teamID' => team_id,
      'signingStyle' => 'manual',
      'signingCertificate' => 'Apple Distribution',
      'provisioningProfiles' => profiles,
      'manageAppVersionAndBuildNumber' => false,
      'uploadSymbols' => true
    }))
    export_path
  end

  def restore_ios_project_settings(settings_path, original_settings, backup_path, build_error)
    begin
      File.binwrite(settings_path, original_settings)
    rescue StandardError => restore_error
      raise unless build_error
      FastlaneCore::UI.error("Could not restore project.pbxproj after iOS build failure: #{restore_error.message}. The original file is at #{backup_path}.")
      return
    end
    FileUtils.rm_f(backup_path)
  end
end
