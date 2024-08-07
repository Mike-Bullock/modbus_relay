#!/usr/bin/env ruby
# https://www.waveshare.com/wiki/Modbus_POE_ETH_Relay
#
# Send commands between containers using pipes
# https://community.home-assistant.io/t/running-commands-on-the-host-without-ssh/510481
# need to chmod a+wr for the fifo pipe after creation
#
require 'digest/crc16_modbus'
require 'socket'
require 'fileutils'
require 'daemons'

def send_message(message, read_timeout_ms = 500)
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

  # wait to for read with 500ms timeout
  readbuff = []
  start_time = Time.now
  loop do
    if (Time.now - start_time)*1000.0 > read_timeout_ms
      # timeout after read_timeout_ms
      puts "timeout"
      return nil
    end
    if !@sock.ready?
      # sleep 10ms is no data on socket.
      sleep 0.01
      next
    end

    # read a single byte and add it to receive buffer
    readbyte = @sock.read(1)
    readbyte = readbyte.unpack("H*").first.to_i(16)
    readbuff << readbyte
    crc = Digest::CRC16Modbus.new
    crc.update(readbuff.pack('C*'))
    
    # the only way we know we have a full response is when the crc passes.
    if crc.hexdigest.to_i(16) == 0
      puts "Received valid response"
      return readbuff
    end
  end

  return nil
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

def find_relay_ip(timeout_ms = 500)
  # there is a UDP broadcast to port 1092 to find relays on the network. 
  discover_msg = "ZL\000\000\344D\312\000\310\fMu\330\fMuU|\350+\244Cu\004\310\fMu\330\fMu\360\350\031\000\324\243?u\333\243?u\265\257\253I\000\351\031\000\324\243?u\333\243?uE\256\253I@\000\000\000\b\000\000\000h\351\031\000)\201@u\310\fMu\330\350\031\000\364\352\031\000)\201@u\377\377\377\377\333\243?u.\243?u\340@\312\000h\351\031\000\330\fMuTCu\004\030\353Lu\340@\312\000\b\000\000\000\v\000\000\000h\351\031\000P\351\031\000\302\244?u\330\fMuh\351\031\000&R\312\000\345\220?urN"
  sock = UDPSocket.new
  sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, 1)
  sock.send(discover_msg, 0, "255.255.255.255",1092)
  
  start_time = Time.now
  loop do
    if (Time.now - start_time)*1000.0 > timeout_ms
      # timeout after read_timeout_ms
      sock.close
      return nil
    end
    if !sock.ready?
      # sleep 10ms is no data on socket.
      sleep 0.01
      next
    end
    recv_data = sock.recvfrom(1024)
    sock.close

    begin
      # find device ID
      # there is a lot of improvement to be made here for error checking....
      # also a lot of guesswork. 8888888888 was in my packet capture. 

      device_id = recv_data[0].force_encoding("iso-8859-1").split("8888888888")[1][0,6].unpack('H*').first
      puts "device id: #{device_id}"
    end
    return recv_data[1][2]
  end
end
###############################################################################

PIPE_DIRECTORY = "/usr/share/hassio/homeassistant/pipes"
PIPE_NAME = PIPE_DIRECTORY + "/host_executor_queue"
RUN_MODE_DAEMON   = 0
RUN_MODE_CONSOLE  = 1
# name the daemon based on the this file's name
PS_NAME = $0.match('([\w\_\.]+)\Z')[0]
PID_FILE = "/tmp/#{PS_NAME}.pid"
LOG_FILE = "/var/log/#{PS_NAME}.log"

run_mode = RUN_MODE_DAEMON
if ARGV.map(&:upcase).include?("CONSOLE")
  run_mode = RUN_MODE_CONSOLE
  puts "Running in console"
end


if File.exist?(PID_FILE)
  running_pid = File.read(PID_FILE).strip

  # see if process is still running. 
  `kill -0 #{running_pid} 1> /dev/null 2> /dev/null`

  if $?.exitstatus == 0
    if run_mode == RUN_MODE_CONSOLE
      puts "Killing existing running pid #{running_pid}"
      `kill -9 #{running_pid}`
    else
      $stderr.puts "a #{PS_NAME} process is already running with pid #{running_pid}"
      exit 1
    end
  else # pid file exists, but process is dead
    `rm #{PID_FILE}`
  end
end

unless run_mode == RUN_MODE_CONSOLE
  Daemonize.daemonize(LOG_FILE, PS_NAME)
end

# write the daemon's pid file
File.open(PID_FILE, 'w') do |f|
  f.write("#{$$}\n")
end



relay_ip = find_relay_ip()
puts "Relay board IP: #{relay_ip}"



# Recreate pipes if not exist
FileUtils.mkdir_p(PIPE_DIRECTORY) if !File.directory?(PIPE_DIRECTORY)

# recreate pipe
File.delete(PIPE_NAME) if File.exists?(PIPE_NAME)
File.mkfifo(PIPE_NAME)
FileUtils.chmod("a+rw", PIPE_NAME)

pipe = File.open(PIPE_NAME, "r+") 
while true
  FileUtils.touch(PID_FILE)
  puts pipe.gets  #I expect this to block and wait for input

  relay_ip = find_relay_ip()
  if !relay_ip
    puts "unable to find relay board"
    next
  end
  puts "Relay board IP: #{relay_ip}"

  
  @sock = TCPSocket.new(relay_ip, 4196)
  #toggle_relay(0xFF, RELAY_FLIP)
  pulse_relay(0, 500)
  @sock.close
end

File.delete(PID_FILE) if File.exist?(PID_FILE)