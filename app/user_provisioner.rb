require_relative 'command_runner'

class UserProvisioner

  include CommandRunner

  attr_reader :logger, :config

  def initialize(logger, config)
    @logger = logger
    @config = config
  end

  def verify_users_exist!
    Service.all.each do |service|
      results = execute_command("id #{service.username}")
      if results[:status] != 0
        # this user does not exist lets try and create it.
        # failures here could break the service. but maybe thats not a bad thing
        # if an alert goes out
        # because bosh temp users and these sshfs users share the same uid pools,
        # there maybe a conflict. Consider moving the sshfs uids/guids to their own range
        execute_command("groupadd -g #{service.gid} #{service.username}")
        execute_command("useradd #{service.username} -d /var/vcap/store/sharedfs/home/#{service.username} -s /bin/bash -g #{service.gid} -u #{service.uid} -g #{service.gid}")
      end
    end
  end


  def provision(service_id, plan_id, size)
    username = generate_username
    execute_command("mkdir -p /var/vcap/store/sharedfs/home/#{username}/.ssh")
    execute_command("mkdir -p /var/vcap/store/sharedfs/home/#{username}/data")
    execute_command("useradd #{username} -d /var/vcap/store/sharedfs/home/#{username} -s /bin/bash")
    execute_command("chown -R #{username}:#{username} /var/vcap/store/sharedfs/home/#{username}")
    execute_command("chmod g-rwx /var/vcap/store/sharedfs/home/#{username}")
    execute_command("chmod o-rwx /var/vcap/store/sharedfs/home/#{username}")
    execute_command("su - #{username} -c 'ssh-keygen -q -N \"\" -f /var/vcap/store/sharedfs/home/#{username}/.ssh/id_rsa'")
    execute_command("mv /var/vcap/store/sharedfs/home/#{username}/.ssh/id_rsa.pub /var/vcap/store/sharedfs/home/#{username}/.ssh/authorized_keys")

    result = execute_command("id -u #{username}")
    useruid = result.chomp
    result = execute_command("id -g #{username}",)
    groupid = result.chomp

    #TODO : Set up quota here as well
    Service.create(
        :service_id => service_id,
        :plan_id => plan_id,
        :quota => size,
        :username => username,
        :uid => useruid,
        :gid => groupid
    )
    [true, 'OK']
  rescue => e
    logger.error "error provisioning: #{e.message}, backtrace: #{e.backtrace}"
    [false, e.message]
  end

  def unprovision(service_id)

    unless Service.exists?(:service_id => service_id)
      return [false, "Service #{service_id} not found"]
    end

    logger.info("Unprovisioning service #{service_id}")

    # we should only get one
    Service.where(service_id: service_id).each do |srv|
      raise "Empty username for service_id: #{service_id}" if srv.username.nil? || srv.username == ''
      execute_command("rm -rf /var/vcap/store/sharedfs/home/#{srv.username}")
      execute_command("userdel #{srv.username}")
    end

    Service.where(service_id: service_id).destroy_all

    [true, 'OK']
  rescue => e
    logger.error "error uprovisioning: #{e.message}, backtrace: #{e.backtrace}"
    [false, e.message]
  end

  def credentials(service_id)

    unless Service.exists?(:service_id => service_id)
      return [false, "Service #{service_id} not found", nil]
    end

    logger.info("Getting credentials for service: #{service_id}")

    service = Service.where(:service_id => service_id).first
    key = File.read("/var/vcap/store/sharedfs/home/#{service.username}/.ssh/id_rsa")
    credentials = {
        :username => service.username,
        :hostname => config['agent_dns_address'],
        :host => config['agent_dns_address'],
        :port => 22,
        :identity => key,
        :firewall_allow_rules => config['firewall_allow_rules'].map { |i| i.to_s }.join(',')
    }

    [true, 'OK', credentials]
  rescue => e
    logger.error "error getting credentials: #{e.message}, backtrace: #{e.backtrace}"
    [false, e.message, nil]
  end

  private

  def generate_username
    result = File.open('/dev/urandom') { |x| x.read(16).unpack('H*')[0] }
    m = /(.{10})$/.match(result)
    m[0]
  end


end