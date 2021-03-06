require 'sinatra'
require 'logger'
require 'sinatra/activerecord'

require_relative 'models/service'
require_relative 'user_provisioner'

$stdout.sync = true
$stderr.sync = true
$logger = Logger.new($stdout)

class CFSharedFSAgent < Sinatra::Base

  register Sinatra::ActiveRecordExtension

  use Rack::CommonLogger, $logger

  configure :development do
    set :database, 'sqlite3:db/development.sqlite3'
  end

  configure :production do
    set :database, 'sqlite3:/var/vcap/store/sharedfs/sharedfs.sqlite3'
  end

  configure do
    $logger.info('*==========================*')
    $logger.info('*cf-sharedfs agent starting*')
    $logger.info('*==========================*')

    settings_filename = ENV['SETTINGS_FILENAME'] ? ENV['SETTINGS_FILENAME'] : File.dirname(__FILE__) + '/../config/settings.yml'
    $logger.info("Loading settings file #{settings_filename}")
    $app_settings ||= YAML.load_file(settings_filename)

    set :service, UserProvisioner.new($logger, $app_settings)

    ActiveRecord::Base.logger = Logger.new($stdout)

    $logger.info 'verifying existing users...'
    settings.service.verify_users_exist!
    $logger.info 'started!'
  end

  before do
    content_type :json
  end

  after do
    ActiveRecord::Base.connection_pool.disconnect!
  end

  get '/' do
    {:msg => 'Cloud Foundry Proxy Broker'}.to_json
  end


  get '/' do
    {
        :msg => "CFSharedFS Agent #{agent_name}"
    }.to_json
  end

  get '/discover' do
    disk_free = service.disk_free

    {
        :disk_free => disk_free
    }.to_json
  end

  put '/provision/:service_id/:plan_id/:size' do |service_id, plan_id, size|
    $logger.info "provisioning service: #{service_id}, plan: #{plan_id}, size: #{size}"
    success, msg = service.provision(service_id, plan_id, size)

    {
        success: success,
        :msg => msg
    }.to_json
  end

  delete '/unprovision/:service_id' do |service_id|
    $logger.info "unprovisioning service: #{service_id}"
    success, msg = service.unprovision(service_id)

    {
        :success => success,
        :msg => msg
    }.to_json
  end

  get '/credentials/:service_id' do |service_id|
    $logger.info "getting credentials for service: #{service_id}"
    success, msg, credentials = service.credentials(service_id)

    {
        :success => success,
        :msg => msg,
        :credentials => credentials
    }.to_json
  end

  private

  def service
    settings.service
  end

  def agent_name
    $app_settings['agent_name']
  end

end