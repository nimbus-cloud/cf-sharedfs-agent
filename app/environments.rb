require 'logger'
require 'yaml'
require 'bunny'
require 'json'
require 'net/http'

configure :test do
  $logger = Logger.new("/dev/null")
end

configure :development, :production do
  $logger = Logger.new(STDOUT)
  STDOUT.sync = true
end

configure do

  $master_fiber = Fiber.current

  original_formatter = Logger::Formatter.new
  $logger.formatter = proc do |severity, datetime, progname, msg|
    Fiber.current.to_s =~ /(\S\S\S\S\S)>$/
    "#{Fiber.current == $master_fiber?"MASTER":$1}: #{original_formatter.call(severity, datetime, progname, msg.dump)}"
  end

  $logger.info("==========================")
  $logger.info("cf-sharedfs agent starting")
  $logger.info("==========================")


  settings_filename = ENV['SETTINGS_FILENAME'] ? ENV['SETTINGS_FILENAME'] : File.dirname(__FILE__) + '/../config/settings.yml'
  $logger.info("Loading settings file #{settings_filename}")
  $app_settings ||= YAML.load_file(settings_filename)

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

end
