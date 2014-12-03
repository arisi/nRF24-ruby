#!/usr/bin/env ruby
#encoding: UTF-8

require 'optparse'
require 'yaml'
require "pp"

options = {}

options=options.merge YAML::load_file('/etc/nRF24.conf')
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
  opts.on("-b", "--broker uri", "URI of the MQTT-SN Broker to connect to (udp://localhost:1883)") do |v|
    options[:broker_uri] = v
  end
  opts.on("-m", "--mac mac", "This radio station's MAC (AA:AA)") do |v|
    options[:mac] = v
  end

  opts.on("-i", "--id GwId", "MQTT-SN gw_id of this Station (111)") do |v|
    options[:gw_id] = v.to_i
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


require "pp"
pp options

if  not options[:gw_id]
  puts "Error: gw_id must be specified!"
  exit -1
end


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

puts "\nPure Ruby nRF24 <-> UDP MQTT-SN Bridge Starting..."


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

loopc=0;
sc=0;

def poll_packet_radio r
  if not r.recv_q.empty? #get packets from broker's radio and send them to udp broker/forwader
    msg=r.recv_q.pop
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
    #puts "got #{msg}, '#{pac}'"
    return [pac,msg[:from],msg[:socket] ]
  end
  return nil
end



@gateways={}
@active_gw_id=nil
@gsem=Mutex.new

def add_gateway gw_id,hash
  if not @gateways[gw_id]
     @gateways[gw_id]={stamp: Time.now.to_i, status: :ok, last_use: 0,last_ping: 0,counter_send:0, last_send: 0,counter_recv:0, last_recv: 0}.merge(hash)
  else
    @gateways[gw_id][:status]=:ok
    if @gateways[gw_id][:uri]!=hash[:uri]
      puts "conflict -- gateway has moved? or duplicate"
    else
      @gateways[gw_id][:stamp]=Time.now.to_i
      @gateways[gw_id]=@gateways[gw_id].merge hash
    end
  end
end

def gateway_close cause
  @gsem.synchronize do #one command at a time --

    if @active_gw_id # if using one, mark it used, so it will be last reused
      puts "Closing gw #{@active_gw_id} cause: #{cause}"
      @gateways[@active_gw_id][:last_use]=Time.now.to_i
      if @gateways[@active_gw_id][:socket]
        @gateways[@active_gw_id][:socket].close
        @gateways[@active_gw_id][:socket]=nil
      end
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
      @gateways.each do |gw_id,data|
        if data[:uri] and data[:status]==:ok
          if not pick or data[:last_use]==0  or pick_t>data[:last_use]
            pick=gw_id
            pick_t=data[:last_use]
          end
        end
      end
      if pick
        @active_gw_id=pick
        NRF24::note "Opening Gateway #{@active_gw_id}: #{@gateways[@active_gw_id][:uri]}"
        #@s,@server,@port = MqttSN::open_port @gateways[@active_gw_id][:uri]
        #@gateways[@active_gw_id][:socket]=@s
        @gateways[@active_gw_id][:last_use]=Time.now.to_i
      else
        #note "Error: no usable gw found !!"
      end
    end
  rescue => e
    puts "Error: receive thread died: #{e}"
    pp e.backtrace
  end
  return @active_gw_id
end


@bcast_mac="45:45:45"
@bcast_period=20


puts "Gateway Main Loop Starts:"
### gateway!!!
@clients={}
MAX_IDLE=120

