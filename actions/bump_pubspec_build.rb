# frozen_string_literal: true

require_relative '../lib/pubspec_version'
require_relative '../lib/release_numbers'

module Fastlane
  module Actions
    class BumpPubspecBuildAction < Action
      def self.run(params)
        path = params[:pubspec_path].to_s.strip
        if path.empty?
          fastlane_dir = FastlaneCore::FastlaneFolder.path
          UI.user_error!('Provide pubspec_path; no application fastlane directory was found.') if fastlane_dir.to_s.empty?
          path = File.join(fastlane_dir, '..', 'pubspec.yaml')
        end
        path = File.expand_path(path)
        UI.user_error!("pubspec.yaml not found: #{path}") unless File.file?(path)
        current = PubspecVersion.read(path)
        selected = params[:build_number] || current[:build_number] + 1
        UI.user_error!('build_number must be a positive integer.') unless selected.to_s.match?(/\A\d+\z/) && selected.to_i.positive?
        UI.user_error!('build_number must increase the pubspec build number.') unless selected.to_i > current[:build_number]
        ReleaseNumbers.validate_play_version_code!(selected)
        updated = current[:content].sub(PubspecVersion::PATTERN) do
          "version: #{Regexp.last_match[:version]}+#{selected}"
        end
        File.write(path, updated)
        UI.success("Updated pubspec to #{current[:version]}+#{selected}; review and commit it before release.")
        selected.to_i
      rescue ArgumentError => error
        UI.user_error!(error.message)
      end

      def self.description
        'Explicitly increment or select a higher pubspec build number'
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :pubspec_path, description: 'Application pubspec.yaml path', optional: true, type: String),
          FastlaneCore::ConfigItem.new(key: :build_number, description: 'Higher build number; defaults to current plus one', optional: true, type: Integer)
        ]
      end

      def self.authors
        ['Project contributors']
      end

      def self.is_supported?(_platform)
        true
      end
    end
  end
end
