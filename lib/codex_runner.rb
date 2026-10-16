# frozen_string_literal: true

require 'timeout'

module CodexRunner
  class Error < StandardError; end

  # Release jobs hold store and signing credentials. The notes assistant only
  # needs its CLI login and basic process settings, never those job secrets.
  CHILD_ENV_KEYS = %w[HOME PATH USER LOGNAME LANG LC_ALL LC_CTYPE TMPDIR
                      XDG_CONFIG_HOME XDG_CACHE_HOME CODEX_HOME SSL_CERT_FILE
                      SSL_CERT_DIR].freeze

  def self.run(command, root:, timeout:, log_path:)
    raise Error, 'Codex working directory does not exist.' unless File.directory?(root)
    raise Error, 'Codex log directory does not exist.' unless File.directory?(File.dirname(log_path))

    begin
      child_env = ENV.to_h.select { |key, _| CHILD_ENV_KEYS.include?(key) }
      pid = Process.spawn(child_env, *command, chdir: root, out: log_path,
                         err: [:child, :out], pgroup: true, unsetenv_others: true)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC, Errno::ENOTDIR => e
      raise Error, 'Codex working or log directory disappeared.' unless File.directory?(root) && File.directory?(File.dirname(log_path))
      raise Error, "Codex executable could not be started: #{e.message}. Install codex and authenticate it before generating release notes."
    end
    status = Timeout.timeout(timeout) { Process.wait2(pid).last }
    return if status.success?

    log = File.open(log_path, 'rb') do |file|
      file.seek(-[file.size, 16_384].min, IO::SEEK_END)
      file.read
    end.force_encoding(Encoding::UTF_8).scrub
    reason = if log.match?(/unauthorized|authentication (?:failed|required)|not logged in|HTTP\S*\s+401|status(?: code)?[:= ]+401|invalid.api.key/i)
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
      Timeout.timeout(2) { Process.wait(pid) }
    end
  rescue Errno::ESRCH, Errno::ECHILD, Timeout::Error
    # Do not signal a PID/group once its child has exited or been reaped.
  end
end
