#!/bin/bash

pio run -t upload --upload-port $( ls -1 /dev/cu.usbserial-* | head -n 1 )

