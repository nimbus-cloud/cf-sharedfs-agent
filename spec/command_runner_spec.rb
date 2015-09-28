require 'logger'

require_relative '../app/command_runner'

class Test

  attr_reader :logger

  def initialize
    @logger = Logger.new($stdout)
  end

end

describe CommandRunner do

  let(:runner) do
    Test.new.extend CommandRunner
  end

  it 'returns output' do
    expect(runner.execute_command("echo 'Hello World'").strip).to eq 'Hello World'
  end

  it 'throws error when command return status is != 0' do
    expect{runner.execute_command('doesnotexits')}.to raise_error(CommandFailedError)
  end

  context 'timeout' do

    before(:all) do
      ENV['TIMEOUT_OVERRIDE'] = '1'
    end

    after(:all) do
      ENV['TIMEOUT_OVERRIDE'] = nil
    end

    it 'throws error when command times out' do
      expect{runner.execute_command('sleep 2')}.to raise_error(RuntimeError, /Command "sleep 2" timed out, PID: .*/)
    end
  end


end