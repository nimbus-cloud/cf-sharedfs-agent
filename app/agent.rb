require 'faraday'
require 'json'
require 'bunny'
require 'eventmachine'
require "sinatra/activerecord"

require_relative 'models/service'

class Agent

  def initialize(logger)
    @logger = logger
  end

  def start_in_fiber

    # deliberately block startup until this call is successful
    $logger.info("Getting rabbitmq details")
    status = 0
    while status.to_i != 200 do
      uri = URI.parse("#{$app_settings['broker_end_point']}/rabbitdetails")
      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Get.new(uri.request_uri)
      request.basic_auth($app_settings['broker_username'], $app_settings['broker_password'])
      response = http.request(request)
      status = response.code
      if status.to_i == 200
        json = JSON.parse(response.body)
        $amqp_url = json['amqp_url']
        break
      end
      sleep(1)
      $logger.info("Retrying to get rabbit info... #{status}")
    end

    $logger.info("Got rabbitmq details")

    Fiber.new { start() }.resume
  end

  def start
    @logger.debug "Event machine starting."
    @logger.info "connecting to rabbitmq..."
    create_rabbit_mq_connection
    verify_users_exist
    @logger.info "...success"

    EM.next_tick() { em_fibered_start { send_announcement() } }
    EM.add_periodic_timer(60) { em_fibered_start { send_announcement() } }

    @rabbit_broker_annoucement_queue.subscribe() do |delivery_info, properties, message|
      EM.next_tick() { em_fibered_start { process_broker_message(delivery_info, properties, message) } }
    end
  end

  def em_fibered_start
    Fiber.new {
      begin
        yield
      rescue Exception => e
        @logger.error("Fibered execution failed \"#{e.message}\"\n#{e.backtrace}")
      end
    }.resume
  end

  def create_rabbit_mq_connection
    @rabbit_conn = Bunny.new($amqp_url)
    @rabbit_conn.start
    @rabbit_ch = @rabbit_conn.create_channel
    @rabbit_agent_announcement_exch = @rabbit_ch.fanout("cf_sharedfs_agent_announcement")
    @rabbit_broker_annoucement_exch = @rabbit_ch.fanout("cf_sharedfs_broker_announcement")
    @rabbit_broker_annoucement_queue = @rabbit_ch.queue("", :auto_delete => true, :exclusive => true)
    @rabbit_broker_annoucement_queue.bind(@rabbit_broker_annoucement_exch)
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

  def process_broker_message(delivery_info, properties, message)
    parsed_message = JSON.parse(message, :symbolize_names => true)
    parsed_message[:type] or raise "Unknown type for message #{message}"
    if parsed_message[:type] == "startup"
      @logger.debug("Received broker startup")
      send_announcement()
    elsif parsed_message[:type] == "discover"
      discover(properties, parsed_message)
    elsif parsed_message[:type] == "provision"
      provision(properties, parsed_message)
    elsif parsed_message[:type] == "unprovision"
      unprovision(properties, parsed_message)
    elsif parsed_message[:type] == "get_credentials"
      get_credentials(properties, parsed_message)
    else
      raise "Unknown message type for #{message}"
    end
  end

  def send_announcement
    @logger.debug("Sending announcement for #{$app_settings['agent_name']}")
    @rabbit_agent_announcement_exch.publish({:type => 'hereiam', :name=>$app_settings['agent_name']}.to_json, :expiration => "60000")
  end

  def discover(properties, message)
    @logger.debug("Recevied discover. Sending back usage info")
    queue = @rabbit_ch.queue(properties.reply_to, :auto_delete => true)
    queue.publish({:name => $app_settings['agent_name'], :disk_size => "10000", :disk_free => "1000", :cpu_load => "1000"}.to_json, :expiration => "20000")
  end

  def provision(properties, message)
    return unless message[:node] == $app_settings['agent_name']
    @logger.info("Provisioning on my node from #{message.to_s}")
    success = false
    msg = ""
    begin
      username=generate_username
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
      success = true
    rescue Exception => e
      msg = e.message
      raise e
    ensure
      queue = @rabbit_ch.queue(properties.reply_to, :auto_delete => true)
      queue.publish({:name => $app_settings['agent_name'], success: success, :msg => msg}.to_json, :expiration => "20000")
    end
  end

  def unprovision(properties, message)
    # We don't own this service
    return unless Service.exists?(:service_id => message[:service_id])

    @logger.info("Unprovisioning on my node from: #{message.to_s}")
    success = false
    msg = ""
    begin
      # we should only get one
      Service.where(service_id: message[:service_id]).each do |service|
         raise "No username found" if service.username == ""
         execute_command("rm -rf /var/vcap/store/sharedfs/home/#{service.username}")
         execute_command("userdel #{service.username}")
      end
      Service.where(service_id: message[:service_id]).destroy_all
      success = true
    rescue Exception => e
      msg = e.message
      raise e
    ensure
      queue = @rabbit_ch.queue(properties.reply_to, :auto_delete => true)
      queue.publish({:name => $app_settings['agent_name'], :success => success, :msg => msg}.to_json, :expiration => "20000")
    end
  end

  def get_credentials(properties, message)
    # We don't own this service
    return unless Service.exists?(:service_id => message[:service_id])
    @logger.info("Returning credentials after receiving: #{message.to_s}")
    success = false
    msg = ""
    credentials = {}
    begin
      service = Service.where(service_id: message[:service_id]).first
      key = ""
      @logger.debug("reading key")
      file = File.new("/var/vcap/store/sharedfs/home/#{service.username}/.ssh/id_rsa", "r")
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
      @logger.debug("Credentials are #{credentials.to_s}")
      success = true
    rescue Exception => e
      msg = e.message
      raise e
    ensure
      @logger.debug("Creating response queue #{properties.reply_to}")
      queue = @rabbit_ch.queue(properties.reply_to, :auto_delete => true)
      @logger.debug("Publish to response queue: #{{:name => $app_settings['agent_name'], :success => success, :msg => msg, :credentials => credentials}.to_json}")
      queue.publish({:name => $app_settings['agent_name'], :success => success, :msg => msg, :credentials => credentials}.to_json, :expiration => "20000")
      @logger.debug("Publish finished")
    end
  end

  def generate_username
    result = File.open('/dev/urandom') { |x| x.read(16).unpack('H*')[0] }
    m=/(.{10})$/.match(result)
    m[0]
  end












  # TODO But all this fibered command execution is a ruby gem

  def execute_command(command, timeout = nil, flog = nil)
    hash = {}
    hash[:command] = command
    (timeout) and hash[:timeout] = timeout
    (flog) and hash[:logging] = flog
    result=execute_command_hash(hash)
    result[:status]!=0 and raise ("Command execution failed.\nCommand:#{command}.Output:#{result[:output]}\n")
    result
  end

  def execute_command_hash(hash)
    hash[:command] or raise("No command passed in")
    hash[:logging] or hash[:logging] = @logger
    hash[:tries] or hash[:tries] = 1
    result={}
    result[:status] = 1
    f = Fiber.current
    attempt=1
    while (attempt<=hash[:tries] and result[:status]!=0)
      if (f.equal?($master_fiber))
        result = execute_command_non_fibered(hash)
      else
        result = execute_command_fibered(hash)
      end
      attempt = attempt + 1
      if attempt<=hash[:tries] and result[:status]!=0
        hash[:logging].debug("Command Failed with #{result[:output]}. Attempt #{attempt}. Sleeping for 2 secs then trying again...")
        mysleep(2)
      end
    end
    result
  end

  def mysleep(time)
    f = Fiber.current
    if (f.equal?(@root_fiber))
      sleep(time)
    else
      EM.add_timer(time) do
        f.resume
      end
      Fiber.yield
    end
  end

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

