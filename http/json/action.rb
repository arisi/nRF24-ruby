#!/usr/bin/env ruby
# encode: UTF-8

def json_action request,args,session,event
  pp args
  devs=NRF24::all_devices
  chan=(args['chan']||2).to_i
  chan&=0x7f
  if args['aa']=="true"
    aa=true
  else
    aa=nil
  end

  devs.each do |d|
  	if false
	  	d.wreg :RF_CH,chan
	  	d.cmd :FLUSH_TX
	    d.cmd :FLUSH_RX
	    d.get_regs true
	  else
	  	puts "initing #{d}"
	  	d.hw_init chan: chan, ack: aa, rf_dr: args['rf_dr'], rf_pwr: args['rf_pwr'], lna_hcurr: args['lna_hcurr'],mac_header: true
	  	d.get_regs true
	  end
  end
  data={jee: 123}
  return ["text/json",data]
end