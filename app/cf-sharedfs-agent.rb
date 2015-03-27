require 'sinatra'
require 'sinatra/reloader' if development?
require 'logger'
require 'eventmachine'
require 'rack/fiber_pool'

class CFSharedFSAgent  < Sinatra::Base

  # register Sinatra::ActiveRecordExtension

  # I think rack fiber pool may well be broken all requests coming in on the same fiber. Comment out for now
  # use Rack::FiberPool, size: 20

  get '/' do
    "CFSharedFS Agent"
  end

end
