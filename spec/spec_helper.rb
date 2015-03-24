ENV['RACK_ENV'] = 'test'

require 'rack/test'


def with_event_machine(options = {})
  raise "no block given" unless block_given?
  timeout = options[:timeout] ||= 10

  ::EM.epoll

  ::EM.run do
    quantum = 0.005
    ::EM.set_quantum(quantum * 1000) # Lowest possible timer resolution
    ::EM.set_heartbeat_interval(quantum) # Timeout connections asap
    ::EM.add_timer(timeout) { raise "timeout" }

    yield
  end
end

def done
  raise "reactor not running" if !::EM.reactor_running?

  ::EM.next_tick {
    # Assert something to show a spec-pass
    :done.should == :done
    ::EM.stop_event_loop
  }
end

RSpec.configure do |config|
  config.include Rack::Test::Methods

  # Too much conflicting information on the internet about rspec
  config.mock_with :rspec do |c|
    c.syntax = [:should, :expect]
  end
  config.expect_with :rspec do |c|
    c.syntax = [:should, :expect]
  end
  
end
