# frozen_string_literal: true

require 'open3'

# Thin wrapper around the git commands the release flow needs. Keeps status
# handling in one place instead of mixing IO.popen and $CHILD_STATUS.
module ReleaseGit
  class Error < StandardError; end

  module_function

  def capture(root, *command)
    output, status = Open3.capture2e(*command, chdir: root)
    [output, status.success?]
  end

  def output(root, *command)
    text, success = capture(root, *command)
    raise Error, text.strip unless success

    text
  end

  def current_commit(root)
    output(root, 'git', 'rev-parse', 'HEAD').strip
  end

  def head_bytes(root, relative_path)
    text, success = capture(root, 'git', 'show', "HEAD:#{relative_path}")
    success ? text : nil
  end

  # Returns true when a commit was created, false when the paths were already clean.
  def commit_paths(root, relative_paths, message)
    add, added = capture(root, 'git', 'add', '--', *relative_paths)
    raise Error, "Could not stage the release build and changelog.\n#{add}" unless added

    _, clean = capture(root, 'git', 'diff', '--quiet', 'HEAD', '--', *relative_paths)
    return false if clean

    commit, committed = capture(root, 'git', 'commit', '-m', message, '--', *relative_paths)
    raise Error, "Could not commit the release build and changelog.\n#{commit}" unless committed

    true
  end
end