#this needs to be Class...
def forwarder r0, hash={}
  add_gateway(0,{uri: hash[:broker_uri],source: "default"})
  pick_new_gateway
  pp @gateways
  uri = URI.parse(hash[:broker_uri])
  if uri.scheme== 'udp'
    @broker_host=uri.host
    @broker_port=uri.port
  else
    raise "Error: Cannot open socket for '#{hash[:broker_uri]}', unsupported scheme: '#{uri.scheme}'"
  end

  last_kill=0
  stime=Time.now.to_i
  Thread.new do
    loop do
      begin
        msg=[MqttSN::ADVERTISE_TYPE,hash[:gw_id],@bcast_period>>8,@bcast_period&0xff]
        r = MqttSN::build_packet msg
        send_raw_packet r,r0,@bcast_mac,0
        puts "adv: #{msg} "
        sleep @bcast_period
      rescue => e
        puts "Error: receive thread died: #{e}"
        pp e.backtrace
      end
    end
  end

  Thread.new do #maintenance
    loop do
      begin
        sleep 1
        now=Time.now.to_i
        changes=false
        @gateways.dup.each do |key,data|
          if data[:stamp]<now-MAX_IDLE and data[:status]==:ok
            puts "***********************************gw lost #{key} #{data},#{now}"
            @gateways[key][:status]=:fail
            if key==@active_gw_id
              gateway_close "timeout"
            end
          end
        end
        @clients.dup.each do |key,data|
          if data[:state]==:disconnected
            dest="#{data[:ip]}:#{data[:port]}"
            NRF24::note "- %s",dest
            @clients.delete key
            changes=true
          elsif data[:last_send]<now-MAX_IDLE and data[:last_recv]<now-MAX_IDLE
            dest="#{data[:ip]}:#{data[:port]}"
            NRF24::note "-- %s",dest
            kill_client key
            @clients.delete key
            changes=true
          end
        end
        if changes
          NRF24::note "cli:#{@clients.to_json}"
          puts "cli:#{@clients.to_json}"
        end
      rescue => e
        puts "Error: maintenance thread died: #{e}"
        pp e.backtrace
      end
    end
  end

  loop do
    begin
      if pac=poll_packet_radio(r0)
        r,client_ip,client_port=pac
        key="#{client_ip}:#{client_port}"
        if not @clients[key]
          if client_port== :broadcast
            m=MqttSN::parse_message r
            gw_id=m[:gw_id]
            duration=m[:duration]||180
            uri="rad://#{client_ip}"
            add_gateway(gw_id,{uri: uri, source: m[:type], duration:duration,stamp: Time.now.to_i})
            now=Time.now.to_i
            #@gateways.each do |k,v|
            #  puts "gw: #{k} , #{now-v[:stamp]}, #{v[:uri]}"
            #end
            next
          end
          uri="rad://#{client_ip}:#{client_port}"
          @clients[key]={ip:client_ip, port:client_port, socket: UDPSocket.new, uri: uri, state: :active, counter_send:0, last_send:0 , counter_recv:0, last_recv:0}
          c=@clients[key]
          #puts "thread start for #{key}"

          @clients[key][:thread]=Thread.new(key) do |my_key|
            while true
              pacc=MqttSN::poll_packet_block(@clients[my_key][:socket]) #if we get data from server destined to our client
              rr,client_ip,client_port=pacc
              #@s.send(rr, 0, @clients[my_key][:ip], @clients[my_key][:port]) # send_packet to client
              send_raw_packet rr,r0,@clients[my_key][:ip], @clients[my_key][:port]
              mm=MqttSN::parse_message rr
              #puts "thread got #{rr}, sent to #{@clients[my_key][:ip]}: #{mm}"
              puts "UDP(#{client_ip}:#{client_port})->RAD(#{@clients[my_key][:ip]}:#{@clients[my_key][:port]}): #{pacc}"

              _,port,_,_ = @clients[my_key][:socket].addr
              dest="#{@server}:#{port}"
              printf "sc %-24.24s <- %-24.24s | %s\n",@clients[my_key][:uri],"udp://#{@broker_host}:#{@broker_port}",mm.to_json
              NRF24::note "sc %-24.24s <- %-24.24s | %s",@clients[my_key][:uri],"udp://#{@broker_host}:#{@broker_port}",mm.to_json
              #@gateways[@active_gw_id][:last_recv]=Time.now.to_i
              #@gateways[@active_gw_id][:counter_recv]+=1
              @clients[my_key][:last_send]=Time.now.to_i
              @clients[my_key][:counter_send]+=1

              case mm[:type]
              when :disconnect
                @clients[my_key][:state]=:disconnected
                puts "*************** disco #{my_key}"
              end
            end
          end
          dest="#{client_ip}:#{client_port}"
          printf "+ %s\n",dest
          NRF24::note "+ %s",dest
          puts "cli: #{@clients.to_json}"
          NRF24::note "cli: #{@clients.to_json}"
        end

        @clients[key][:stamp]=Time.now.to_i
        m=MqttSN::parse_message r
        case m[:type]
        when :publish
          if m[:qos]==-1
            @clients[key][:state]=:disconnected #one shot
          end
        end
        #sbytes=@clients[key][:socket].send(r, 0, @server, @port) # to rsmb -- ok as is
        send_raw_packet r,@clients[key][:socket],@broker_host,@broker_port
        puts "RAD(#{client_ip}:#{@lient_port})->UDP(#{@broker_host}:#{@broker_port}): #{pac}"

        _,port,_,_ = @clients[key][:socket].addr
        dest="#{@server}:#{port}"
        #@gateways[@active_gw_id][:last_send]=Time.now.to_i
        #@gateways[@active_gw_id][:counter_send]+=1
        @clients[key][:last_recv]=Time.now.to_i
        @clients[key][:counter_recv]+=1
        begin
          if @active_gw_id and @gateways[@active_gw_id]
            printf "cs %-24.24s -> %-24.24s | %s\n", @clients[key][:uri],@gateways[@active_gw_id][:uri],m.to_json
            NRF24::note  "cs %-24.24s -> %-24.24s | %s", @clients[key][:uri],@gateways[@active_gw_id][:uri],m.to_json
          else
            printf "cs %-24.24s -> %-24.24s | %s\n", @clients[key][:uri],"udp://#{@broker_host}:#{@broker_port}",m.to_json
            NRF24::note "cs %-24.24s -> %-24.24s | %s", @clients[key][:uri],"udp://#{@broker_host}:#{@broker_port}",m.to_json
          end
        rescue Exception =>e
          puts "Error: main loop fails #{e}"
          pp e.backtrace
        end
      end
    rescue => e
      puts "Error: receive thread died: #{e}"
      pp e.backtrace
    end
    sleep 0.01
  end
end


def kill_client key
  puts "Killing Client #{key}:"
  if c=@clients[key]
    puts "Really Killing #{key}"
    msg= [MqttSN::DISCONNECT_TYPE] #,@s,c[:ip], c[:port]
    r = MqttSN::build_packet msg
    send_raw_packet r,@radio,@clients[key][:ip], @clients[key][:port]
    send_raw_packet r,@clients[key][:socket],@broker_host,@broker_port
  end
end


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

@radio=NRF24.new options.merge(id: :eka, ack: false, mac_header: true)

begin
  forwarder @radio,options
rescue SystemExit, Interrupt
  puts "\nExiting after Disconnect\n"
rescue => e
  puts "\nError: '#{e}' -- Quit after Disconnect\n"
  pp e.backtrace
end
puts "Killing Clients:"
@clients.each do |key,c|
  kill_client key
end
sleep 2

puts "Done."

