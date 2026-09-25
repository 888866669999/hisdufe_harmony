#!/usr/bin/env bash
# 【已废弃】请改用 signing/emu-sign-install.sh
#
# 见同目录 build.sh 的说明：旧流程会覆盖真机签名包，且没有把
# 「Profile 内嵌叶子证书必须与 app.cer 一致」固化进流程。
echo "本脚本已废弃，请使用：bash signing/emu-sign-install.sh" >&2
exit 1
