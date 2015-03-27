require 'faraday'
require 'em-synchrony/em-http'
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

    Fiber.new { start }.resume
  end

  def start
    @logger.debug "Event machine starting."
    @logger.info "connecting to rabbitmq..."
    create_rabbit_mq_connection
    @logger.info "...success"

    EM.next_tick() { em_fibered_start { send_announcement() } }
    EM.add_periodic_timer(60) { em_fibered_start { send_announcement() } }

    @rabbit_broker_annoucement_queue.subscribe() do |delivery_info, properties, message|
      em_fibered_start { process_broker_message(delivery_info, properties, message) }
    end
  end

  def em_fibered_start
    Fiber.new {
      begin
        yield
      rescue Exception => e
        @logger.error("Fibered execution failed \"#{e.message}\"\n#{e.backtrace}")
        raise e
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

  def process_broker_message(delivery_info, properties, message)
    parsed_message = JSON.parse(message, :symbolize_names => true)
    parsed_message[:type] or raise "Unknown type for message #{message}"
    if parsed_message[:type] == "startup"
      @logger.debug("Received broker startup")
      send_announcement()
    elsif parsed_message[:type] == "sharedfs.discover"
      discover(properties, parsed_message)
    elsif parsed_message[:type] == "provision"
      provision(message)
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
    queue.publish({:name => $app_settings['agent_name'], :disk_size => "10000", :disk_free => "1000", :cpu_load => "1000"}.to_json, :expiration => "8000")
  end

  def provision(message)
    return unless message[:node] == $app_settings['agent_name']
  end

end

