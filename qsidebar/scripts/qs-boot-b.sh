#!/bin/sh
/usr/local/bin/bootslot b --no-reboot && sync && systemctl reboot
