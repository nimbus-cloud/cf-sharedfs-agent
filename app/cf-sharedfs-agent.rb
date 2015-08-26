require 'sinatra'
require 'logger'
require 'eventmachine'
require 'rack/fiber_pool'

require_relative 'models/service'

class CFSharedFSAgent  < Sinatra::Base

  # register Sinatra::ActiveRecordExtension

  # I think rack fiber pool may well be broken all requests coming in on the same fiber. Comment out for now
  # use Rack::FiberPool, size: 20

  $stdout.sync = true
  $stderr.sync = true
  $logger = Logger.new($stdout)

  configure :development do
    set :database, 'sqlite3:db/development.sqlite3'
  end

  configure :production do
    set :database, 'sqlite3:/var/vcap/store/sharedfs/sharedfs.sqlite3'
  end

  configure do
    $logger.info('==========================')
    $logger.info('cf-sharedfs agent starting')
    $logger.info('==========================')

    settings_filename = ENV['SETTINGS_FILENAME'] ? ENV['SETTINGS_FILENAME'] : File.dirname(__FILE__) + '/../config/settings.yml'
    $logger.info("Loading settings file #{settings_filename}")
    $app_settings ||= YAML.load_file(settings_filename)
  end

  get '/' do
    'CFSharedFS Agent'
  end

  get '/discover' do
    content_type :json

    {
        :name => $app_settings['agent_name'],
        :disk_size => '10000', # WTF ???
        :disk_free => '1000',  # WTF ???
        :cpu_load => '1000'
    }.to_json
  end

  get '/privision' do
    content_type :json

    service = Potato.new $logger
    success, msg = service.provision

    {
        :name => $app_settings['agent_name'],
        success: success,
        :msg => msg
    }.to_json
  end

  get '/unprovision/:service_id/:username' do
    content_type :json

    service = Potato.new $logger
    success, msg = service.unprovision(params[:service_id], params[:username])

    {
        :name => $app_settings['agent_name'],
        :success => success,
        :msg => msg
    }
  end

  get '/credentials/:service_id' do
    content_type :json

    service = Potato.new $logger
    success, msg, credentials = service.credentials(params[:service_id])


    {
        :name => $app_settings['agent_name'],
        :success => success,
        :msg => msg,
        :credentials => credentials
    }.to_json
  end

  # TODO: run on startup on EM - checks if all the users are there
  def start
    verify_users_exist
    @logger.info "...success"
  end

  def verify_users_exist
    Service.all.each do |service|
      results=execute_command_hash({:command => "id #{service.username}", :timeout => 5})
      if results[:status] != 0
        # this user does not exist lets try and create it.
        # failures here could break the service. but maybe thats not a bad thing
        # if an alert goes out
        # because bosh temp users and these sshfs users share the same uid pools,
        # there maybe a conflict. Consider moving the sshfs uids/guids to their own range
        execute_command("groupadd -g #{service.gid} #{service.username}")
        execute_command("useradd #{service.username} -d /var/vcap/store/sharedfs/home/#{service.username} -s /bin/bash -g #{service.gid} -u #{service.uid} -g #{service.gid}", 5)
      end
    end
  end


  # TODO But all this fibered command execution is a ruby gem
  # is there something better - perhaps something that works with EM
  def execute_command(command, timeout = nil, flog = nil)
    hash = {}
    hash[:command] = command
    (timeout) and (hash[:timeout] = timeout)
    (flog) and (hash[:logging] = flog)
    result=execute_command_hash(hash)
    result[:status]!=0 and raise ("Command execution failed.\nCommand:#{command}.Output:#{result[:output]}\n")
    result
  end

  # Retriable gem???
  def execute_command_hash(hash)
    hash[:command] or raise("No command passed in")
    hash[:logging] or (hash[:logging] = @logger)
    hash[:tries] or (hash[:tries] = 1)
    result={}
    result[:status] = 1
    f = Fiber.current
    attempt=1
    while attempt<=hash[:tries] and result[:status]!=0
      if f.equal?($master_fiber)
        result = execute_command_non_fibered(hash)
      else
        result = execute_command_fibered(hash)
      end
      attempt = attempt + 1
      if attempt<=hash[:tries] and result[:status]!=0
        hash[:logging].debug("Command Failed with #{result[:output]}. Attempt #{attempt}. Sleeping for 2 secs then trying again...")
        sleep(2)
      end
    end
    result
  end


  #  TODO: delete this nonsense
  def execute_command_non_fibered(hash)
    result = {}
    hash[:logging] or hash[:logging] = @logger
    actual_command = hash[:command].gsub(/\$/, "\\\$")
    actual_command = actual_command.gsub(/\"/, "\\\"")
    if (hash[:timeout] == nil)
      hash[:logging].debug("non-fibered execute : #{actual_command}")
      result[:output] = `/bin/bash -c \"#{actual_command}\" 2>&1`
      result[:status] = $?
      hash[:logging].debug("non-fibered result : #{result[:status]}")
    else
      begin
        Timeout::timeout(timeout) do
          hash[:logging].debug("non-fibered execute timeout #{timeout} : #{actual_command}")
          result[:output] = `/bin/bash -c \"#{actual_command}\" 2>&1`
          result[:status] = $?
          hash[:logging].debug("non-fibered result : #{result[:status]}")
        end
      rescue => e
        hash[:logging].debug("non-fibered timeout : 1")
        result[:output] = "Command timed out"
        result[:status] = 1
      end
    end
    result
  end

  def execute_command_fibered(hash)
    f = Fiber.current
    commandTimedOut = false
    result = {}
    hash[:logging].debug("Executing timeout #{hash[:timeout]} fibered : #{hash[:command]}")

    command_proc = proc do |p|
      p.send_data("#{hash[:command]} 2>&1\n")
      p.send_data("exit $?\n")
    end

    cont_proc = proc do |output, status|
      f.resume({:status => status, :output => output})
    end

    pid=EM.system("/bin/bash", command_proc, cont_proc)

    timer=nil
    if hash[:timeout]!=nil
      timer=EM.add_timer(hash[:timeout]) do
        # Depending upon the process tree the kill might not happen straight away
        # Linux is a slacker about killing the child processes
        Process.kill(9, pid)
        hash[:logging].debug("TIMEOUT for pid #{pid}")
        commandTimedOut=true
      end
    end
    result = Fiber.yield
    EM.cancel_timer(timer)
    if commandTimedOut
      result[:output] = "#{result[:output]}. TIMEOUT!"
    end
    result[:status] = result[:status].exitstatus
    hash[:logging].debug("Fibered result #{result[:status]}")
    result
  end


