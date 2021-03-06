require 'open4'
require 'timeout'

class CommandFailedError < StandardError
end

module CommandRunner

  def execute_command(command)
    pid, out = nil, ''
    status = Timeout.timeout(timeout_value) do
        # Open4::popen4("/bin/bash -c \"#{command}\" 2>&1") do |p, stdin, stdout, stderr|
        # above does not work when running: su - 5f091acbd4 -c 'ssh-keygen -q -N "" -f /var/vcap/store/sharedfs/home/5f091acbd4/.ssh/id_rsa'
        Open4::popen4("#{command} 2>&1") do |p, stdin, stdout, stderr|
        pid = p
        while (o = stdout.gets) do
          out = out + o
        end
      end
    end
    logger.info "Finished command \"#{command}\", STATUS: #{status.to_i}, PID: #{pid}, OUTPUT:\n#{out}"
    if status.to_i != 0
      raise CommandFailedError, "Command \"#{command}\" failed, STATUS: #{status.to_i}, PID: #{pid}, OUTPUT:\n#{out}"
    end
    out
  rescue Timeout::Error
    logger.error "Timed out on command \"#{command}\", PID: #{pid}, OUTPUT:\n#{out}"
    Process.kill 9, pid
    # we need to collect status so it doesn't
    # stick around as zombie process
    Process.wait pid
    raise "Command \"#{command}\" timed out, PID: #{pid}, OUTPUT:\n#{out}"
  end

  private

  def timeout_value
    override = ENV['TIMEOUT_OVERRIDE']
    override ? override.to_i : 8
  end

end