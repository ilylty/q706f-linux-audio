#!/bin/sh
S=$(tr ' ' '\n' < /proc/cmdline | grep -m1 '^slot_suffix=' | cut -d= -f2)
case "$S" in
  _a) echo "槽位 A Linux" ;;
  _b) echo "槽位 B Android" ;;
  *)  echo "槽位 A Linux" ;;
esac
