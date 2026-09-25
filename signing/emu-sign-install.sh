#!/usr/bin/env bash
# 模拟器专用：构建 → 用 OpenHarmony 证书签名 → 安装 → 启动
#
# 真机只认华为证书链、模拟器只认 OpenHarmony 证书链，两者不可混用（混了会报
# fail to verify pkcs7 file / 9568332）。本脚本产出到 build/emu/，刻意不覆盖
# entry-default-signed.hap —— 那是给真机装的那份。
#
# 用法: OPENHARMONY_KEYSTORE_PWD=<口令> bash signing/emu-sign-install.sh [设备序列号]
set -euo pipefail

SERIAL="${1:-127.0.0.1:5555}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
DEVECO="${DEVECO_HOME:-/d/DevEco Studio}"
LIB_WIN="${DEVECO_LIB_WIN:-D:\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\lib}"
JAVA="$DEVECO/jbr/bin/java.exe"
TOOL="$LIB_WIN\\hap-sign-tool.jar"
HDC="$DEVECO/sdk/default/openharmony/toolchains/hdc.exe"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw"
SIGN="$PROJ/signing"
OUTDIR="$PROJ/build/emu"
BUNDLE=com.sdufe.jwclient

# OpenHarmony SDK 内置密钥库（OpenHarmony.p12）的口令。它随 SDK 公开分发、
# 不是私密凭据，但仍要求由调用方提供 —— 口令不写进任何文件。
KS_PWD="${OPENHARMONY_KEYSTORE_PWD:?请先设置 OPENHARMONY_KEYSTORE_PWD（OpenHarmony.p12 的口令）}"

mkdir -p "$OUTDIR"
cd "$PROJ"

echo "== 1/6 构建 =="
"$HVIGOR" assembleHap --mode module -p product=default --no-daemon 2>&1 \
  | grep -E "ERROR|Error Message|BUILD" | tail -3

echo "== 2/6 取设备 UDID =="
UDID="$("$HDC" -t "$SERIAL" shell "bm get --udid" | tail -1 | tr -d '\r' | awk '{print $NF}')"
echo "   UDID=$UDID"

# CA 用仓库里的 signing/oh-*.cer（SDK 里那两份的副本），不必每次从密钥库导出。
echo "== 3/6 生成 app 证书链 =="
"$JAVA" -jar "$TOOL" generate-app-cert \
  -keyAlias "openharmony application release" -signAlg "SHA256withECDSA" \
  -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
  -issuerKeyAlias "openharmony application ca" \
  -subject "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application Release" \
  -keystoreFile "$LIB_WIN\\OpenHarmony.p12" -keystorePwd "$KS_PWD" \
  -keyPwd "$KS_PWD" -issuerKeyPwd "$KS_PWD" -outForm certChain \
  -rootCaCertFile "$SIGN\\oh-root-ca.cer" -subCaCertFile "$SIGN\\oh-sub-ca.cer" \
  -outFile "$SIGN\\app.cer" >/dev/null

echo "== 4/6 生成 profile 签名证书 =="
"$JAVA" -jar "$TOOL" generate-profile-cert \
  -keyAlias "openharmony application profile debug" -signAlg "SHA256withECDSA" \
  -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
  -issuerKeyAlias "openharmony application ca" \
  -subject "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application Profile Debug" \
  -keystoreFile "$LIB_WIN\\OpenHarmony.p12" -keystorePwd "$KS_PWD" \
  -keyPwd "$KS_PWD" -issuerKeyPwd "$KS_PWD" -outForm certChain \
  -rootCaCertFile "$SIGN\\oh-root-ca.cer" -subCaCertFile "$SIGN\\oh-sub-ca.cer" \
  -outFile "$SIGN\\profile.cer" >/dev/null

echo "== 5/6 生成并签名调试 Profile =="
# Profile 内嵌的 development-certificate 必须与 app.cer 的叶子证书一致，
# 否则安装报 9568332；SDK 模板里内嵌的是另一张，所以由脚本改写后重签。
node "$SIGN/make-emu-profile.mjs" "$SIGN" "$UDID" "$BUNDLE"
"$JAVA" -jar "$TOOL" sign-profile \
  -keyAlias "openharmony application profile debug" -signAlg "SHA256withECDSA" \
  -mode "localSign" -profileCertFile "$SIGN\\profile.cer" \
  -inFile "$SIGN\\profile_unsigned.json" -keystoreFile "$LIB_WIN\\OpenHarmony.p12" \
  -outFile "$SIGN\\profile.p7b" -keyPwd "$KS_PWD" -keystorePwd "$KS_PWD" >/dev/null

echo "== 6/6 签名并安装 =="
UNSIGNED_ABS="$PROJ/entry/build/default/outputs/default/entry-default-unsigned.hap"
"$JAVA" -jar "$TOOL" sign-app \
  -keyAlias "openharmony application release" -signAlg "SHA256withECDSA" \
  -mode "localSign" -appCertFile "$SIGN\\app.cer" -profileFile "$SIGN\\profile.p7b" \
  -inFile "$(cygpath -w "$UNSIGNED_ABS")" -keystoreFile "$LIB_WIN\\OpenHarmony.p12" \
  -outFile "$(cygpath -w "$OUTDIR/entry-emu-signed.hap")" \
  -keyPwd "$KS_PWD" -keystorePwd "$KS_PWD" >/dev/null

# 先卸载：残留的旧包若用的是另一套证书，-r 覆盖会因签名不一致失败。
"$HDC" -t "$SERIAL" uninstall "$BUNDLE" >/dev/null 2>&1 || true
"$HDC" -t "$SERIAL" install "$OUTDIR/entry-emu-signed.hap"
"$HDC" -t "$SERIAL" shell "aa start -b $BUNDLE -a EntryAbility" >/dev/null 2>&1 || true
echo "完成：已安装并启动到 $SERIAL"
