#!/usr/bin/env ruby
#encoding: UTF-8

if File.file? './lib/nRF24-ruby.rb'
  require './lib/nRF24-ruby.rb'
  puts "using local lib"
else
  require 'nRF24-ruby'
end

puts "\nPure Ruby nRF24L01 Driver Starting..."

if true
  puts "Loading Http-server.. hold on.."
  require 'minimal-http-ruby'
  minimal_http_server http_port: 8088, http_path: "./http/"
  puts "\n"
end


r0=NRF24.new id: :eka, ce: 22,cs: 27
r1=NRF24.new id: :toka, ce: 24,cs: 23

puts "Main Loop Starts:"

loop do
  #r0.dump_regs false
  #r1.dump_regs false
  puts "\n0: rcnt:#{r0.rcnt} | rfull:#{r0.rfull} ,scnt:#{r0.scnt} "
  puts "1: rcnt:#{r1.rcnt} | rfull:#{r1.rfull} ,scnt:#{r1.scnt} "
  sleep 1
end

