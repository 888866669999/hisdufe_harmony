#!/usr/bin/env bash
# 【已废弃】请改用 signing/emu-sign-install.sh
#
# 本脚本（连同同目录的 deploy.sh）是早期版本，已被 signing/emu-sign-install.sh 取代。
# 它有两个问题：
#   1. 签出的产物覆盖 entry-default-signed.hap，那是 hvigor 用华为证书签的
#      **真机包**；覆盖后若再往真机安装，会静默装到 OpenHarmony 签名的包上而失败。
#   2. 复用固定生成的 app.cer / profile，没有把「Profile 里内嵌的叶子证书必须与
#      app.cer 一致」这件事固化进流程，换设备或换 SDK 后容易复现 9568332。
#
# 新脚本会自行重新生成证书链、绑定设备 UDID，并把产物写到 build/emu/，不污染真机包。
echo "本脚本已废弃，请使用：bash signing/emu-sign-install.sh" >&2
exit 1
