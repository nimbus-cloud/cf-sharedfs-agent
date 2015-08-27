require 'open4'
require 'timeout'

module CommandRunner

  def execute_command(command)
    pid, out = nil, ''
    status = Timeout.timeout(5) do
      Open4::popen4("/bin/bash -c \"#{command}\" 2>&1") do |p, stdin, stdout, stderr|
        pid = p
        while (o = stdout.gets) do
          out = out + o
        end
      end
    end
    puts "Finished command \"#{command}\", STATUS: #{status.to_i}, OUTPUT:\n#{out}"
    raise "Command \"#{command}\" failed, PID: #{pid}" unless status.to_i == 0
    out
  rescue Timeout::Error
    puts "Timed out on command \"#{command}\", PID: #{pid}, OUTPUT:\n#{out}"
    Process.kill 9, pid
    # we need to collect status so it doesn't
    # stick around as zombie process
    Process.wait pid
    raise "Command \"#{command}\" timed out, PID: #{pid}"
  end

end

# include ::CommandRunner
#
# execute_command "ls -la"
# puts execute_command "df -h"
# execute_command "echo 'abc def ghijk '; sleep 6"



