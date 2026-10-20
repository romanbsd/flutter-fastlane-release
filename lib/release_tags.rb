# frozen_string_literal: true

require_relative 'release_git'

# Tags only real version changes. A build-number bump inside the same
# major.minor.patch keeps the existing tag.
module ReleaseTags
  VERSION_PATTERN = /\A(\d+)\.(\d+)\.(\d+)\z/
  TAG_PATTERN = /\Av(\d+\.\d+\.\d+)\z/

  module_function

  # Returns the tag to create, or nil when the version is not a plain
  # major.minor.patch bump, is already tagged, or is not newer than the last tag.
  def pending(root, version)
    match = VERSION_PATTERN.match(version.to_s)
    return nil unless match

    tag = "v#{match[1]}.#{match[2]}.#{match[3]}"
    return nil if tagged?(root, tag)

    previous = latest_release_version(root)
    return nil if previous && (version_key(tag) <=> version_key("v#{previous}")) <= 0

    tag
  end

  def create(root, version)
    tag = pending(root, version)
    return nil unless tag

    ReleaseGit.output(root, 'git', 'tag', tag)
    tag
  end

  def tagged?(root, tag)
    ReleaseGit.output(root, 'git', 'tag', '--list', tag).strip == tag
  end

  def latest_release_version(root)
    ReleaseGit.output(root, 'git', 'tag', '--list', 'v*', '--merged', 'HEAD')
              .lines.map(&:strip)
              .filter_map { |tag| tag[TAG_PATTERN, 1] }
              .max_by { |version| version_key("v#{version}") }
  end

  def version_key(tag)
    tag.delete_prefix('v').split('.').map(&:to_i)
  end
end
