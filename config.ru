dir = File.dirname(__FILE__)
require File.join(dir, 'app/cf-sharedfs-agent')
require File.join(dir, 'app/agent')
require File.join(dir, 'app/environments')

run Rack::URLMap.new("/" => CFSharedFSAgent.new)

EM.schedule do
  $agent = Agent.new($logger)
  $agent.start_in_fiber

end
