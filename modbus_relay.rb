#!/usr/bin/env ruby
# https://www.waveshare.com/wiki/Modbus_POE_ETH_Relay
#
# Send commands between containers using pipes
# https://community.home-assistant.io/t/running-commands-on-the-host-without-ssh/510481
# need to chmod a+wr for the fifo pipe after creation
#
#
# mkdir /usr/share/hassio/homeassistant/pipes
# sudo mkfifo /usr/share/hassio/homeassistant/pipes/host_executor_queue
# chmod a+wr /usr/share/hassio/homeassistant/pipes/host_executor_queue

require 'digest/crc16_modbus'
require 'socket'
require 'fileutils'

def send_message(message)
  # message is array of bytes [0x01, 0x02, etc.]
  sendbuff = message.dup
  crc = Digest::CRC16Modbus.new

  crc.update(message.pack('C*'))
  crc_int = crc.hexdigest.to_i(16) # get integer value of CRC

  # append to sendbuff
  sendbuff << (crc_int & 0x00FF)
  sendbuff << ((crc_int >> 8) & 0x00FF)

  puts "sending=" + sendbuff.inspect

  # encode and send via tcp
  @sock.write(sendbuff.pack('C*'))

  # wait to for read
  # timeout?
  readbuff = []
  while (readbyte = @sock.read(1))
    puts "readbyte=" + readbyte.inspect
    readbyte = readbyte.unpack("H*").first.to_i(16)
    readbuff << readbyte
    puts "readbuff=" + readbuff.inspect
    crc = Digest::CRC16Modbus.new
    crc.update(readbuff.pack('C*'))
    crc_int = crc.hexdigest.to_i(16)
    puts "crc= #{crc_int}"
    break if crc_int == 0
  end
  return readbuff
end

RELAY_ON = 0xFF
RELAY_OFF = 0x00
RELAY_FLIP = 0x55

def toggle_relay(relay_idx, action)
  sendbuff =  [0x01,
               0x05, 
               0x00,
               relay_idx.to_i,
               action,
               0x00,
            ]
  send_message(sendbuff)
end

def toggle_all_relays(action)
  return toggle_relay(0xFF, action)
end

def pulse_relay(relay_idx, on_ms)
  #Pulses a relay
  pulse_ms = on_ms

  # send to device number of 100 ms counts to keep relay active
  pulse_ticks = pulse_ms / 100
  pulse_time_hex = pulse_ticks.to_s.to_i(16)

  sendbuff =  [0x01,
               0x05, 
               0x02,
               relay_idx.to_i,
               ((pulse_time_hex >> 8) & 0x00FF),
               (pulse_time_hex & 0x00FF),
            ]
  send_message(sendbuff)
end

def get_sw_version
  sendbuff =  [0x01,
               0x03, # read sr version
               0x80, 0x00, # read sw version
               0x00, 0x01, # fixed
            ]
  send_message(sendbuff)

end



#send_message(sendbuff)
#get_sw_version()
#
PIPE_DIRECTORY = "/usr/share/hassio/homeassistant/pipes"
PIPE_NAME = PIPE_DIRECTORY + "/host_executor_queue"

# Recreate pipes if not exist
FileUtils.mkdir_p(PIPE_DIRECTORY) if !File.directory?(PIPE_DIRECTORY)

# recreate pipe
File.delete(PIPE_NAME) if File.exists?(PIPE_NAME)
File.mkfifo(PIPE_NAME)
FileUtils.chmod("a+rw", PIPE_NAME)


pipe = File.open(PIPE_NAME, "r+") 
while true
  puts pipe.gets  #I expect this to block and wait for input
  @sock = TCPSocket.new("192.168.200.195", 4196)
  toggle_relay(0xFF, RELAY_FLIP)
  @sock.close
end