end


class Potato

  def initialize logger
    @logger = logger
  end

  def provision
    username = generate_username
    execute_command("mkdir -p /var/vcap/store/sharedfs/home/#{username}/.ssh", 5)
    execute_command("mkdir -p /var/vcap/store/sharedfs/home/#{username}/data", 5)
    execute_command("useradd #{username} -d /var/vcap/store/sharedfs/home/#{username} -s /bin/bash", 5)
    execute_command("chown -R #{username}:#{username} /var/vcap/store/sharedfs/home/#{username}", 5)
    execute_command("chmod g-rwx /var/vcap/store/sharedfs/home/#{username}", 5)
    execute_command("chmod o-rwx /var/vcap/store/sharedfs/home/#{username}", 5)
    execute_command("su - #{username} -c 'ssh-keygen -q -N \"\" -f /var/vcap/store/sharedfs/home/#{username}/.ssh/id_rsa'", 5)
    execute_command("mv /var/vcap/store/sharedfs/home/#{username}/.ssh/id_rsa.pub /var/vcap/store/sharedfs/home/#{username}/.ssh/authorized_keys")
    result=execute_command("id -u #{username}", 5)
    useruid=result[:output].chomp

    result=execute_command("id -g #{username}", 5)
    groupid=result[:output].chomp

    #TODO : Set up quota here as well

    Service.create(
        :service_id => message[:service_id],
        :plan_id => message[:plan_id],
        :quota => message[:size],
        :username => username,
        :uid => useruid,
        :gid => groupid
    )
    [true, 'OK']
  rescue => e
    @logger.error "error provisioning: #{e.message}, backtrace: #{e.backtrace}"
    [false, e.message]
  end

  def unprovision(service_id, username)
    # We don't own this service
    return unless Service.exists?(:service_id => service_id)

    @logger.info("Unprovisioning service #{service_id}")

    # we should only get one
    Service.where(service_id: service_id).each do |service|
      raise 'No username found' if username == ''
      execute_command("rm -rf /var/vcap/store/sharedfs/home/#{username}")
      execute_command("userdel #{username}")
    end
    Service.where(service_id: service_id).destroy_all
    [true, 'OK']
  rescue => e
    @logger.error "error uprovisioning: #{e.message}, backtrace: #{e.backtrace}"
    [false, e.message]
  end

  def credentials(service_id)
    # We don't own this service
    return unless Service.exists?(:service_id => :service_id)

    @logger.info("Getting credentials for service: #{service_id}")
    credentials = {}
    begin
      service = Service.where(service_id: :service_id).first
      key = ''
      file = File.new("/var/vcap/store/sharedfs/home/#{service.username}/.ssh/id_rsa", 'r')
      while (line = file.gets)
        key = key + line
      end
      file.close
      credentials = {
          :username => service.username,
          :hostname => $app_settings['agent_dns_address'],
          :host => $app_settings['agent_dns_address'],
          :port => 22,
          :identity => key
      }
      if $app_settings['firewall_allow_rules']
        credentials[:firewall_allow_rules] = $app_settings['firewall_allow_rules'].map { |i| i.to_s }.join(',')
      end

      [true, 'OK', credentials]
    rescue => e
      @logger.error "error getting credentials: #{e.message}, backtrace: #{e.backtrace}"
      [false, e.message, nil]
  end


  private

  # TODO: there must be a nicer way of doing this
  def generate_username
    result = File.open('/dev/urandom') { |x| x.read(16).unpack('H*')[0] }
    m=/(.{10})$/.match(result)
    m[0]
  end


end

end