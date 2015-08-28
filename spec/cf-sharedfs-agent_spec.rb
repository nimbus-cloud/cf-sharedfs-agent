require 'fileutils'

require_relative '../app/cf-sharedfs-agent'

#  RUNNING THIS SPEC
# install rbenv sudo plugin: https://github.com/dcarley/rbenv-sudo
# run specs with: rbenv sudo rspec

describe 'sharedfs agent routes' do

  include_context :rack_test

  before(:each) do
    Service.delete_all
    FileUtils.mkdir_p '/var/vcap/store'
  end

  after(:each) do
    Service.delete_all
    Dir['/var/vcap/store/sharedfs/home/*'].select {|f| File.directory? f}.map{|d| File.basename d}.each{|u| `userdel -r #{u}`}
    FileUtils.rm_rf '/var/vcap'
  end

  it 'test route "/"' do
    get '/'

    expect(last_response).to be_ok
    expect(resp_hash['msg']).to eq 'CFSharedFS Agent'
  end

  it 'discover route "/discover"' do
    get '/discover'

    expect(last_response).to be_ok
    expect(resp_hash['name']).to eq 'cf-sharedfs-l1-01_0'
    expect(resp_hash['disk_free'].is_a? Integer).to eq true
    expect(resp_hash['disk_free'] > 0).to eq true
  end

  it 'provision route "/provision/:service_id/:plan_id/:size"' do
    get '/provision/123/456/7'

    expect(last_response).to be_ok
    expect(resp_hash['success']).to eq true
    expect(resp_hash['name']).to eq 'cf-sharedfs-l1-01_0'
    expect(resp_hash['msg']).to eq 'OK'
  end

  context 'unprovision route /unprovision/:service_id' do

    it 'returns false when service does not exist' do
      get '/unprovision/123'

      expect(last_response).to be_ok
      expect(resp_hash['success']).to eq false
      expect(resp_hash['name']).to eq 'cf-sharedfs-l1-01_0'
      expect(resp_hash['msg']).to eq 'Service 123 not found'
    end

    it 'returns true when service exist' do
      get '/provision/123/456/7'

      get '/unprovision/123'

      expect(last_response).to be_ok
      expect(resp_hash['success']).to eq true
      expect(resp_hash['name']).to eq 'cf-sharedfs-l1-01_0'
      expect(resp_hash['msg']).to eq 'OK'
    end

  end

  context 'credentials route /credentials/:service_id' do

    it 'returns false when service does not exist' do
      get '/credentials/123'

      expect(last_response).to be_ok
      expect(resp_hash['success']).to eq false
      expect(resp_hash['name']).to eq 'cf-sharedfs-l1-01_0'
      expect(resp_hash['msg']).to eq 'Service 123 not found'
      expect(resp_hash['credentials']).to eq nil
    end

    it 'returns true when service exist' do
      get '/provision/123/456/7'

      get '/credentials/123'

      expect(last_response).to be_ok
      expect(resp_hash['success']).to eq true
      expect(resp_hash['name']).to eq 'cf-sharedfs-l1-01_0'
      expect(resp_hash['msg']).to eq 'OK'

      service = Service.where(:service_id => '123').first
      credentials = resp_hash['credentials']

      expect(credentials['username']).to eq service.username
      expect(credentials['hostname']).to eq 'dnsname1.somesite.com'
      expect(credentials['host']).to eq 'dnsname1.somesite.com'
      expect(credentials['port']).to eq 22
      expect(credentials['identity']).to eq(File.read("/var/vcap/store/sharedfs/home/#{service.username}/.ssh/id_rsa"))
    end

  end

  context 'user provisioner service - verify_users_exist!' do

    it 'does nothing when there are no services' do
      app.new.settings.service.verify_users_exist!
    end

    context 'when a vm has been recreated' do

      it 'recreates users on startup ' do
        # create the service, get the user
        app.new.settings.service.provision '123', '456', '7'
        _, _, creds = app.new.settings.service.credentials '123'

        # delete user without removing home folder
        `userdel #{creds[:username]}`

        # verify users
        app.new.settings.service.verify_users_exist!

        # check the user is there
        `id #{creds[:username]}`
         expect($?.to_i).to eq 0

        # and identity stays the same
        home_folder = `eval echo ~#{creds[:username]}`.chomp
        expect(creds[:identity]).to eq(File.read("#{home_folder}/.ssh/id_rsa"))
      end

    end

  end

end