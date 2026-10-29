#!/bin/sh
# 当前在 A → 提示切到 B；当前在 B → 提示切到 A
S=$(tr ' ' '\n' < /proc/cmdline | grep -m1 '^slot_suffix=' | cut -d= -f2)
if [ "$S" = "_a" ]; then
  # 在 Linux，问是否切到 Android
  TARGET=b
  MSG="当前在 A 槽（Linux）。\\n\\n切换到 B 槽（Android）并重启？"
else
  TARGET=a
  MSG="当前在 B 槽（Android）。\\n\\n切换到 A 槽（Linux）并重启？"
fi
if command -v zenity >/dev/null 2>&1; then
  zenity --question --title="切换启动槽" --text="$MSG" --width=400 2>/dev/null || exit 0
elif command -v yad >/dev/null 2>&1; then
  yad --question --title="切换启动槽" --text="$MSG" || exit 0
fi
/usr/local/bin/bootslot "$TARGET" --no-reboot && sync && systemctl reboot
