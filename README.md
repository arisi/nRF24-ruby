nRF24-ruby
==========

Pure Ruby Driver and Utilitity with Http-server for the Ultra Cheap Radio Chip nRF24.
Early phases, but functional :)

##Installation:

On Ubuntu install first

``sudo apt-get install ruby ruby-dev build-essential nodejs``

and then

``gem install nRF-ruby``

##Connection:

Connect the radio module as follows (you can move CE and CS around, others are fixed):

|nRF24|Rpi|Function|Rpi Name
|-----|---|-|-
|8|11|IRQ|GPIO17
|3|13| CE|GPIO27
|4|15| CS|GPIO22
|2|17| 3V3|3V3
|6|19| MOSI|GPIO10 (MOSI)
|7|21| MISO|GPIO9 (MISO)
|5|23| SCLK|GPIO11 (SCLK)
|1|25| GND|GND

