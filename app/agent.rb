require 'faraday'
require 'em-synchrony/em-http'
require 'json'
require 'bunny'
require 'eventmachine'

class Agent

  def initialize(logger)
    @logger = logger
    @modules = []
  end

  def start_in_fiber
    Fiber.new { start }.resume
  end

  def start
    @logger.debug "Event machine starting."
    @logger.info "connecting to rabbitmq..."
    create_rabbit_mq_connection
    @logger.info "...success"

  end

  def create_rabbit_mq_connection
    @rabbit_conn = Bunny.new($amqp_url)
    @rabbit_conn.start
    @rabbit_ch = @rabbit_conn.create_channel
  end

end

