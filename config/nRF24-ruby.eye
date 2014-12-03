require "eye-http"

Eye.config do
  http :enable => true, :host => "0.0.0.0", :port => 12345
end


app="nRF24-ruby"
Eye.application "#{app}" do
  working_dir "/var/app/#{app}/current"
  stdall "/var/log/#{app}.log"
  notify :errors
  trigger :flapping, times: 2, within: 1.minute, retry_in: 5.minutes
  check :cpu, every: 10.seconds, below: 100, times: 3 # global check for all processes

  daemon="nRF24_MQTT-SN_client"

  process "#{daemon}" do
    notify :dev
    notify :errors
    auto_start  false
    start_command "sudo ruby ./bin/#{daemon}.rb -S 22 -E 27 --http 8088 --mac 'EE:EE' --dr 1 -vd"
    daemonize true
    pid_file "/tmp/#{daemon}.pid"
  end

  daemon="nRF24_MQTT-SN_bridge"
  process "#{daemon}" do
    notify :dev
    notify :errors
    auto_start  false
    start_command "sudo ruby ./bin/#{daemon}.rb -S 22 -E 27 --id 33 --mac 'EE:EE' --broker udp://20.20.20.21:1883 --dr 1"
    daemonize true
    pid_file "/tmp/#{daemon}.pid"
  end
end
