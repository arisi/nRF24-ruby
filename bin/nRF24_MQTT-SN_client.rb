#!/usr/bin/env ruby
#encoding: UTF-8


require "pp"
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

if http
  puts "Loading Http-server.. hold on.."
  require 'minimal-http-ruby'
  if local
    minimal_http_server http_port: 8088, http_path:  './http/'
  else
    minimal_http_server http_port: 8088, http_path:  File.join( Gem.loaded_specs['nRF24-ruby'].full_gem_path, 'http/')
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


r=NRF24.new id: :eka, ce: 27,cs: 22, irq: 17, chan:4, ack: false, mac: "A1:A1",mac_header: true

s=UDPSocket.new
s.bind("0.0.0.0",5555) # our port for clients

puts "Main Loop Starts:"

loopc=0;
sc=0;

@gateways={}
@active_gw_id=nil
 @gsem=Mutex.new

def add_gateway gw_id,hash
  if not @gateways[gw_id]
     @gateways[gw_id]={stamp: Time.now.to_i, status: :ok, last_use: 0,last_ping: 0,counter_send:0, last_send: 0,counter_recv:0, last_recv: 0}.merge(hash)
  else
    if @gateways[gw_id][:uri]!=hash[:uri]
      note "conflict -- gateway has moved? or duplicate"
    else
      @gateways[gw_id][:stamp]=Time.now.to_i
      @gateways[gw_id]=@gateways[gw_id].merge hash
    end
  end
end

def gateway_close cause
  @gsem.synchronize do #one command at a time --

    if @active_gw_id # if using one, mark it used, so it will be last reused
      note "Closing gw #{@active_gw_id} cause: #{cause}"
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


#CLIENT HERE
@server_uri="rad://A9:A9"
add_gateway(0,{uri: @server_uri,source: "default"})
pick_new_gateway
pp @gateways

GW="A9:A9"
loop do
  begin
    if pac=poll_packet(s)
      msg,@client_ip,@client_port=pac
      puts "UDP(#{@client_ip}:#{@client_port})->RAD(#{GW}:#{3}): #{pac}"
      send_raw_packet msg,r,GW,3
    end

    if pac=poll_packet(r)
      msg,client_ip,client_port=pac
      puts "RAD(#{client_ip}:#{client_port})->UDP(#{@client_ip}:#{@client_port}): #{pac}"
      if client_port==:broadcast
        m=MqttSN::parse_message msg
        puts "bcast! -- we handle it! #{m}"
        gw_id=m[:gw_id]
        duration=m[:duration]||180
        uri="rad://#{client_ip}"
        add_gateway(gw_id,{uri: uri, source: m[:type], duration:duration,stamp: Time.now.to_i})
        pp @gateways
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

