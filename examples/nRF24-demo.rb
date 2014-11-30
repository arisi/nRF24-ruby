#!/usr/bin/env ruby
#encoding: UTF-8

if File.file? './lib/nRF24-ruby.rb'
  require './lib/nRF24-ruby.rb'
  puts "using local lib"
else
  require 'nRF24-ruby'
end

puts "\nPure Ruby nRF24L01 Driver Starting..."

http=true
#http=false

if http
  puts "Loading Http-server.. hold on.."
  require 'minimal-http-ruby'
  minimal_http_server http_port: 8088, http_path: "./http/"
  puts "\n"
end

bmac="C7:C7:C7"
NRF24::set_bmac bmac
r0=NRF24.new id: :eka, ce: 22,cs: 27, irq: 17, chan:4, ack: false, mac: "A7:A7",mac_header: true
r1=NRF24.new id: :toka, ce: 24,cs: 23, irq: 22, chan: 4, ack: false, mac: "A5:A5",mac_header: true

puts "Main Loop Starts: bmac: #{NRF24::get_bmac}"

loopc=0;
sc=0;
lista=[]
loop do
  if (loopc%4)==0
    msg=[]
    str=sprintf "%5.5d",sc
    lista<<sc
    sc+=1
    str.each_byte do |b|
      msg<<b
    end
    if sc&2==0
      if sc&1==0
        r0.send_q << {msg: msg, socket: :broadcast}
      else
        r1.send_q << {msg: msg, socket: :broadcast}
      end
    else  
      if sc&1==0
        #r0.send_q << {msg: msg, tx_mac: r1.mac,ack:true}
        r0.send_q << {msg: msg, to: r1.mac, socket: 3,ack:true}
      else
        r1.send_q << {msg: msg, to: r0.mac, socket: 4,ack:true}
      end
    end
    NRF24::note "lista:#{lista.size}"
  end
  loopc+=1
  while not r1.recv_q.empty?
    got=r1.recv_q.pop
    #puts "got 1 #{got}"
    msg=""
    len=0
    got[:msg].each_with_index do |b,i|
      break  if b==0x00
      msg[i]=b.chr 
    end
    got[:msg]=msg
    s=got[:msg].to_i
    lista-=[s]
    NRF24::note "i #{got}"
  end
  while not r0.recv_q.empty?
    got=r0.recv_q.pop
    #puts "got 0 #{got}"
    msg=""
    len=0
    got[:msg].each_with_index do |b,i|
      msg[i]=b.chr if b!=0x00
    end
    got[:msg]=msg
    s=got[:msg].to_i
    lista-=[s]
    NRF24::note "i #{got}"
  end
  if not http
   if NRF24::get_log.size>0
      e=NRF24::get_log[0]
      if e[:text][/lista/]
        puts e
      end
      NRF24::get_log.shift
   end
  end
  sleep 0.05
end

