#!/usr/bin/env ruby
#encoding: UTF-8

require 'pp'
require 'thread'
require 'pi_piper'
include PiPiper

class NRF24
  @@all=[]

  @@regs={
    CONFIG:      {address: 0x00},
    EN_RXADDR:   {address: 0x02},
    SETUP_AW:    {address: 0x03},
    SETUP_RETR:  {address: 0x04},
    RF_CH:       {address: 0x05},
    RF_SETUP:    {address: 0x06},
    STATUS:      {address: 0x07,poll: 1},
    OBSERVE_TX:  {address: 0x08,poll: 1},
    CD:          {address: 0x09,poll: 1},
    RX_ADDR_P0:  {address: 0x0A, bytes: 5 },
    RX_ADDR_P1:  {address: 0x0B, bytes: 5 },
    RX_ADDR_P2:  {address: 0x0C},
    RX_ADDR_P3:  {address: 0x0D},
    RX_ADDR_P4:  {address: 0x0E},
    RX_ADDR_P5:  {address: 0x0F},
    TX_ADDR:     {address: 0x10, bytes: 5 },
    RX_PW_P0:    {address: 0x11},
    RX_PW_P1:    {address: 0x12},
    FIFO_STATUS: {address: 0x17,poll: 1},
    FEATURE:     {address: 0x1D},
  }

  @@cmds={
    R_REGISTER: 0x00,
    W_REGISTER: 0x20,
    ACTIVATE:   0x50,
    R_RX_PAYLOAD: 0x61,
    W_TX_PAYLOAD: 0xA0,
    FLUSH_TX:   0xe1,
    W_TX_PAYLOAD_NOACK: 0xB0,
    ACTIVATE2:  0x73,
  }

  @@sem=Mutex.new 
  
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
    cc=get_ccode(c)
    @@sem.synchronize do
      @cs.off 
      PiPiper::Spi.begin do 
        @status=write cc
        data.each do |byte|
          ret << write(byte)
        end
      end
      @cs.on
    end
    [ret]
  end


  def rreg reg
    data=0
    i,bytes =get_address reg
    cc=get_ccode(:R_REGISTER) +i
    @@sem.synchronize do
      @cs.off
      PiPiper::Spi.begin do 
        @status=write cc
        if bytes==1
          data=write(0xff)
        else
          data=[]
          bytes.times do 
            data << write(0xff)
          end
        end
      end
      @cs.on
    end
    [@status,data,bytes]
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
      @status=status
    end
    [@status]
  end

  def send packet
    @ce.off
    wreg :CONFIG,0x0a
    cmd :W_TX_PAYLOAD_NOACK,packet
    @ce.on
    sleep 0.001
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

  def dump_regs all
    #puts "---------------- rcnt:#{@rcnt} | rfull:#{@rfull} ,scnt:#{@scnt} "
    @@regs.each do |k,r|
      next if not r[:poll] and not all
      s,d,bytes =rreg k
      if s!=0xff
        if bytes==1
          printf "%-12.12s(%02X): %08b %02X\n",k,r[:address],d,d
        else
          printf "%-12.12s(%02X):            [ ",k,r[:address]
          d.each do |b|
            printf "%02X ",b
          end
          printf "]\n"
        end
      end
    end
  end

  def do_recv
    Thread.new do
      loop do
        donesome=false
        s,d,b=rreg :FIFO_STATUS
        if d==0x10 or d==0x12
          #print "!"
          ret=cmd :R_RX_PAYLOAD,[ 0xff,0xff,0xff,0xff]
          @rcnt+=1
          donesome=true
        end
        if  d==0x12
          #print "*" 
          ret=cmd :R_RX_PAYLOAD,[ 0xff,0xff,0xff,0xff]
          @rcnt+=1
          @rfull+=1
          donesome=true
        end
        sleep 0.0001 if not donesome
      end
    end
  end

  def do_send
    Thread.new do
      begin
        loop do
          s,d,b=rreg :STATUS
          if (s&0x01)==0x00 
            send [1,2,3,4]
            #print "."
            @scnt+=1
          end
          sleep 0.001
        end
      rescue Exception =>e
        puts "do_send fails #{e}"
        pp e.backtrace
      end
    end
  end

  attr_accessor :rcnt,:scnt,:rfull

  def initialize(hash={})
    @regs={} 
    @rcnt=0
    @rfull=0
    @scnt=0
    @id=hash[:id]
    @ce=PiPiper::Pin.new(:pin => hash[:ce], :direction => :out)
    @cs=PiPiper::Pin.new(:pin => hash[:cs], :direction => :out)
    @ce.on
    @cs.on
    @@all<<self
    wreg :CONFIG,0x0b
    wreg :SETUP_RETR,0x8f
    wreg :SETUP_AW,0x03
    wreg :STATUS,0x70
    wreg :RX_PW_P0,4
    wreg :RX_PW_P1,4
    wreg :TX_ADDR,[0x12,0x34,0x56,0x78,0x9a]
    wreg :RX_ADDR_P0,[0x12,0x34,0x56,0x78,0x9a]

    cmd :ACTIVATE,[ get_ccode(:ACTIVATE2)]
    cmd :ACTIVATE
    wreg :FEATURE,0x05
    cmd :FLUSH_TX
    @recv_t=do_recv if  @id==:toka
    @send_t=do_send if  @id==:eka
  end
end

