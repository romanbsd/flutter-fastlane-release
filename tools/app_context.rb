# frozen_string_literal: true

require 'dotenv'
require_relative '../lib/flutter_project_root'

# Locates the importing Flutter app for the standalone App Store tools, which run as
# `bundle exec ruby vendor/flutter-fastlane-release/tools/<tool>.rb` from the app.
module AppContext
  module_function

  def root
    dir = Dir.pwd
    loop do
      return dir if FlutterProjectRoot.app_root?(dir)

      parent = File.dirname(dir)
      raise ArgumentError, 'Run the App Store tools from inside a Flutter app with fastlane/Appfile.' if parent == dir

      dir = parent
    end
  end

  def fastlane_dir
    File.join(root, 'fastlane')
  end

  # APP_IDENTIFIER wins; otherwise the literal app_identifier('...') in fastlane/Appfile.
  # ponytail: a literal match, not an Appfile evaluation; set APP_IDENTIFIER when the Appfile computes it.
  def bundle_id
    from_env = ENV['APP_IDENTIFIER'].to_s.strip
    return from_env unless from_env.empty?

    appfile = File.join(fastlane_dir, 'Appfile')
    match = File.file?(appfile) && File.read(appfile)[/^\s*app_identifier\(\s*['"]([^'"]+)['"]\s*\)/, 1]
    raise ArgumentError, 'Set APP_IDENTIFIER or app_identifier(...) in fastlane/Appfile.' unless match

    match
  end

  # The Team API-key JSON, from the environment or the app's fastlane/.env, resolved against the app root.
  def api_key_path
    env_path = File.join(fastlane_dir, '.env')
    config = File.file?(env_path) ? Dotenv.parse(env_path) : {}
    key_path = (ENV['APP_STORE_CONNECT_API_KEY_PATH'] || config['APP_STORE_CONNECT_API_KEY_PATH']).to_s.strip
    raise ArgumentError, 'Set APP_STORE_CONNECT_API_KEY_PATH to the Team API-key JSON file.' if key_path.empty?

    File.expand_path(key_path, root)
  end
end
