require 'spec_helper'
require File.join(File.dirname(__FILE__), '../app/', 'cf-sharedfs-agent.rb')

describe CFSharedFSAgent do
  def app
    @app ||= CFSharedFSAgent
  end
  
  before(:all) do
    CFSharedFSAgent.set :logging, false
    CFSharedFSAgent.set :run, false
    CFSharedFSAgent.set :raise_errors, true
    
  end
      
  describe "Root URL" do
    before(:each) do
      get '/'
    end
      
    it 'should return return a 200' do
      expect(last_response.status).to eq(200)
    end
    
    it 'should return "CFSharedFS Agent"' do
      expect(last_response.body).to eq("CFSharedFS Agent")
    end
  end
end
