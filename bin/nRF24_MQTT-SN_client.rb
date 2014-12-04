#!/usr/bin/env ruby
#encoding: UTF-8

require 'optparse'
require 'yaml'
require "pp"

options = {}
CONF_FILE='/etc/nRF24.conf'

options=options.merge YAML::load_file(CONF_FILE) if File.exist?(CONF_FILE)
options=options.inject({}){|memo,(k,v)| memo[k.to_sym] = v; memo}

options[:cs] = 22 if not options[:cs]
options[:ce] = 27 if not options[:ce]
options[:irq] = 17 if not options[:irq]
options[:local_port] = 5555 if not options[:local_port]
options[:rf_dr] = 0 if not options[:rd_dr]
options[:chan] = 2 if not options[:chan]

OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

  opts.on("-v", "--[no-]verbose", "Run verbosely; creates protocol log on console (false)") do |v|
    options[:verbose] = v
  end
  opts.on("-d", "--[no-]debug", "Produce Debug dump on verbose log (false)") do |v|
    options[:debug] = v
  end

  opts.on("-l", "--localport port", "MQTT-SN local port to listen (5555)") do |v|
    options[:local_port] = v.to_i
  end

  opts.on("-b", "--broker uri", "URI of the MQTT-SN Radio Broker to connect to in format: rad://XX:XX (no default)") do |v|
    options[:broker_uri] = v
  end

  opts.on("-m", "--mac mac", "This radio station's MAC (no default)") do |v|
    options[:mac] = v
  end

  opts.on("-S","--cs n", "RaspberryPi Pin number for nRF24's CS (27)") do |v|
    options[:cs] = v.to_i
  end

  opts.on("--rf n", "nRF24 radio channel number [0..125] (2)") do |v|
    options[:chan] = v.to_i
  end

  opts.on("--dr n", "nRF24 radio Data Rate [1,2] Mbps (2)") do |v|
    options[:rf_dr] = 1 if v.to_i==2
  end

  opts.on("-E","--ce n", "RaspberryPi Pin number for nRF24's CE (22)") do |v|
    options[:ce] = v.to_i
  end

  opts.on("--irq n", "RaspberryPi Pin number for nRF24's IRQ (17)") do |v|
    options[:irq] = v.to_i
  end

  opts.on("-h", "--http port", "Http port for debug/status JSON server (false)") do |v|
    options[:http_port] = v.to_i
  end
end.parse!

pp options

require 'socket'
require 'json'
require 'uri'
require 'ipaddr'
require 'time'
require 'thread'
require 'mqtt-sn-ruby'


local=false
if File.file? './lib/nRF24-ruby.rb'
  require './lib/nRF24-ruby.rb'
  puts "using local lib"
  local=true
else
  require 'nRF24-ruby'
end

puts "\nPure Ruby UDP <-> nRF24 Client  Starting..."

http=true
#http=false

if options[:http_port]
  puts "Loading Http-server.. hold on.."
  require 'minimal-http-ruby'
  if local
    minimal_http_server http_port: options[:http_port], http_path:  './http/'
  else
    minimal_http_server http_port: options[:http_port], http_path:  File.join( Gem.loaded_specs['nRF24-ruby'].full_gem_path, 'http/')
  end
  puts "\n"
end

def open_port uri_s
  begin
    uri = URI.parse(uri_s)
    if uri.scheme== 'udp'
      return [UDPSocket.new,uri.host,uri.port]
    else
      raise "Error: Cannot open socket for '#{uri_s}', unsupported scheme: '#{uri.scheme}'"
    end
  rescue => e
    pp e.backtrace
    raise "Error: Cannot open socket for '#{uri_s}': #{e}"
  end
end

def poll_packet socket
  if socket.class.name=="UDPSocket"
    begin
      r,stuff=socket.recvfrom_nonblock(200) #get_packet --high level func!
      client_ip=stuff[2]
      client_port=stuff[1]
      return [r,client_ip,client_port]
    rescue IO::WaitReadable
      sleep 0.1
    rescue => e
      puts "Error: receive thread died: #{e}"
      pp e.backtrace
    end
  else
    if not socket.recv_q.empty? #get packets from broker's radio and send them to udp broker/forwader
      msg=socket.recv_q.pop
      pac=msg[:msg].pack("c*")
      len=msg[:msg][0]
      if len<1 or len>30
        puts "crap #{msg}"
        return nil
      end
      if msg[:checksum]!=msg[:check]
        puts "checksum error #{msg}"
        return nil
      end
      pac=pac[0...len]
      return [pac,msg[:from],msg[:socket] ]
    end
  end
  return nil
end

def poll_packet_block socket
  #decide how to get data -- UDP-socket or FM-radio
  r,stuff=socket.recvfrom(200) #get_packet --high level func!
  client_ip=stuff[2]
  client_port=stuff[1]
  return [r,client_ip,client_port]
end

def send_raw_packet msg,socket,server,port
  if socket
    if socket.class.name=="UDPSocket"
      socket.send(msg, 0, server, port)
    else
      a=msg.unpack('c*')
      socket.send_q << {msg: a, to: server, socket: port,ack:false}
    end
    #MqttSN::hexdump msg
  else
    puts "Error: no socket at send_raw_packet"
  end
