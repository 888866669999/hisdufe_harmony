/*
 * UrlGuard：出站请求的 URL/主机校验（SSRF 防护）
 *
 * ===== 为什么需要它 =====
 * 本应用有两处**从远端 HTML 里解析出 URL 再发请求**的地方：
 *   1. 校历图：从官网页面 `<img src=...>` 取地址后下载
 *      （见 CampusCalendarService）；
 *   2. 培养方案 PDF：从页面里正则出附件路径后下载（见 PdfStore）。
 * 这两条链路的 URL 完全由**服务端返回的内容**决定。若页面被篡改、
 * 或链路被中间人改写，攻击者就能让应用去请求
 * `http://127.0.0.1:8080/...`、`http://192.168.1.1/...` 这类**内网地址** ——
 * 手机上的应用一旦能访问内网，就变成了扫描器/跳板（经典 SSRF）。
 *
 * 因此规则是：**只允许 http/https、发请求前校验 host、
 * 拒绝 localhost / 环回 / 私有 / 保留地址**。
 *
 * ===== 为什么不能只做字符串匹配 =====
 * IP 有大量等价写法，只按字面判断会被绕过：
 *   `http://2130706433/`（十进制）、`http://0x7f000001/`（十六进制）、
 *   `http://017700000001/`（八进制）、`http://127.1/`（省略段）、
 *   `http://[::ffff:127.0.0.1]/`（IPv6 映射）。
 * 它们全都会连到 127.0.0.1。所以这里先把各种写法**归一化成 32 位整数**
 * 再按网段判断，而不是比对字符串。
 */

/** 允许的协议 */
const ALLOWED_SCHEMES: string[] = ['http', 'https'];

/** 明确禁止的主机名（小写） */
const BLOCKED_NAMES: string[] = [
  'localhost',
  'localhost.localdomain',
  'ip6-localhost',
  'ip6-loopback'
];

/** 被禁止的主机后缀（本地网络 / mDNS / 内网习惯命名） */
const BLOCKED_SUFFIXES: string[] = ['.localhost', '.local', '.internal'];

export class UrlGuard {
  /**
   * 校验一个 URL 是否允许请求；不通过则抛错。
   *
   * @param url 待校验的绝对地址
   * @param allowedHosts 若非空，则主机必须在此白名单内（更严格）。
   *        用于「本来就知道该从哪个域名取数据」的场景
   *        （校历只应来自学校域名）。
   */
  static check(url: string, allowedHosts: string[] | null = null): void {
    const scheme: string = UrlGuard.schemeOf(url);
    if (scheme.length === 0) {
      throw new Error('无法解析的地址');
    }
    if (ALLOWED_SCHEMES.indexOf(scheme) < 0) {
      throw new Error('协议不允许（只允许 http/https）');
    }
    const host: string = UrlGuard.hostOf(url);
    if (host.length === 0) {
      throw new Error('主机为空');
    }

    // 白名单优先：命中后仍继续做私网检查，
    // 避免「白名单里误写了内网地址」这种配置错误
    if (allowedHosts !== null && allowedHosts.length > 0) {
      let ok: boolean = false;
      for (let i = 0; i < allowedHosts.length; i++) {
        const h: string = allowedHosts[i].toLowerCase();
        if (host === h || (host.length > h.length + 1 &&
          host.substring(host.length - h.length - 1) === '.' + h)) {
          ok = true;
          break;
        }
      }
      if (!ok) {
        throw new Error('主机不在允许列表内');
      }
    }

    for (let i = 0; i < BLOCKED_NAMES.length; i++) {
      if (host === BLOCKED_NAMES[i]) {
        throw new Error('禁止访问本机主机');
      }
    }
    for (let i = 0; i < BLOCKED_SUFFIXES.length; i++) {
      const suf: string = BLOCKED_SUFFIXES[i];
      if (host.length > suf.length &&
        host.substring(host.length - suf.length) === suf) {
        throw new Error('禁止访问本地网络主机');
      }
    }

    // IP 字面量：先尝试解析，再按网段判断。
    // 必须区分「解析成功」与「根本没解析成 IP」，否则会把
    // 8.8.8.8 这类**合法公网 IP** 一起误杀。
    const v4: number = UrlGuard.parseIpv4(host);
    if (v4 >= 0) {
      if (UrlGuard.isBlockedIpv4(v4)) {
        throw new Error('禁止访问环回/私有/保留地址');
      }
      return;
    }
    if (host.indexOf(':') >= 0) {
      if (UrlGuard.isBlockedIpv6(host)) {
        throw new Error('禁止访问环回/私有/保留地址');
      }
      return;
    }
    // 走到这里说明**不是可解析的 IP**。若它「看起来像 IP 字面量」，
    // 说明是「想写 IP 却写错」，一律拒绝（fail-closed）——
    // `999.999.999.999` / `256.1.1.1` 不拦会被当成域名放行。
    if (UrlGuard.looksLikeIpLiteral(host)) {
      throw new Error('非法的 IP 字面量');
    }
  }

