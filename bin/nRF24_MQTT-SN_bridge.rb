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


puts "Gateway Main Loop Starts:"
### gateway!!!
@clients={}
MAX_IDLE=120

#this needs to be Class...
def forwarder r0, broker_uri

  uri = URI.parse(broker_uri)
  if uri.scheme== 'udp'
    @broker_host=uri.host
    @broker_port=uri.port
  else
    raise "Error: Cannot open socket for '#{broker_uri}', unsupported scheme: '#{uri.scheme}'"
  end

  last_kill=0
  stime=Time.now.to_i
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

  Thread.new do #maintenance
    loop do
      begin
        sleep 1
        now=Time.now.to_i
        changes=false
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
          uri="rad://#{client_ip}:#{client_port}"
          @clients[key]={ip:client_ip, port:client_port, socket: UDPSocket.new, uri: uri, state: :active, counter_send:0, last_send:0 , counter_recv:0, last_recv:0}
          c=@clients[key]
          puts "thread start for #{key}"

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
          if @active_gw_id
            logger "cs %-24.24s -> %-24.24s | %s", @clients[key][:uri],@gateways[@active_gw_id][:uri],m.to_json
          else
            printf "cs %-24.24s -> %-24.24s | %s\n", @clients[key][:uri],"udp://#{@broker_host}:#{@broker_port}",m.to_json
            NRF24::note "cs %-24.24s -> %-24.24s | %s", @clients[key][:uri],"udp://#{@broker_host}:#{@broker_port}",m.to_json
          end
        rescue Exception =>e
          puts "logging fails #{e}"
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

@radio=NRF24.new id: :eka, ce: 22,cs: 27, irq: 17, chan:4, ack: false, mac: "A9:A9",mac_header: true

begin
  forwarder @radio,"udp://20.20.20.21:1882"
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

