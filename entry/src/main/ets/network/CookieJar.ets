/*
 * CookieJar：会话 cookie 管理
 *
 * 教务系统的 JSESSIONID 是 HttpOnly，页面 JS 读不到；
 * 原生请求里通过响应头的 Set-Cookie 拿到，并需要在后续请求手动回填 Cookie 头。
 *
 * 实现要点（两处都是踩过坑才这么写的）：
 *   1. **用 Map 而不是两个并行数组**。早先用 `names[]` + `values[]`，
 *      删除时要对两个数组各做一次 splice；而 HttpClient 与 CookieJar 都是单例，
 *      多个请求并发时会「一边遍历 toHeader、一边在 absorbCookies 里删除」，
 *      可能读到 `values[i] === undefined`，生成出 `NAME=undefined` 的请求头。
 *      Map 只有一个结构，天然避免这种错位。
 *   2. **一行里可能有多个 cookie**。Set-Cookie 用 `;` 分隔的是「属性」
 *      （Path/Domain/Expires 等），但同一个响应把多个 cookie 拼成一行的情况也存在。
 *      所以不能简单「只取第一个分号之前」——那会丢掉第二个 cookie（如负载均衡的
 *      SERVERID，丢了会破坏会话粘连，表现为偶发掉线）。
 *      这里逐个分段判断：是已知属性就跳过，否则当作 cookie。
 */

export class CookieJar {
  /** name -> value，保持插入顺序 */
  private jar: Map<string, string> = new Map<string, string>();

  /**
   * 已知的 cookie 属性名（小写）。
   * 分段出现在 `;` 之后、且名字命中这张表时按属性处理、不当作 cookie。
   */
  private static readonly ATTRS: string[] = [
    'path', 'domain', 'expires', 'max-age', 'secure', 'httponly',
    'samesite', 'version', 'comment', 'commenturl', 'port', 'discard'
  ];

  /** 从响应 cookies 数组或 Set-Cookie 字符串中吸收 cookie */
  absorbFromHeaders(raws: string[]): void {
    for (let i = 0; i < raws.length; i++) {
      this.absorbOne(raws[i]);
    }
  }

  /**
   * 吸收一行 Set-Cookie。
   *
   * 形状可能是：
   *   "JSESSIONID=abc"                              单个
   *   "JSESSIONID=abc; Path=/; HttpOnly"            单个 + 属性
   *   "JSESSIONID=abc; SERVERID=xyz"                两个 cookie 拼在一行
   * 因此逐段解析：第 0 段一定是 cookie；其后的段要么是属性（跳过），要么是另一个 cookie。
   */
  absorbOne(setCookie: string): void {
    if (setCookie === undefined || setCookie === null || setCookie.length === 0) {
      return;
    }
    const segs: string[] = setCookie.split(';');
    for (let i = 0; i < segs.length; i++) {
      const seg: string = segs[i].trim();
      if (seg.length === 0) {
        continue;
      }
      const eq: number = seg.indexOf('=');
      if (eq <= 0) {
        // 没有 `=` 的段是标志型属性（如 Secure / HttpOnly），跳过
        continue;
      }
      const name: string = seg.substring(0, eq).trim();
      const value: string = seg.substring(eq + 1).trim();
      if (name.length === 0) {
        continue;
      }
      // 第 0 段始终视为 cookie（即便它恰好叫 path 这种罕见名字），
      // 之后的段才按属性表过滤，避免误丢真实 cookie。
      if (i > 0 && CookieJar.ATTRS.indexOf(name.toLowerCase()) >= 0) {
        continue;
      }
      this.set(name, value);
    }
  }

  set(name: string, value: string): void {
    if (name.length === 0) {
      return;
    }
    if (value.length === 0) {
      // 值为空视为删除该 cookie
      this.jar.delete(name);
      return;
    }
    this.jar.set(name, value);
  }

  /** 生成 Cookie 请求头 */
  toHeader(): string {
    const parts: string[] = [];
    this.jar.forEach((value: string, name: string) => {
      // 防御：Map 里不该出现空值，真出现也绝不能拼成 NAME=undefined 发出去
      if (name !== undefined && name !== null && value !== undefined && value !== null) {
        parts.push(name + '=' + value);
      }
    });
    return parts.join('; ');
  }

  /** 序列化为可持久化的字符串 */
  serialize(): string {
    return this.toHeader();
  }

  /**
   * 供日志使用的脱敏摘要：**只给出 cookie 名与值的长度**，不给出值本身。
   *
   * ===== 为什么必须有这个方法（安全）=====
   * JSESSIONID 是**持有即可用**的凭据：拿到它就等于拿到该学生的登录态，
   * 不需要账号密码。而 hilog 是系统级日志，用户抓日志求助、系统收集
   * 日志上报时都可能带出去。原先几处调试日志直接把 `toHeader()` 的结果
   * 拼进日志（形如 `jar=[JSESSIONID=ABCDEF...]`），等于把会话凭据写进
   * 日志里。改用本方法后仍能看出「有几个 cookie、名字是什么、值多长」
   * —— 排查会话问题所需的信息都在，凭据本身不外泄。
   */
  toLogSummary(): string {
    const parts: string[] = [];
    this.jar.forEach((value: string, name: string) => {
      if (name !== undefined && name !== null) {
        const len: number = (value === undefined || value === null) ? 0 : value.length;
        parts.push(name + '=(' + len.toString() + '字符)');
      }
    });
    if (parts.length === 0) {
      return '空';
    }
    return parts.join(', ');
  }

  /** 从持久化字符串恢复 */
  deserialize(s: string): void {
    this.jar.clear();
    if (s === undefined || s === null || s.length === 0) {
      return;
    }
    const parts: string[] = s.split(';');
    for (let i = 0; i < parts.length; i++) {
      const item: string = parts[i].trim();
      if (item.length === 0) {
        continue;
      }
      const eq: number = item.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      this.set(item.substring(0, eq).trim(), item.substring(eq + 1).trim());
    }
  }

  /** 是否已有会话 */
  isEmpty(): boolean {
    return this.jar.size === 0;
  }

  clear(): void {
    this.jar.clear();
  }
}
