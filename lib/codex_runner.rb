# frozen_string_literal: true

require 'timeout'

module CodexRunner
  class Error < StandardError; end

  def self.run(command, root:, timeout:, log_path:)
    raise Error, 'Codex working directory does not exist.' unless File.directory?(root)
    raise Error, 'Codex log directory does not exist.' unless File.directory?(File.dirname(log_path))

    begin
      pid = Process.spawn(*command, chdir: root, out: log_path, err: [:child, :out], pgroup: true)
    rescue Errno::ENOENT => e
      raise Error, 'Codex working or log directory disappeared.' unless File.directory?(root) && File.directory?(File.dirname(log_path))
      raise Error, "Codex executable could not be started: #{e.message}. Install codex and authenticate it before generating release notes."
    end
    status = Timeout.timeout(timeout) { Process.wait2(pid).last }
    return if status.success?

    log = File.read(log_path)
    reason = if log.match?(/unauthorized|authentication (?:failed|required)|not logged in|401|invalid.api.key/i)
               'authentication failed; authenticate the Codex CLI before retrying'
             else
               'execution/service failed; check Codex connectivity and CLI authentication'
             end
    raise Error, "Codex release-note generation #{reason} (exit #{status.exitstatus || 'signal'}). No notes saved."
  rescue Errno::ENOENT => e
    raise Error, "Codex diagnostic log is unavailable: #{e.message}. No notes saved."
  rescue Timeout::Error
    terminate(pid)
    pid = nil
    raise Error, "Codex release-note generation timed out after #{timeout} seconds. No notes saved."
  ensure
    terminate(pid) if pid && status.nil?
  end

  def self.terminate(pid)
    Process.kill('TERM', -pid)
    begin
      Timeout.timeout(2) { Process.wait(pid) }
    rescue Timeout::Error
      # The unreaped leader still reserves its PID: this is our process group.
      Process.kill('KILL', -pid)
      Process.wait(pid)
    end
  rescue Errno::ESRCH, Errno::ECHILD
    # Do not signal a PID/group once its child has exited or been reaped.
  end
end
