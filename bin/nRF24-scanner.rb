#!/usr/bin/env ruby
#encoding: UTF-8


require "pp"
require 'time'
require 'nRF24-ruby'

r=NRF24.new id: :eka, ce: 27,cs: 22, irq: 17, chan:4, ack: false, mac: "A1:A1",mac_header: true

chan=0
loop do
  r.wreg :RF_CH,chan
  cd=0
  100.times do
    sleep 0.01
    s,d,_ = r.rreg :CD
    if d==0x01
      cd+=1
    end
  end
  printf "chan=%d, cd=%d\n",chan,cd
  chan+=1
  chan=0 if chan>127
end
