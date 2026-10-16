# frozen_string_literal: true

require 'fileutils'
require 'plist'

module IosSigning
  def ios_encryption_declaration
    declaration = env_boolean('USES_NON_EXEMPT_ENCRYPTION', default: nil)
    return declaration unless declaration.nil?

    info = Plist.parse_xml(File.join(project_root, 'ios', 'Runner', 'Info.plist'))
    declaration = info && info['ITSAppUsesNonExemptEncryption']
    return declaration if [true, false].include?(declaration)

    FastlaneCore::UI.user_error!('Declare export compliance with USES_NON_EXEMPT_ENCRYPTION or ITSAppUsesNonExemptEncryption in Info.plist.')
  end

  def build_signed_ios_ipa(api_key_options, team_id, build_number)
    started_at = Time.now
    setup_ci if is_ci
    identifier = CredentialsManager::AppfileConfig.try_fetch_value(:app_identifier)
    match(type: 'appstore', readonly: true, app_identifier: identifier, team_id: team_id, **api_key_options)
    profiles = lane_context[Fastlane::Actions::SharedValues::MATCH_PROVISIONING_PROFILE_MAPPING]
    profile = profiles && profiles[identifier]
    FastlaneCore::UI.user_error!('match did not provide an App Store provisioning profile for the app.') if profile.to_s.empty?

    # Flutter builds the archive as well as the IPA. Configure both signing phases.
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

    project_path = File.join(project_root, 'ios', 'Runner.xcodeproj')
    settings_path = File.join(project_path, 'project.pbxproj')
    original_settings = File.binread(settings_path)
    begin
      update_code_signing_settings(
        path: project_path, use_automatic_signing: false,
        targets: ['Runner'], build_configurations: ['Release'],
        sdk: 'iphoneos*',
        team_id: team_id, bundle_identifier: identifier,
        code_sign_identity: 'Apple Distribution', profile_name: profile
      )
      flutter('build', 'ipa', '--release', "--export-options-plist=#{export_path}",
              *ios_build_args(build_number: build_number))
    ensure
      File.binwrite(settings_path, original_settings)
    end

    build_artifact('build/ios/ipa/*.ipa', since: started_at)
  end
end