end


r=NRF24.new options.merge(id: :eka, ack: false, mac_header: true)

s=UDPSocket.new
s.bind("0.0.0.0",5555) # our port for clients

puts "Main Loop Starts!:"

loopc=0;
sc=0;

$gateways={}
@active_gw_id=nil
 @gsem=Mutex.new

def add_gateway gw_id,hash
  gw_id=0 if $gateways[0] and $gateways[0][:uri]==hash[:uri] ##this was the default one we found now... keep it as zero key

  if not $gateways[gw_id]
    $gateways[gw_id]={stamp: Time.now.to_i, status: :ok, last_use: 0,last_ping: 0,counter_send:0, last_send: 0,counter_recv:0, last_recv: 0}.merge(hash)
  else
    $gateways[gw_id][:status]=:ok
    if $gateways[gw_id][:uri]!=hash[:uri]
      note "conflict -- gateway has moved? or duplicate"
    else
      $gateways[gw_id][:stamp]=Time.now.to_i
      $gateways[gw_id]=$gateways[gw_id].merge hash
    end
  end
end

def gateway_close cause
  @gsem.synchronize do #one command at a time --

    if @active_gw_id # if using one, mark it used, so it will be last reused
      puts "Closing gw #{@active_gw_id} cause: #{cause}"
      $gateways[@active_gw_id][:last_use]=Time.now.to_i
      #if $gateways[@active_gw_id][:socket]
        #$gateways[@active_gw_id][:socket].close
        #$gateways[@active_gw_id][:socket]=nil
      #end
      @active_gw_id=nil
    end
  end
end

def pick_new_gateway
  begin
    gateway_close nil
    @gsem.synchronize do #one command at a time --
      pick=nil
      pick_t=0
      $gateways.each do |gw_id,data|
        if data[:uri] and data[:status]==:ok
          if not pick or data[:last_use]==0  or pick_t>data[:last_use]
            pick=gw_id
            pick_t=data[:last_use]
          end
        end
      end
      if pick
        @active_gw_id=pick
        NRF24::note "Opening Gateway #{@active_gw_id}: #{$gateways[@active_gw_id][:uri]}"
        #@s,@server,@port = MqttSN::open_port $gateways[@active_gw_id][:uri]
        #$gateways[@active_gw_id][:socket]=@s
        @server_uri=$gateways[@active_gw_id][:uri]
        @server_ip=@server_uri[6..@server_uri.size]
        puts "macccc #{@server_ip}"
        $gateways[@active_gw_id][:last_use]=Time.now.to_i
      else
        puts "Error: no usable gw found !!"
      end
    end
  rescue => e
    puts "Error: receive thread died: #{e}"
    pp e.backtrace
  end
  return @active_gw_id
end


#CLIENT HERE
#@server_uri=options[:broker_uri]
#add_gateway(0,{uri: options[:broker_uri],source: "default"})
#pick_new_gateway
pp $gateways
MAX_IDLE=60
Thread.new do #maintenance
  loop do
    begin
      sleep 1
      now=Time.now.to_i
      changes=false
      $gateways.dup.each do |key,data|
        if data[:stamp]<now-MAX_IDLE and data[:status]==:ok
          puts "***********************************gw lost #{key} #{data},#{now}"
          $gateways[key][:status]=:fail
          if key==@active_gw_id
            gateway_close "timeout"
          end
        end
      end

    rescue => e
      puts "Error: maintenance thread died: #{e}"
      pp e.backtrace
    end
  end
end

loop do
  begin
    if not @active_gw_id or not $gateways[@active_gw_id]
      puts "No active gw, wait ."
      if  not ret=pick_new_gateway
        sleep 0.5
        print "."
        while poll_packet(s) do
          #waste these.. congestion error ?
        end
      end

    elsif pac=poll_packet(s)
      msg,@client_ip,@client_port=pac
      m=MqttSN::parse_message msg
      puts "UDP(#{@client_ip}:#{@client_port})->RAD(#{@server_ip}:#{3}): #{m}"
      send_raw_packet msg,r,@server_ip,3
    end

    if pac=poll_packet(r)
      msg,client_ip,client_port=pac
      m=MqttSN::parse_message msg
      puts "RAD(#{client_ip}:#{client_port})->UDP(#{@client_ip}:#{@client_port}): #{m}"
      if client_port==:broadcast
        gw_id=m[:gw_id]
        duration=m[:duration]||180
        uri="rad://#{client_ip}"
        add_gateway(gw_id,{uri: uri, source: m[:type], duration:duration,stamp: Time.now.to_i})
        now=Time.now.to_i
        $gateways.each do |k,v|
          puts "gw: #{k} , #{now-v[:stamp]}, #{v[:uri]}, #{v[:status]}"
        end
      else
        send_raw_packet msg,s,@client_ip,@client_port
      end
    end

  rescue => e
      puts "Error: receive thread died: #{e}"
      pp e.backtrace
  end
  sleep 0.01
end

