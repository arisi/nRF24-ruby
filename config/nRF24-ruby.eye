require "eye-http"

Eye.config do
  http :enable => true, :host => "0.0.0.0", :port => 12345
end


daemon="nRF24_MQTT-SN_client"

Eye.application "#{daemon}" do
  working_dir "/var/app/nRF24-ruby/current"
  stdall "/var/log/#{daemon}.log"
  notify :errors
  trigger :flapping, times: 2, within: 1.minute, retry_in: 5.minutes
  check :cpu, every: 10.seconds, below: 100, times: 3 # global check for all processes
  process "#{daemon}" do
    notify :dev
    notify :errors
    auto_start  false
    start_command "ruby ./bin/#{daemon}.rb "
    daemonize true
    pid_file "/tmp/#{daemon}.pid"
  end
end

daemon="nRF24_MQTT-SN_bridge"

Eye.application "#{daemon}" do
  working_dir "/var/app/nRF24-ruby/current"
  stdall "/var/log/#{daemon}.log"
  notify :errors
  trigger :flapping, times: 2, within: 1.minute, retry_in: 5.minutes
  check :cpu, every: 10.seconds, below: 100, times: 3 # global check for all processes
  process "#{daemon}" do
    notify :dev
    notify :errors
    auto_start  false
    start_command "ruby ./bin/#{daemon}.rb "
    daemonize true
    pid_file "/tmp/#{daemon}.pid"
  end
end
