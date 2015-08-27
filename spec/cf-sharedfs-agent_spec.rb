
#  RUNNING THIS SPEC
# create folder /var/vcap TODO: add this to test setup
# install rbenv sudo plugin: https://github.com/dcarley/rbenv-sudo
# run specs with: rbenv sudo rspec

describe 'sharedfs agent routes' do

  include_context :rack_test

  it 'test route "/"' do
    get '/'

    expect(last_response).to be_ok
    expect(resp_hash['msg']).to eq 'CFSharedFS Agent'
  end

  it 'discover route "/discover"' do
    get '/discover'

    expect(last_response).to be_ok
    expect(resp_hash['name']).to eq 'uniquename1'
    # TODO: disk size, cpu
  end

  it 'provision route "/provision/:service_id/:plan_id/:size"' do
    get '/provision/123/456/7'

    expect(last_response).to be_ok
    expect(resp_hash['success']).to eq true
    expect(resp_hash['name']).to eq 'uniquename1'
    expect(resp_hash['msg']).to eq 'abc'
  end



    # it 'allows access to O2 ip address' do
    #   header 'x-lb-forwarded-for', '93.174.159.102%10'
    #   get '/home/sky-at-the-o2/idnv/index'
    #
    #   expect(last_response).to be_ok
    # end
    #
    # it 'denies access to anything else' do
    #   header 'x-lb-forwarded-for', '10.65.93.21'
    #   get '/home/sky-at-the-o2/idnv/index'
    #
    #   expect(last_response).to_not be_ok
    #   expect(last_response.status).to eq 401
    # end




end