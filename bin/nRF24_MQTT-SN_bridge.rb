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

puts "\nPure Ruby nRF24 <-> UDP MQTT-SN Bridge Starting..."

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


r0=NRF24.new id: :eka, ce: 22,cs: 27, irq: 17, chan:4, ack: false, mac: "A9:A9",mac_header: true

s0,s0_host,s0_port=open_port("udp://20.20.20.21:1882") # our port for forwarder/broker connection


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

@bcast_mac="45:45:45"
@bcast_period=20
Thread.new do
  loop do
    begin
      msg=[MqttSN::ADVERTISE_TYPE,222,@bcast_period>>8,@bcast_period&0xff]
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

puts "Gateway Main Loop Starts:"
### gateway!!!
loop do
  begin
    if pac=poll_packet(s0)
      r,client_ip,client_port=pac
      puts "UDP(#{client_ip}:#{client_port})->RAD(#{@client_ip}:#{@client_port}): #{pac}"
      send_raw_packet r,r0,@client_ip,@client_port
    end

    if pac=poll_packet_radio(r0)
      r,@client_ip,@client_port=pac
      puts "RAD(#{@client_ip}:#{@client_port})->UDP(#{s0_host}:#{s0_port}): #{pac}"
      send_raw_packet r,s0,s0_host,s0_port
    end

  rescue => e
      puts "Error: receive thread died: #{e}"
      pp e.backtrace
  end
  sleep 0.01
end

