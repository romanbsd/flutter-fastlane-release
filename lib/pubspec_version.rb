# frozen_string_literal: true

module PubspecVersion
  PATTERN = /^version:[ \t]*(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\+(?<build>\d+)[ \t]*$/

  def self.read(path)
    content = File.read(path)
    match = content.match(PATTERN)
    raise ArgumentError, 'Expected pubspec version: major.minor.patch+build.' unless match

    { version: match[:version], build_number: match[:build].to_i, content: content }
  end

  # Bumps the numeric core and drops any pre-release suffix. A major bump
  # resets minor and patch, a minor bump resets patch.
  def self.next_version(version, part)
    core = version.to_s.split('-', 2).first
    raise ArgumentError, 'Expected version major.minor.patch.' unless core.match?(/\A\d+\.\d+\.\d+\z/)

    major, minor, patch = core.split('.').map(&:to_i)
    case part.to_s
    when 'major' then "#{major + 1}.0.0"
    when 'minor' then "#{major}.#{minor + 1}.0"
    when 'patch' then "#{major}.#{minor}.#{patch + 1}"
    else raise ArgumentError, 'Version bump must be major, minor, or patch.'
    end
  end

  def self.rewrite(content, version:, build:)
    content.sub(PATTERN) { "version: #{version}+#{build}" }
  end
end
