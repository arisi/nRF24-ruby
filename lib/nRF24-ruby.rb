#!/usr/bin/env ruby
#encoding: UTF-8

require 'pp'
require 'thread'
require 'pi_piper'
include PiPiper

class NRF24
  @@all=[]
  @@PAYLOAD_SIZE=32
  @@regs={
    CONFIG:      {address: 0x00},
    EN_AA:       {address: 0x01},
    EN_RXADDR:   {address: 0x02},
    SETUP_AW:    {address: 0x03},
    SETUP_RETR:  {address: 0x04},
    RF_CH:       {address: 0x05},
    RF_SETUP:    {address: 0x06},
    STATUS:      {address: 0x07, poll: 1},
    OBSERVE_TX:  {address: 0x08, poll: 1},
    CD:          {address: 0x09, poll: 1},
    RX_ADDR_P0:  {address: 0x0A, bytes: 5 },
    RX_ADDR_P1:  {address: 0x0B, bytes: 5 },
    RX_ADDR_P2:  {address: 0x0C},
    RX_ADDR_P3:  {address: 0x0D},
    RX_ADDR_P4:  {address: 0x0E},
    RX_ADDR_P5:  {address: 0x0F},
    TX_ADDR:     {address: 0x10, bytes: 5 },
    RX_PW_P0:    {address: 0x11},
    RX_PW_P1:    {address: 0x12},
    FIFO_STATUS: {address: 0x17, poll: 1},
    FEATURE:     {address: 0x1D},
  }

  @@cmds={
    R_REGISTER: 0x00,
    W_REGISTER: 0x20,
    ACTIVATE:   0x50,
    R_RX_PAYLOAD: 0x61,
    W_TX_PAYLOAD: 0xA0,
    FLUSH_TX:   0xe1,
    FLUSH_RX:   0xe2,
    W_TX_PAYLOAD_NOACK: 0xB0,
    ACTIVATE2:  0x73,
  }

  @@sem=Mutex.new 
  @@log=[]

  def self.note str,*args
    begin
      s=sprintf(str,*args)
      text=sprintf("%s: %s",Time.now.iso8601,s)
      @@log << {stamp: Time.now.to_i, text: text}
    rescue => e
      pp e.backtrace
      puts "note dies: #{e} '#{str}'"
    end
  end
  
  def get_ccode c
    ccode=@@cmds[c]
    if not ccode
      printf("Error: Unkown Command %s\n",c);
      raise "Command Error"
    end
    ccode
  end

  def get_address reg
    rdata=@@regs[reg]
    if not rdata
      raise "Unknown Register : #{reg}"
    end
    [rdata[:address],rdata[:bytes]||1]
  end

  def cmd c,data=[]
    ret=[]
    status=0
    cc=get_ccode(c)
    @@sem.synchronize do
      @cs.off 
      PiPiper::Spi.begin do 
        status=write cc
        data.each do |byte|
          ret << write(byte)
        end
      end
      @cs.on
      @s[:status]=status
    end
    ret
  end


  def rreg reg
    status=data=0
    i,bytes =get_address reg
    cc=get_ccode(:R_REGISTER) +i
    @@sem.synchronize do
      @cs.off
      PiPiper::Spi.begin do 
        status=write cc
        if bytes==1
          data=write(0xff)
        else
          data=[]
          bytes.times do 
            data << write(0xff)
          end
        end
      end
      @s[:status]=status
      @cs.on
    end
    [@s[:status],data,bytes,cc]
  end

  def wreg reg,data
    i,bytes=get_address reg
    cc=get_ccode(:W_REGISTER)+i
    @@sem.synchronize do
      status=0xff
      @cs.off
      PiPiper::Spi.begin do
        status=write cc
        if bytes==1
          write(data)
        else
          data.each do |byte|
            write(byte)
          end
        end
      end
      @cs.on
      @s[:status]=status
    end
    [@s[:status]]
  end

  def send packet
    pac=Array.new(@@PAYLOAD_SIZE, 0)
    packet.each_with_index do |byte,i|
      pac[i]=packet[i] if i<@@PAYLOAD_SIZE
    end
    @ce.off
    wreg :CONFIG,0x0a
    cmd :W_TX_PAYLOAD_NOACK,pac
    @ce.on
    sleep 0.0005
    @ce.off
    wreg :CONFIG,0x0b
    @ce.on
  end

  def recv 
    fifo_status,_=rreg :FIFO_STATUS
    if (fifo_status & 0x01) == 0x01
      puts "on dataa"
    end
  end

  def get_regs all
    @@regs.each do |k,r|
      next if not r[:poll] and not all
      s,d,bytes,code =rreg k
      @s[:regs][code]=d
    end
  end

  def do_recv
    Thread.new do
      loop do

        sleep 1
      end
    end
  end

  def do_send
    Thread.new do
      begin
        loop do
          donesome=false
          s,d,b=rreg :FIFO_STATUS
          if (d&0x01)==0x00
            ret=cmd :R_RX_PAYLOAD,Array.new(@@PAYLOAD_SIZE, 0xff)
            @recv_q<<ret
            @s[:rcnt]+=1
            donesome=true
          end
          if (d&0x02)==0x02
            ret=cmd :R_RX_PAYLOAD,Array.new(@@PAYLOAD_SIZE, 0xff)
            @recv_q<<ret
            @s[:rcnt]+=1
            @s[:rfull]+=1
            donesome=true
          end
          #sleep 0.01 if not donesome


          if not @send_q.empty?
            s,d,b=rreg :STATUS
            if (s&0x01)==0x00
              msg=@send_q.pop 
              send msg 
              @s[:scnt]+=1
            end
          end
          sleep 0.01
        end
      rescue Exception =>e
        puts "do_send fails #{e}"
        pp e.backtrace
      end
    end
  end

  def do_monitor
    Thread.new do
      begin
        lc=0
        loop do
          get_regs(lc%10 == 0)
          sleep 1
          lc+=1
        end
      rescue Exception =>e
        puts "do_monitor fails #{e}"
        pp e.backtrace
      end
    end
  end

  attr_accessor :rcnt,:scnt,:rfull
  attr_accessor :send_q,:recv_q,:log

  def self.all_devices
    @@all
  end

  def self.json
    devs=[]
    NRF24::all_devices.each do |data|
      devs<<data.json
    end
    json ={
      now:Time.now.to_i,
      devs: devs,
    }
    return json
  end

  def self.register_table
    @@regs
  end

  def json 
    @s
  end

  def self.get_log 
    @@log
  end

  def initialize(hash={})
    @semh=Mutex.new 

    @s={
      stamp: 0,
      params: hash,
      status: 0,
      regs: {},
      rcnt: 0,
      rfull: 0,
      scnt: 0,
      } 
    @id=hash[:id]
    @ce=PiPiper::Pin.new(:pin => hash[:ce], :direction => :out)
    @cs=PiPiper::Pin.new(:pin => hash[:cs], :direction => :out)

    @ce.on
    @cs.on
    @@all<<self
    wreg :CONFIG,0x0b
    wreg :SETUP_RETR,0x00
#    wreg :SETUP_RETR,0x8f
    wreg :EN_AA,0x00
    wreg :SETUP_AW,0x03
    wreg :STATUS,0x70
    wreg :RX_PW_P0,@@PAYLOAD_SIZE
    wreg :RX_PW_P1,32
    wreg :TX_ADDR,[0x12,0x34,0x56,0x78,0x9a]
    wreg :RX_ADDR_P0,[0x12,0x34,0x56,0x78,0x9a]

    cmd :ACTIVATE,[ get_ccode(:ACTIVATE2)]
    #cmd :ACTIVATE
    wreg :FEATURE,0x01
    cmd :FLUSH_TX
    cmd :FLUSH_RX
    if hash[:roles]
      if hash[:roles].include? :recv
        @recv_t=do_recv 
        @recv_q=Queue.new
      end
      if hash[:roles].include? :send
        @send_t=do_send 
        @send_q=Queue.new
      end
    end
    @monitor_t=do_monitor
  end
end

