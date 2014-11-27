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

if http
  puts "Loading Http-server.. hold on.."
  require 'minimal-http-ruby'
  minimal_http_server http_port: 8088, http_path: "./http/"
  puts "\n"
end


r0=NRF24.new id: :eka, ce: 22,cs: 27, irq: 17, chan:3, ack: true
r1=NRF24.new id: :toka, ce: 24,cs: 23, irq: 22, chan: 3, ack: true

puts "Main Loop Starts:"

loopc=0;
sc=0;

loop do
  if (loopc%4)==0
    msg=[]
    str=sprintf "testing %5.5d -- testing?",sc%10000
    sc+=1
    str.each_byte do |b|
      msg<<b
    end
     if sc&1==0
      r0.send_q << msg
    else
      r1.send_q << msg
    end
    NRF24::note "sent '#{str}' to #{sc&1}"
  end
  loopc+=1
  while not r1.recv_q.empty?
    got=r1.recv_q.pop
    #puts "got 1 #{got}"
    msg=""
    len=0
    got.each_with_index do |b,i|
      msg[i]=b.chr
    end
    NRF24::note "got #{msg} from 1!"
  end
  while not r0.recv_q.empty?
    got=r0.recv_q.pop
    #puts "got 0 #{got}"
    msg=""
    len=0
    got.each_with_index do |b,i|
      msg[i]=b.chr
    end
    NRF24::note "got #{msg} from 0!"
  end
  if not http
    pp r0.json
    pp r1.json
  end
  sleep 0.1
end

