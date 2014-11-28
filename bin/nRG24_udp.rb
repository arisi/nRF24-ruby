#!/usr/bin/env ruby
#encoding: UTF-8


require "pp"
require 'socket'
require 'json'
require 'uri'
require 'ipaddr'
require 'time'
require 'thread'


if File.file? './lib/nRF24-ruby.rb'
  require './lib/nRF24-ruby.rb'
  puts "using local lib"
else
  require 'nRF24-ruby'
end

puts "\nPure Ruby nRF24 <-> UDP Bridge Starting..."

http=true
http=false

if http
  puts "Loading Http-server.. hold on.."
  require 'minimal-http-ruby'
  minimal_http_server http_port: 8088, http_path: "./http/"
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
    socket.send(msg, 0, server, port)
    #MqttSN::hexdump msg
  else
    puts "Error: no socket at send_raw_packet"
  end
end


r0=NRF24.new id: :eka, ce: 22,cs: 27, irq: 17, chan:3, ack: true
r1=NRF24.new id: :toka, ce: 24,cs: 23, irq: 22, chan: 3, ack: true

s0,s0_host,s0_port=open_port("udp://20.20.20.21:1882") # our port for forwarder/broker connection
s1,s1_host,s1_port=open_port("udp://20.20.20.21:1882")
s1.bind("0.0.0.0",5555) # our port for clients
pp s0
pp s1
puts "Main Loop Starts:"

loopc=0;
sc=0;


#r0.send_q << [0x55,0x44]
loop do
  begin
    if pac=poll_packet(s1) #get packets from client's udp and send them to broker/forwarder's radio
      r,@client_ip,@client_port=pac
      msg=r.unpack('c*')
      puts "UDP1(#{@client_ip}:#{@client_port})->RAD0: #{msg}"
      r0.send_q << msg
    end
    while not r1.recv_q.empty? #get packets from broker's radio and send them to udp broker/forwader 
      msg=r1.recv_q.pop
      pac=msg.pack("c*")
      len=msg[0]
      pac=pac[0...len]
      puts "RAD1->UDP0(#{s0_host}:#{s0_port}): #{msg} len=#{len}"
      send_raw_packet pac,s0,s0_host,s0_port
    end
    if pac=poll_packet(s0) #get packets from 
      r,client_ip,client_port=pac
      msg=r.unpack('c*')
      puts "UDP0(#{client_ip}:#{client_port})->RAD1: #{msg}"
      r1.send_q << msg
    end
    while not r0.recv_q.empty? #get packets from broker's radio and send them to udp broker/forwader 
      msg=r0.recv_q.pop
      pac=msg.pack("c*")
      len=msg[0]
      pac=pac[0...len]
      puts "RAD0->UDP1(#{@client_ip}:#{@client_port}): #{msg}, len=#{len}"
      send_raw_packet pac,s1,@client_ip,@client_port
    end
  rescue => e
      puts "Error: receive thread died: #{e}"
      pp e.backtrace
  end
  sleep 0.01
end

