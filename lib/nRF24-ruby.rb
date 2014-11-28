#!/usr/bin/env ruby
#encoding: UTF-8

require 'pp'
require 'thread'
require 'pi_piper'
include PiPiper

class NRF24
  @@all=[]
  @@PAYLOAD_SIZE=32
  @@SPI_CLOCK=250000
        
  @@regs={
    CONFIG:      {address: 0x00,len:7},
    EN_AA:       {address: 0x01,len:6},
    EN_RXADDR:   {address: 0x02,len:6},
    SETUP_AW:    {address: 0x03,len:2},
    SETUP_RETR:  {address: 0x04},
    RF_CH:       {address: 0x05,format: :dec},
    RF_SETUP:    {address: 0x06,len:4},
    STATUS:      {address: 0x07, poll: 1,len: 7},
    OBSERVE_TX:  {address: 0x08, poll: 1},
    CD:          {address: 0x09, poll: 1, len: 1},
    RX_ADDR_P0:  {address: 0x0A, bytes: 3, format: :hex },
    RX_ADDR_P1:  {address: 0x0B, bytes: 3, format: :hex },
    RX_ADDR_P2:  {address: 0x0C, format: :hex,hide: true},
    RX_ADDR_P3:  {address: 0x0D, format: :hex,hide: true},
    RX_ADDR_P4:  {address: 0x0E, format: :hex,hide: true},
    RX_ADDR_P5:  {address: 0x0F, format: :hex,hide: true},
    TX_ADDR:     {address: 0x10, bytes: 3 , format: :hex},
    RX_PW_P0:    {address: 0x11, format: :dec,hide: true},
    RX_PW_P1:    {address: 0x12, format: :dec,hide: true},
    RX_PW_P2:    {address: 0x13, format: :dec,hide: true},
    RX_PW_P3:    {address: 0x14, format: :dec,hide: true},
    RX_PW_P4:    {address: 0x15, format: :dec,hide: true},
    RX_PW_P5:    {address: 0x16, format: :dec,hide: true},
    FIFO_STATUS: {address: 0x17, poll: 1, len:7},
    DYNPD:       {address: 0x1C,len:6}, 
    FEATURE:     {address: 0x1D,len:3},
  }

  @@cmds={
    R_REGISTER: 0x00,
    W_REGISTER: 0x20,
    ACTIVATE:   0x50,
    R_RX_PL_WID: 0x60,
    R_RX_PAYLOAD: 0x61,
    W_TX_PAYLOAD: 0xA0,
    FLUSH_TX:   0xe1,
    FLUSH_RX:   0xe2,
    W_TX_PAYLOAD_NOACK: 0xB0,
    ACTIVATE2:  0x73,
  }

  @@sem=Mutex.new 
  @@log=[]
  @@bmac="45:45:45:45:45"

  def self.set_bmac mac
    @@bmac=mac
    puts "set bmac to #{mac}"
  end

  def self.note str,*args
    begin
      s=sprintf(str,*args)
      text=sprintf("%s: %s",Time.now.iso8601,s)
      @@log << {stamp: Time.now.to_i, text: text.encode("UTF-8", :invalid=>:replace, :replace=>"?")}
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
        clock(@@SPI_CLOCK)
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
        clock(@@SPI_CLOCK)
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
        clock(@@SPI_CLOCK)
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

  def send packet,hash={}
    pac=Array.new(@@PAYLOAD_SIZE, 0)
    packet.each_with_index do |byte,i|
      pac[i]=packet[i] if i<@@PAYLOAD_SIZE
    end
    @ce.off
    wreg :CONFIG,0x0a
    #prepend our mac?
    if @s[:params][:mac_header]
      pac= NRF24::mac2a(@mac, short:true)+pac
      pac=pac[0...32]
    end
    if hash[:ack] and @s[:params][:ack]
      cmd :W_TX_PAYLOAD,pac
    else
      cmd :W_TX_PAYLOAD_NOACK,pac
    end
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

  def get_regs all
    @@regs.each do |k,r|
      next if not r[:poll] and not all
      s,d,bytes,code =rreg k
      @s[:regs][code]=d
    end
  end

  def rf_server
    Thread.new do
      begin
        loop do
          donesome=false

          s,d,b=rreg :FIFO_STATUS
          if (s&0x40) == 0x40
            #NRF24::note "got RX_DR --received something"
            wreg :STATUS,0x40
          end
          if (s&0x20) == 0x20
            #NRF24::note "got TX_DS --sent something"
            wreg :STATUS,0x20
          end
          if (s&0x10) == 0x10
            NRF24::note "****************** got MAX_RT --send fails..."
            wreg :STATUS,0x10
            @s[:sfail]+=1
          end

          while (d&0x01)==0x00
            @s[:rfull]+=1 if (d&0x02)==0x02
            pipe=(s>>1)&0x05
            if pipe==0
              socket=:broadcast
            else
              socket=pipe-1
            end
            ret=cmd :R_RX_PAYLOAD,Array.new(@@PAYLOAD_SIZE, 0xff)
            if @s[:params][:mac_header]
              sender=NRF24::a2mac(ret[0..1])
              ret.shift
              ret.shift
            end
            @recv_q<<{msg:ret,socket:socket,from:sender,to:@mac,dir: :in}
            @s[:rcnt]+=1
            s,d,b=rreg :FIFO_STATUS
            donesome=true
          end

          #send rate limiter here :)
          if not @send_q.empty?
            if (d&0x20)==0x00

              s,d,b=rreg :OBSERVE_TX
              if (d&0x0f)!=0x00
                NRF24::note "got ARC_CNT:#{d&0x0f}******************"
                @s[:sarc]+=d&0x0f
              end

              msg=@send_q.pop
              #puts "msg:#{msg}"
              if msg[:socket]==:broadcast
                to=NRF24::mac2a(NRF24::get_bmac)
              else
                to=NRF24::mac2a(msg[:to],socket: msg[:socket])
              end
              wreg :TX_ADDR, to
              msg[:from]=@mac
              msg[:dir]=:out
              send msg[:msg], ack:msg[:ack]
              msg[:msg]=msg[:msg].pack("c*")
              NRF24::note "o #{msg}"
              @s[:scnt]+=1
            end
          end
          sleep 0.01 if not donesome
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
  attr_accessor :send_q,:recv_q,:log,:mac

  def self.all_devices
    @@all
  end

  def self.get_bmac
    @@bmac
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

  def self.a2mac a,hash={}
    mac=""
    a.each do |e|
      mac+=":" if mac!=""
      mac+=sprintf "%02X",e
    end
    mac
  end

  def self.mac2a mac,hash={}
    a=[]
    mac.split(":").each do |b|
      a<<b.hex
    end
    a.unshift hash[:socket]||0 if a.size==2 and not hash[:short]
    #pp a
    a
  end

  def hw_init hash
    @s={
      stamp: 0,
      params: hash,
      status: 0,
      regs: {},
      rcnt: 0,
      rfull: 0,
      scnt: 0,
      sarc: 0,
      sfail: 0,
    } 
    @id=hash[:id]
    wreg :CONFIG,0x0b
    rf_dr=(hash[:rf_dr]||1).to_i&0x01
    rf_pwr=(hash[:rf_pwr]||3).to_i&0x03
    lna_hcurr=(hash[:lna_hcurr]||1).to_i&0x01
    wreg :RF_SETUP,(rf_dr<<3)+(rf_pwr<<1)+lna_hcurr
    wreg :RF_CH,hash[:chan]||2
    if hash[:ack]
      wreg :SETUP_RETR,0x8f
      wreg :EN_AA,0x3e # no acks on broadcast
    else
      wreg :SETUP_RETR,0x00
      wreg :EN_AA,0x00
    end
    wreg :FEATURE,0x01
    wreg :SETUP_AW,0x01
    wreg :DYNPD,0x00
    wreg :STATUS,0x70
    wreg :EN_RXADDR,0x3f
    wreg :RX_PW_P0,@@PAYLOAD_SIZE
    wreg :RX_PW_P1,@@PAYLOAD_SIZE
    wreg :RX_PW_P2,@@PAYLOAD_SIZE
    wreg :RX_PW_P3,@@PAYLOAD_SIZE
    wreg :RX_PW_P4,@@PAYLOAD_SIZE
    wreg :RX_PW_P5,@@PAYLOAD_SIZE
    wreg :TX_ADDR,NRF24::mac2a(@@bmac)
    wreg :RX_ADDR_P0,NRF24::mac2a(@@bmac)
    
    if hash[:mac] #keep old if not defined
      wreg :RX_ADDR_P1,NRF24::mac2a(hash[:mac]) 
      @mac=hash[:mac]
    else
      s,d,bytes,code =rreg :RX_ADDR_P1
      mac=""
      d.each do |b|
        mac+=":" if mac!=""
        mac+=sprintf "%02X",b
      end
      @mac=mac
    end
    wreg :RX_ADDR_P2,1
    wreg :RX_ADDR_P3,2
    wreg :RX_ADDR_P4,3
    wreg :RX_ADDR_P5,4
#    if hash[:ack]
 #     cmd :ACTIVATE,[ 0]
  #  else
      cmd :ACTIVATE,[ get_ccode(:ACTIVATE2)]
   # end

    cmd :FLUSH_TX
    cmd :FLUSH_RX
  end

  def initialize(hash={})
    @semh=Mutex.new 

   
    @ce=PiPiper::Pin.new(:pin => hash[:ce], :direction => :out)
    @cs=PiPiper::Pin.new(:pin => hash[:cs], :direction => :out)

    @ce.on
    @cs.on
    @@all<<self

    @recv_q=Queue.new
    @send_q=Queue.new

    hw_init hash

    @server_t=rf_server 
    @monitor_t=do_monitor
  end
end

