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
#http=false

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


r0=NRF24.new id: :eka, ce: 22,cs: 27, irq: 17, chan:4, ack: false, mac: "A7:A7",mac_header: true
r1=NRF24.new id: :toka, ce: 24,cs: 23, irq: 22, chan: 4, ack: false, mac: "A5:A5",mac_header: true

s0,s0_host,s0_port=open_port("udp://20.20.20.21:1882") # our port for forwarder/broker connection
s1,s1_host,s1_port=open_port("udp://20.20.20.21:1882")
s1.bind("0.0.0.0",5555) # our port for clients
pp s0
pp s1
puts "Main Loop Starts:"

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

# client s1 <-> r0

# forwarder s0 <-> r1

loop do
  begin
    if pac=poll_packet(s1) #get packets from client's via udp (s1) and send them to forwarder's radio
      r,@client_ip,@client_port=pac
      puts "UDP1(#{@client_ip}:#{@client_port})->RAD0(#{r1.mac}:#{4}): #{pac}"
      #r0.send_q << {msg: msg, to: r1.mac, socket: 3,ack:false}
      send_raw_packet r,r0,r1.mac,4
    end

    if pac=poll_packet_radio(r1)  #this is forwarder receiving the packet from client -- and sendig it to broker at s0
      r,client_ip,client_port=pac
      puts "RAD1(#{client_ip}:#{client_port})->UDP0(#{s0_host}:#{s0_port}): #{pac}"
      send_raw_packet r,s0,s0_host,s0_port
    end


    if pac=poll_packet(s0) #get packets from broker ... send to client via radio
      r,client_ip,client_port=pac
      puts "UDP0(#{client_ip}:#{client_port})->RAD1(#{r0.mac}:#{3}): #{pac}"
      send_raw_packet r,r1,r0.mac,3
    end

    if pac=poll_packet_radio(r0)  #this is client listening to radio r0 and getting the packet (via s1)
      r,client_ip,client_port=pac
      puts "RAD0(#{client_ip}:#{client_port})->UDP1(#{@client_ip}:#{@client_port}): #{pac}"
      send_raw_packet r,s1,@client_ip,@client_port
    end

  rescue => e
      puts "Error: receive thread died: #{e}"
      pp e.backtrace
  end
  sleep 0.01
end

