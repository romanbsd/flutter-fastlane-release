# frozen_string_literal: true

module PubspecVersion
  PATTERN = /^version:[ \t]*(?<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\+(?<build>\d+)[ \t]*$/

  def self.read(path)
    content = File.read(path)
    match = content.match(PATTERN)
    raise ArgumentError, 'Expected pubspec version: major.minor.patch+build.' unless match

    { version: match[:version], build_number: match[:build].to_i, content: content }
  end

end
