require 'rspec'
require 'rack/test'
require 'rspec/mocks'
require 'json'

DIR = File.dirname(__FILE__)

RSpec.shared_context :rack_test do
  include Rack::Test::Methods

  def app
    Rack::Builder.parse_file("#{DIR}/../config.ru").first
  end

  def resp_hash
    JSON.parse(last_response.body)
  end

end


