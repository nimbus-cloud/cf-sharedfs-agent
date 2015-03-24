require 'spec_helper'
require 'logger'
require File.join(File.dirname(__FILE__), '../app/', 'agent.rb')
require_relative 'support/bunny_mock'
require "rspec/em"
require "em-synchrony"



describe Agent do
  
  before(:all) do
    $logger = Logger.new("/dev/null")
    #$logger = Logger.new(STDOUT)
    $app_settings = {}
  end
  
  describe "Startup" do 
  
    before(:each) do
      $amqp_url="fake"
      @bunny_mock = BunnyMock.new
      Bunny.stub(:new).and_return(@bunny_mock)
      @agent = Agent.new($logger)
      
    end
    
    
  end
end
