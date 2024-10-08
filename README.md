# modbus_relay
modbus_relay is a project which controls an ethernet Waveshare Modbus POE ETH Relay Module  
https://www.waveshare.com/modbus-poe-eth-relay.htm


modbus_relay listens on a FIFO pipe and when data is received, it will pulse Relay 1 and 2 simultaneously for 250 ms. This is used in conjunction with Home Assistant to actuate a 24VAC home doorbell chime.  It is designed to run in either daemon mode (default) or in console (good for debugging). Any time data is received on the pipe, it will attempt to find a relay board on the network and actuate the relay. 

The program creates and listens on the following FIFO pipe:  
`/usr/share/hassio/homeassistant/pipes/host_executor_queue`

When the program is running, you can send commands with this:  
`echo 123 >  /usr/share/hassio/homeassistant/pipes/host_executor_queue`

Within Home Assistant, you can send commands to this pipe with the following shell command:  
`echo 123  > /config/pipes/host_executor_queue`

# Configuration of the Waveshare Modbus Relay Module
Device Information: https://www.waveshare.com/modbus-poe-eth-relay.htm  
Cost is roughly $36 - $50 on Amazon.  
https://www.amazon.com/Industrial-Modbus-RTU-Relay-Protection/dp/B083J24HCM  
https://www.amazon.com/waveshare-Ethernet-Communication-Isolation-Protection/dp/B0CDGR7KFZ  


The WIKI is a good start to understanding how to manage the relay board device. There is a link to two Windows applications - Vircom and Sscom.

Vircom is used to find and configure the relay board. The relay board comes with a default static IP address of 192.168.1.200/24. There is no need to reconfigure your host to be on the 192.168.1.x network, ad the Vircom software can find the relay board through UDP broadcast messages as seen int he Vircom Device Manager:
![alt text](vircom_device_manager.jpg)


Using the `Edit Device` button allows you to configure the network. Address the device as appropriate for your network (a static IP address is not required for this application). The important parts to configure for this application are:
- Port: 4196  
- Work Mode: TCP Server  

![alt text](vircom_device_setings.jpg)

# Installation of modbus_relay prerequisites
- Install ruby  
`sudo apt install ruby`

- Install ruby gems  
`sudo gem install daemons fileutils digest-crc logger` 

# Usage

It is recommended to initially run the modbus_relay program in console mode to make sure it can find the relay board on the network.  
`sudo ./modbus_relay console`

```
sudo ./modbus_relay console
I, [2024-08-19T22:39:04.769196 #15199]  INFO -- : Starting Modbus Relay in console mode
I, [2024-08-19T22:39:04.793252 #15199]  INFO -- : Found relay board 28712E94FF66: 192.168.200.195
```

Running in console mode, you can type commands which will trigger a relay event. For example, after startup I typed `STDIN Pipe Data` followed by Enter and it caused Relay 3 to pulse for 250ms and the associated bytes sent and received from the relay board. The current implementation does not 

```
sudo ./modbus_relay console
I, [2024-08-19T22:49:52.797950 #16660]  INFO -- : Starting Modbus Relay in console mode
I, [2024-08-19T22:49:52.826587 #16660]  INFO -- : Found relay board 28712E94FF66: 192.168.200.195
STDIN Pipe Data
I, [2024-08-19T22:50:00.583477 #16660]  INFO -- : Received on pipe: STDIN Pipe Data
I, [2024-08-19T22:50:00.593937 #16660]  INFO -- : Relay board 28712E94FF66 IP: 192.168.200.195
D, [2024-08-19T22:50:00.595250 #16660] DEBUG -- : Pulsing relay 1 for 250ms.
D, [2024-08-19T22:50:00.595530 #16660] DEBUG -- : Sending bytes:  0x01 0x05 0x02 0x02 0x00 0x02 0xEC 0x73
D, [2024-08-19T22:50:00.606018 #16660] DEBUG -- : Received bytes: 0x01 0x05 0x02 0x02 0x00 0x02 0xEC 0x73
```

From another terminal window, you can send the application messages through echoing data to the pipe path:  
`echo 123 >  /usr/share/hassio/homeassistant/pipes/host_executor_queue`

Ideally the modbus_relay program will be running as a daemon. Installing modbus_relay as a daemon is accomplished with the following command:  
`sudo modbus_relay install`

And started with:  
`sudo modbus_relay install`  or `systemctl start modbus_relay`  

When running in the background as a daemon or service, the log output is located at `/var/log/modbus_relay.log`

# Integration with Home Assistant
The purpose of interfacing with the WAVESHARE PoE Relay Board was to find a way for my ReoLink doorbell cameras to ring a traditional existing 24VAC doorbell chime system. The chimes include with the Reolink are not really suitable for a larger house and in my opinion are cheap and not very attractive. Not to mention the sound doesn't compare to what you would expect out of a traditional doorbell chime.  

Home Assistant(HA) integrates well with the ReoLink doorbells, so I thought it would be simple enough for HA to invoke an executable. I quickly found out that invoking commands using the shell_command is limited to executables within the container. My application was running on the host Linux subsystem. I needed a way to easily send messages from the HA container to the host OS.

I came across an article referencing how to use FIFO pipes to facilitate this interprocess communication:
    https://community.home-assistant.io/t/running-commands-on-the-host-without-ssh/510481

Essentially you create a names pipe on the host OS:
```
cd /usr/share/hassio/homeassistant
sudo mkdir pipes
cd pipes
sudo mkfifo host_executor_queue
```

From the HA container you can send commands to the pipe by using the `shell_command:`:
```
shell_command:
  some_command: echo some_script > /config/pipes/host_executor_queue
```


If you create a pipe on the host with the path:
	/usr/share/hassio/homeassistant/pipes/host_executor_queue

It is accessible from the HA container with the following path:
	/config/pipes/host_executor_queue


When running modbus_relay on the host operating system, it will trigger toggling a relay whenever data is received on the FIFO pipes. To configure Home Assistant to be able to send to these pipes the `configuration.yaml` file must be edited first to add in the `shell_command` section. This example will send the message `front_door` to the FIFO pipe when the `shell_command.ring_doorbell_front_door` is executed, and will send the message `side_door` to the FIFO pipe when the `shell_command.ring_doorbell_side_door` is executed

configuration.yaml:  
```
shell_command:
  ring_doorbell_front_door: echo front_door > /config/pipes/host_executor_queue
  ring_doorbell_side_door: echo side_door  > /config/pipes/host_executor_queue
```
Home Assistant must be restarted or the configuration file must be reloaded to take effect. 

Sample Automation YAML. the important information contained in this automation is the action line:  
 `action: shell_command.ring_doorbell_front_door`
```
alias: Front Door Ring
description: ""
trigger:
  - type: turned_on
	platform: device
	device_id: aed6134c41e9dcbf656bd61146e409ae
	entity_id: e573da9fe099b62bcf366f719eda8224
	domain: binary_sensor
condition: []
action:
  - data: {}
	action: shell_command.ring_doorbell_front_door
mode: single
```

# Work Remaining / Other Useful Features / General Rambling
- Configuration file to specify the IP address or device id of the relay board. Currently the relay board must be on the same layer-2 network as the service (will not cross routers/nat)
- Command line argument to find all relay boards on the network. 
- Use the pipe data to specify the relay(s) and pulse time. For example, sending a command `1,250;2,500` would pulse relay 1 for 250ms and relay 2 for 500 ms. 
- Since doorbell use can be infrequent (less than a few times a months at my house), a periodic check of the health/reachability of the relay board could be useful, and some sort of notification if the board is not present on the network. 
- Simplified configuration of the relay board without requiring VirtCom