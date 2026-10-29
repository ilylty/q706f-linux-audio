#!/bin/sh
# 输出 0 = A 槽(Linux)，1 = B 槽(Android)
SLOT=$(tr ' ' '\n' < /proc/cmdline | grep -m1 '^slot_suffix=' | cut -d= -f2)
case "$SLOT" in
  _a) echo 0 ;;
  _b) echo 1 ;;
  *)  echo 0 ;;
esac
