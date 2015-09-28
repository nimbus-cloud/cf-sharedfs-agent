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
      begin
        execute_command("id #{service.username}")
      rescue CommandFailedError
        recreate_user(service)
      end
    end
  end

  def disk_free
    result = execute_command("df /var/vcap/store | tail -n 1 | awk '{print $4}'")
    result.chomp.to_i
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

    # TODO: Set up quota here as well
    # TODO: Rarely getting very slow commits, the one below took nearly 47 seconds
    # [2015-09-11T08:58:14.051972 #16362] DEBUG -- :   SQL (0.4ms)  INSERT INTO "services" ("service_id", "plan_id", "quota", "username", "uid", "gid") VALUES (?, ?, ?, ?, ?, ?)  [["service_id", "cef52253-b9a0-4707-852d-4ea3d8a065dc"], ["plan_id", "90b3d933-1328-4326-8044-3590eaab394a"], ["quota", "2048"], ["username", "ce57c9bb5f"], ["uid", "1014"], ["gid", "1014"]]
    # [2015-09-11T08:59:00.890311 #16362] DEBUG -- :    (46837.6ms)  commit transaction
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

  def recreate_user(service)
    # this user does not exist lets try and create it.
    # failures here could break the service. but maybe thats not a bad thing
    # if an alert goes out
    # because bosh temp users and these sshfs users share the same uid pools,
    # there maybe a conflict. Consider moving the sshfs uids/guids to their own range
    logger.info "recreating user #{service.username}"
    execute_command("groupadd -g #{service.gid} #{service.username}")
    execute_command("useradd #{service.username} -d /var/vcap/store/sharedfs/home/#{service.username} -s /bin/bash -g #{service.gid} -u #{service.uid} -g #{service.gid}")
  end

  def generate_username
    result = File.open('/dev/urandom') { |x| x.read(16).unpack('H*')[0] }
    m = /(.{10})$/.match(result)
    m[0]
  end


end