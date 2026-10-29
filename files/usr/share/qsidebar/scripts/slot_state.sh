#!/bin/sh
S=$(tr ' ' '\n' < /proc/cmdline | grep -m1 '^slot_suffix=' | cut -d= -f2)
[ "$S" = "_b" ] && echo 1 || echo 0
