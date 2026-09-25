#!/usr/bin/env node
/*
 * 生成模拟器用的未签名调试 Profile。
 *
 * 关键点：Profile 里的 development-certificate 必须与 app.cer 的**叶子证书**
 * 完全一致。SDK 自带的模板（UnsgnedDebugProfileTemplate.json）内嵌的是另一张证书，
 * 直接拿来用会导致安装时报 9568332 "install sign info inconsistent"。
 *
 * 用法: node signing/make-emu-profile.mjs <sign目录> <UDID> <bundleName>
 */
import fs from 'node:fs';
import path from 'node:path';

const [signDir, udid, bundleName] = process.argv.slice(2);
if (!signDir || !udid || !bundleName) {
  console.error('用法: node make-emu-profile.mjs <sign目录> <UDID> <bundleName>');
  process.exit(1);
}

const TEMPLATE = 'D:\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\lib\\UnsgnedDebugProfileTemplate.json';

const tpl = JSON.parse(fs.readFileSync(TEMPLATE, 'utf8'));
tpl['bundle-info']['bundle-name'] = bundleName;
tpl['bundle-info']['developer-id'] = 'OpenHarmony';

// 取 app.cer 的第一张证书（叶子）作为开发证书
const chain = fs.readFileSync(path.join(signDir, 'app.cer'), 'utf8');
const certs = chain.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g);
if (!certs || certs.length === 0) {
  console.error('app.cer 中未找到证书');
  process.exit(1);
}
tpl['bundle-info']['development-certificate'] = certs[0] + '\n';

// 只允许这台模拟器安装
tpl['debug-info']['device-ids'] = [udid];
tpl['debug-info']['device-id-type'] = 'udid';

// 长有效期，避免调试期间过期
tpl['validity'] = { 'not-before': 1594862078, 'not-after': 2220225678 };
tpl['acls'] = { 'allowed-acls': [''] };
tpl['permissions'] = { 'restricted-permissions': [''] };

const out = path.join(signDir, 'profile_unsigned.json');
fs.writeFileSync(out, JSON.stringify(tpl, null, 2), 'utf8');
console.log(`   profile 已生成（叶子证书已绑定，UDID=${udid}）`);
