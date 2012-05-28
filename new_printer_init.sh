#!/bin/sh

rm -f /etc/avahi/services/printer_*
airprint-generate --directory=/etc/avahi/services/ --prefix=printer_
service samba reload
