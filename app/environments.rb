require 'logger'
require 'yaml'
require 'bunny'
require 'json'
require 'net/http'

configure :development do
  set :database, 'sqlite3:db/development.sqlite3'
end

configure :production do
  set :database, 'sqlite3:/var/vcap/store/sharedfs/sharedfs.sqlite3'
end

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

end