  /** 校验通过返回 true（不抛异常的版本） */
  static isAllowed(url: string, allowedHosts: string[] | null = null): boolean {
    try {
      UrlGuard.check(url, allowedHosts);
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---------- URL 拆解（不依赖 URL 类，避免各版本行为差异）----------

  /** 取协议（小写）；无法解析返回空串 */
  static schemeOf(url: string): string {
    const i: number = url.indexOf('://');
    if (i <= 0) {
      return '';
    }
    const s: string = url.substring(0, i).toLowerCase();
    // 协议只允许字母与 `+.-`，避免 `jar:http://` 这类被当成协议
    if (!/^[a-z][a-z0-9+.-]*$/.test(s)) {
      return '';
    }
    return s;
  }

  /** 取主机（小写、去掉 IPv6 方括号与端口）；无法解析返回空串 */
  static hostOf(url: string): string {
    const i: number = url.indexOf('://');
    if (i <= 0) {
      return '';
    }
    let rest: string = url.substring(i + 3);
    // 去路径 / 查询 / 片段
    const cut: number = UrlGuard.minIndex(rest, ['/', '?', '#']);
    if (cut >= 0) {
      rest = rest.substring(0, cut);
    }
    // 去 userinfo（user:pass@host）—— 注意找最后一个 @ 之前的都要丢弃
    const at: number = rest.lastIndexOf('@');
    if (at >= 0) {
      rest = rest.substring(at + 1);
    }
    if (rest.length === 0) {
      return '';
    }
    // IPv6：[::1]:8080
    if (rest.charAt(0) === '[') {
      const close: number = rest.indexOf(']');
      if (close < 0) {
        return '';
      }
      return rest.substring(0, close + 1).toLowerCase();
    }
    // 去端口
    const colon: number = rest.indexOf(':');
    if (colon >= 0) {
      rest = rest.substring(0, colon);
    }
    return rest.toLowerCase();
  }

  private static minIndex(s: string, chars: string[]): number {
    let out: number = -1;
    for (let i = 0; i < chars.length; i++) {
      const p: number = s.indexOf(chars[i]);
      if (p >= 0 && (out < 0 || p < out)) {
        out = p;
      }
    }
    return out;
  }

  // ---------- IP 解析（等价写法归一化）----------

  /**
   * 把主机名按 IPv4 解析成 32 位整数；不是 IPv4 字面量返回 -1。
   *
   * 兼容：`a.b.c.d`、`a.b.c`、`a.b`、`a`（省略段按低位补齐）、
   * 十进制整数、`0x` 十六进制、前导 0 的八进制。
   */
  static parseIpv4(host: string): number {
    if (host.length === 0) {
      return -1;
    }
    const parts: string[] = host.split('.');
    if (parts.length === 0 || parts.length > 4) {
      return -1;
    }
    const nums: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const n: number = UrlGuard.parseIpv4Part(parts[i]);
      if (n < 0) {
        return -1;
      }
      nums.push(n);
    }
    // 最后一段承载其余位
    const last: number = nums[nums.length - 1];
    let value: number = 0;
    for (let i = 0; i < nums.length - 1; i++) {
      if (nums[i] > 255) {
        return -1;
      }
      value = value * 256 + nums[i];
    }
    const remainingBytes: number = 4 - (nums.length - 1) - 1;
    if (remainingBytes < 0) {
      return -1;
    }
    const bits: number = 8 * (remainingBytes + 1);
    // 2^bits 上限（bits 可能到 32，用浮点算再比较，避免位移按 32 取模）
    const maxLast: number = Math.pow(2, bits) - 1;
    if (last > maxLast) {
      return -1;
    }
    value = value * Math.pow(2, bits) + last;
    // 收敛到 32 位无符号
    if (value > 0xFFFFFFFF) {
      return -1;
    }
    return value;
  }

  /** 解析单个 IPv4 片段：十进制 / 0x 十六进制 / 前导 0 八进制 */
  private static parseIpv4Part(s: string): number {
    if (s.length === 0) {
      return -1;
    }
    const t: string = s.toLowerCase();
    let v: number = -1;
    if (t.indexOf('0x') === 0) {
      v = parseInt(t.substring(2), 16);
    } else if (t.length > 1 && t.charAt(0) === '0') {
      // 前导 0 按八进制（与 inet_aton 行为一致）
      v = parseInt(t.substring(1), 8);
    } else {
      v = parseInt(t, 10);
    }
    if (isNaN(v) || v < 0) {
      return -1;
    }
    return v;
  }

  /** 私网 / 环回 / 保留的 IPv4 段 */
  static isBlockedIpv4(v: number): boolean {
    const a: number = Math.floor(v / 16777216) % 256;
    const b: number = Math.floor(v / 65536) % 256;
    if (a === 0) {
      return true;            // 0.0.0.0/8 本网络
    }
    if (a === 10) {
      return true;            // 10.0.0.0/8 私有
    }
    if (a === 127) {
      return true;            // 127.0.0.0/8 环回
    }
    if (a === 100 && b >= 64 && b <= 127) {
      return true;            // 100.64.0.0/10 运营商级 NAT
    }
    if (a === 169 && b === 254) {
      return true;            // 169.254.0.0/16 链路本地（云元数据在此段）
    }
    if (a === 172 && b >= 16 && b <= 31) {
      return true;            // 172.16.0.0/12 私有
    }
    if (a === 192 && (b === 0 || b === 2)) {
      return true;            // 192.0.0.0/24 保留、192.0.2.0/24 文档用
    }
    if (a === 192 && b === 168) {
      return true;            // 192.168.0.0/16 私有
    }
    if (a === 198 && (b === 18 || b === 19)) {
      return true;            // 198.18.0.0/15 基准测试
    }
    if (a === 198 && b === 51) {
      return true;            // 198.51.100.0/24 文档用
    }
    if (a === 203 && b === 0) {
      return true;            // 203.0.113.0/24 文档用
    }
    if (a >= 224) {
      return true;            // 224.0.0.0/4 组播 + 240.0.0.0/4 保留
    }
    return false;
  }

  /** 私网 / 环回 / 保留的 IPv6 */
  static isBlockedIpv6(host: string): boolean {
    let s: string = host;
    if (s.charAt(0) === '[' && s.charAt(s.length - 1) === ']') {
      s = s.substring(1, s.length - 1);
    }
    const pct: number = s.indexOf('%');
    if (pct >= 0) {
      s = s.substring(0, pct);
    }
    const t: string = s.toLowerCase();
    if (t.length === 0) {
      return true;
    }
    // IPv4 映射与兼容写法：取后 32 位按 IPv4 判断
    const prefixes: string[] = ['::ffff:', '::'];
    for (let i = 0; i < prefixes.length; i++) {
      const pre: string = prefixes[i];
      if (t.indexOf(pre) === 0 && t.indexOf('.') >= 0) {
        const v4: number = UrlGuard.parseIpv4(t.substring(pre.length));
        if (v4 >= 0) {
          return UrlGuard.isBlockedIpv4(v4);
        }
      }
    }
    const g: number[] = UrlGuard.groupsOfIpv6(t);
    if (g.length !== 8) {
      return false;
    }
    // 未指定（::）与环回（::1）—— 按展开后的 8 组判断，
    // 否则 `0:0:0:0:0:0:0:1` 这种全写形式会漏过去（Flutter 版实测踩到过）
    let allZeroExceptLast: boolean = true;
    for (let i = 0; i < 7; i++) {
      if (g[i] !== 0) {
        allZeroExceptLast = false;
        break;
      }
    }
    if (allZeroExceptLast && (g[7] === 0 || g[7] === 1)) {
      return true;
    }
    if ((g[0] & 0xFE00) === 0xFC00) {
      return true;            // fc00::/7 唯一本地
    }
    if ((g[0] & 0xFFC0) === 0xFE80) {
      return true;            // fe80::/10 链路本地
    }
    if ((g[0] & 0xFF00) === 0xFF00) {
      return true;            // ff00::/8 组播
    }
    if (g[0] === 0x2001 && g[1] === 0x0DB8) {
      return true;            // 2001:db8::/32 文档用
    }
    return false;
  }

  /** 展开 IPv6 为 8 组 16 位；无法解析返回空数组 */
  private static groupsOfIpv6(t: string): number[] {
    const halves: string[] = t.split('::');
    if (halves.length > 2) {
      return [];
    }
    const parse = (part: string): number[] => {
      const out: number[] = [];
      const gs: string[] = part.split(':');
      for (let i = 0; i < gs.length; i++) {
        const g: string = gs[i];
        if (g.length === 0) {
          continue;
        }
        const v: number = parseInt(g, 16);
        if (isNaN(v)) {
          return [];
        }
        out.push(v);
      }
      return out;
    };
    const head: number[] = parse(halves[0]);
    if (halves.length === 1) {
      return head.length === 8 ? head : [];
    }
    const tail: number[] = parse(halves[1]);
    const fill: number = 8 - head.length - tail.length;
    if (fill < 0) {
      return [];
    }
    const out: number[] = [];
    for (let i = 0; i < head.length; i++) {
      out.push(head[i]);
    }
    for (let i = 0; i < fill; i++) {
      out.push(0);
    }
    for (let i = 0; i < tail.length; i++) {
      out.push(tail[i]);
    }
    return out;
  }

  /** 主机是否「看起来是 IP 字面量」而非域名 */
  private static looksLikeIpLiteral(host: string): boolean {
    if (host.length === 0) {
      return false;
    }
    let t: string = host;
    if (t.charAt(0) === '[' && t.charAt(t.length - 1) === ']') {
      t = t.substring(1, t.length - 1);
    }
    if (t.length === 0) {
      return false;
    }
    // 只允许 0-9 . : a-f x %（域名至少含一个 g-z 的字母）
    return /^[0-9a-fx:.%]+$/.test(t);
  }
}