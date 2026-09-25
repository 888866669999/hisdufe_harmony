#!/usr/bin/env bash
# 模拟器专用：构建 → 用 OpenHarmony 证书签名 → 安装 → 启动
#
# 为什么真机包和模拟器包不能混用：
#   真机（华为）只认 DevEco 自动签发的华为 debug profile；
#   模拟器（OpenHarmony）只认 SDK 内置的 OpenHarmony 证书链。
#   拿错一个就会报 fail to verify pkcs7 file / 9568332 sign info inconsistent。
#
# 本脚本刻意把产物写到 build/emu/，**不覆盖** hvigor 的
# entry-default-signed.hap —— 那是给真机用的华为签名包，
# 覆盖掉会导致之后往真机安装时静默装到错误签名的包。
#
# 用法: bash signing/emu-sign-install.sh [设备序列号]
set -euo pipefail

SERIAL="${1:-127.0.0.1:5555}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
# DevEco SDK 的安装位置随机器而异，因此允许用环境变量覆盖。
# 默认值是开发机的常见布局；换机器时设 DEVECO_HOME 即可，不必改脚本 ——
# 硬编码某台机器的绝对路径会让别人 clone 下来直接跑不通。
DEVECO="${DEVECO_HOME:-/d/DevEco Studio}"
LIB_WIN="${DEVECO_LIB_WIN:-D:\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\lib}"
JAVA="$DEVECO/jbr/bin/java.exe"
KEYTOOL="$DEVECO/jbr/bin/keytool.exe"
TOOL="$LIB_WIN\\hap-sign-tool.jar"
HDC="$DEVECO/sdk/default/openharmony/toolchains/hdc.exe"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw"
SIGN="$PROJ/signing"
OUTDIR="$PROJ/build/emu"
# OpenHarmony **SDK 内置**密钥库的口令。
#
# 这不是任何人的私密凭据：`OpenHarmony.p12` 随 SDK 一起分发，
# 所有安装该 SDK 的开发者手上都是同一份、口令也都是这个公开值。
# 它只能用于给模拟器签名（真机不认这条证书链，见文件头的说明），
# 所以写在这里是安全的 —— 特此注明，避免开源后被误认为泄露了密钥。
KS_PWD=123456
BUNDLE=com.sdufe.jwclient

mkdir -p "$SIGN" "$OUTDIR"
cd "$PROJ"

echo "== 1/7 构建 =="
"$HVIGOR" assembleHap --mode module -p product=default --no-daemon 2>&1 \
  | grep -E "ERROR|Error Message|BUILD" | tail -3

echo "== 2/7 导出 CA 证书（hap-sign-tool 要求 CA 以文件传入）=="
"$KEYTOOL" -exportcert -alias "openharmony application root ca" \
  -keystore "$LIB_WIN\\OpenHarmony.p12" -storetype PKCS12 -storepass "$KS_PWD" \
  -rfc -file "$SIGN\\root_ca.cer" >/dev/null
"$KEYTOOL" -exportcert -alias "openharmony application ca" \
  -keystore "$LIB_WIN\\OpenHarmony.p12" -storetype PKCS12 -storepass "$KS_PWD" \
  -rfc -file "$SIGN\\sub_ca.cer" >/dev/null

echo "== 3/7 取设备 UDID =="
UDID="$("$HDC" -t "$SERIAL" shell "bm get --udid" | tail -1 | tr -d '\r' | awk '{print $NF}')"
echo "   UDID=$UDID"

echo "== 4/7 生成 app 证书链 =="
"$JAVA" -jar "$TOOL" generate-app-cert \
  -keyAlias "openharmony application release" -signAlg "SHA256withECDSA" \
  -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
  -issuerKeyAlias "openharmony application ca" \
  -subject "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application Release" \
  -keystoreFile "$LIB_WIN\\OpenHarmony.p12" -keystorePwd "$KS_PWD" \
  -keyPwd "$KS_PWD" -issuerKeyPwd "$KS_PWD" -outForm certChain \
  -rootCaCertFile "$SIGN\\root_ca.cer" -subCaCertFile "$SIGN\\sub_ca.cer" \
  -outFile "$SIGN\\app.cer" >/dev/null

echo "== 5/7 生成 profile 签名证书 =="
"$JAVA" -jar "$TOOL" generate-profile-cert \
  -keyAlias "openharmony application profile debug" -signAlg "SHA256withECDSA" \
  -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
  -issuerKeyAlias "openharmony application ca" \
  -subject "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application Profile Debug" \
  -keystoreFile "$LIB_WIN\\OpenHarmony.p12" -keystorePwd "$KS_PWD" \
  -keyPwd "$KS_PWD" -issuerKeyPwd "$KS_PWD" -outForm certChain \
  -rootCaCertFile "$SIGN\\root_ca.cer" -subCaCertFile "$SIGN\\sub_ca.cer" \
  -outFile "$SIGN\\profile.cer" >/dev/null

echo "== 6/7 生成并签名调试 Profile =="
# 关键：Profile 内嵌的 development-certificate 必须与 app.cer 的**叶子证书**一致，
# 否则安装报 9568332。SDK 模板里内嵌的是另一张，所以必须由脚本改写。
node "$PROJ/signing/make-emu-profile.mjs" "$SIGN" "$UDID" "$BUNDLE"
"$JAVA" -jar "$TOOL" sign-profile \
  -keyAlias "openharmony application profile debug" -signAlg "SHA256withECDSA" \
  -mode "localSign" -profileCertFile "$SIGN\\profile.cer" \
  -inFile "$SIGN\\profile_unsigned.json" -keystoreFile "$LIB_WIN\\OpenHarmony.p12" \
  -outFile "$SIGN\\profile.p7b" -keyPwd "$KS_PWD" -keystorePwd "$KS_PWD" >/dev/null

echo "== 7/7 签名并安装 =="
UNSIGNED_ABS="$PROJ/entry/build/default/outputs/default/entry-default-unsigned.hap"
"$JAVA" -jar "$TOOL" sign-app \
  -keyAlias "openharmony application release" -signAlg "SHA256withECDSA" \
  -mode "localSign" -appCertFile "$SIGN\\app.cer" -profileFile "$SIGN\\profile.p7b" \
  -inFile "$(cygpath -w "$UNSIGNED_ABS")" -keystoreFile "$LIB_WIN\\OpenHarmony.p12" \
  -outFile "$(cygpath -w "$OUTDIR/entry-emu-signed.hap")" \
  -keyPwd "$KS_PWD" -keystorePwd "$KS_PWD" >/dev/null

# 先卸载：模拟器上可能残留用另一套证书装过的同名应用，
# 直接 -r 覆盖会因签名不一致失败。
"$HDC" -t "$SERIAL" uninstall "$BUNDLE" >/dev/null 2>&1 || true
"$HDC" -t "$SERIAL" install "$OUTDIR/entry-emu-signed.hap"
"$HDC" -t "$SERIAL" shell "aa start -b $BUNDLE -a EntryAbility" >/dev/null 2>&1 || true
echo "完成：已安装并启动到 $SERIAL"
