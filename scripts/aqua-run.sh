#!/bin/zsh
# 用法：aqua-run.sh <名字> <脚本路径> [等待秒数]
# 从后台会话（ssh、自动化代理的 shell 等 launchd Background 会话）跑时，钥匙串签名、open App 都要投递到图形会话 gui/<uid>。
# 这里把脚本包成一次性 LaunchAgent 跑，输出 build/jobs/<名字>.log，结束写 <名字>.done（内容 exit=N）。
# 给了等待秒数就阻塞等结果并打印日志。
set -e
ROOT=${0:A:h:h}
name=$1; script=${2:A}; wait_s=${3:-0}
J=$ROOT/build/jobs; mkdir -p $J
label=com.shicang.job.$name
plist=$J/$label.plist
rm -f $J/$name.log $J/$name.done
cat > $plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/bin/zsh</string><string>-c</string>
    <string>/bin/zsh '$script' > '$J/$name.log' 2>&amp;1; echo "exit=\$?" > '$J/$name.done'; /bin/launchctl bootout gui/$(id -u)/$label</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PL
launchctl bootout gui/$(id -u)/$label 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $plist
if (( wait_s > 0 )); then
  for i in {1..$((wait_s * 4))}; do [[ -f $J/$name.done ]] && break; /bin/sleep 0.25; done
  cat $J/$name.log 2>/dev/null
  if [[ -f $J/$name.done ]]; then cat $J/$name.done; grep -q "exit=0" $J/$name.done; else echo "（${wait_s}s 内没跑完，稍后看 $J/$name.log）"; exit 3; fi
else
  echo "已投递 $label → $J/$name.log"
fi
