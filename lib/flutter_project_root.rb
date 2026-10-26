# frozen_string_literal: true

module FlutterProjectRoot
  module_function

  def from_fastlane_folder
    resolve(FastlaneCore::FastlaneFolder.path)
  end

  # Fastlane runs lanes from the fastlane directory and resolves that directory
  # again from the new working directory. A nested fastlane/ directory wins that
  # lookup, so one ".." lands on fastlane/ instead of the Flutter app.
  def resolve(fastlane_dir)
    start = fastlane_dir.to_s.strip
    raise ArgumentError, 'Import this Fastfile from an application fastlane/Fastfile.' if start.empty?

    dir = File.expand_path(start)
    6.times do
      root = File.dirname(dir)
      return root if app_root?(root)
      break if root == dir

      dir = root
    end

    raise ArgumentError, "pubspec.yaml not found above #{File.expand_path(start)}."
  end

  def app_root?(dir)
    File.file?(File.join(dir, 'pubspec.yaml')) &&
      File.file?(File.join(dir, 'fastlane', 'Fastfile'))
  end
end
