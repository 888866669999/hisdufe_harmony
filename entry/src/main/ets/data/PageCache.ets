/*
 * 页面数据的缓存层（内存 + 磁盘），与 Flutter 端 page_cache.dart 对齐。
 *
 * ===== 为什么需要它 =====
 * 外壳用 `if / else if` 链切换页面（Index.ets 的 content()），
 * 切一次 dock → 旧页 aboutToDisappear → 新页 aboutToAppear → 重新发请求。
 * 于是「课表→成绩→课表」来回切一次要打三个请求，而其中两次数据一个字都没变。
 * 课表早就有自己的缓存（TimetableStore：缓存优先、网络兜底），
 * 所以切到它从不闪加载态 —— 本文件把这套做法抽成通用的两层缓存。
 *
 * ===== 为什么缓存**服务器原文**而不是解析后的模型 =====
 * 缓存模型要手写每个类的序列化，会引入一类很难发现的静默错误：
 * **模型加了字段、序列化器忘了同步** —— 症状是「在线正常、离线缺字段」，
 * 而且不会有任何报错。缓存原文则让**解析器成为唯一真相**：
 * 缓存的数据走同一条解析路径，解析器修好 bug 后旧缓存自动被正确重读。
 * 代价只是进页面时解析一次（实测课表 3ms、成绩 0.8ms、培养方案 17ms）。
 *
 * ===== 三层结构与取数规则 =====
 *   内存层（进程内）    → 切页即时，不闪加载态
 *   磁盘层（按账号分片）→ 冷启动、离线时仍有内容
 *   网络层             → 只在「手动刷新 / 数据过期 / 压根没数据」时请求
 * 判据见 [PageDataLoader.load]。
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { ContextHolder } from '../common/ContextHolder';

/** 一条缓存记录：原文 + 抓取时刻 */
export class CachedPage {
  /** 服务器返回的**原始页面文本** */
  body: string;
  /**
   * 抓取时刻（毫秒）。
   * TTL 判断只用它，不用文件 mtime —— 写盘时间与「数据从服务器来的时刻」
   * 不是一回事（例如从磁盘读出来又原样写回，mtime 会更新，数据却更旧了）。
   */
  fetchedAt: number;

  constructor(body: string, fetchedAt: number) {
    this.body = body;
    this.fetchedAt = fetchedAt;
  }

  /** 数据年龄是否已超过 ttlMs */
  isStale(ttlMs: number): boolean {
    return Date.now() - this.fetchedAt > ttlMs;
  }
}

/** loader 取数的结果：数据从哪来 */
export enum PageDataSource {
  memory = 0,
  disk = 1,
  network = 2
}

/** 一次加载的结果 */
export class PageLoadResult<T> {
  data: T;
  source: PageDataSource;
  fromNetwork: boolean;

  constructor(data: T, source: PageDataSource) {
    this.data = data;
    this.source = source;
    this.fromNetwork = source === PageDataSource.network;
  }
}

/**
 * 页面数据缓存的统一入口。
 *
 * 内存与磁盘用**同一个 key**，key 里必须包含账号 —— 同机多账号时
 * 不能让 B 看到 A 的缓存（与 AppState 的登出清理保持同一条边界）。
 */
export class PageCache {
  /** 内存层：key → 记录。进程内共享，切页不丢 */
  private static memory: Map<string, CachedPage> = new Map<string, CachedPage>();
  private static readonly DIR: string = 'pagecache';
  /** 缓存文件版本。**改缓存的文件格式时才需要动它** */
  private static readonly VERSION: number = 1;

  /**
   * 拼缓存 key。
   *
   * 用 `|` 分隔各段，顺序固定为「账号 | 页面名 | 变体…」。
   * 变体用于有参数的数据：成绩按学期、空教室按查询条件。
   */
  static keyOf(account: string, name: string, variants?: string[]): string {
    let k: string = (account.length === 0 ? '_' : account) + '|' + name;
    if (variants !== undefined) {
      for (let i = 0; i < variants.length; i++) {
        k += '|' + variants[i];
      }
    }
    return k;
  }

  /** 读内存层（同步，供首帧直接渲染） */
  static peek(key: string): CachedPage | null {
    const hit: CachedPage | undefined = PageCache.memory.get(key);
    return hit === undefined ? null : hit;
  }

  /** 读磁盘层；不存在或损坏返回 null，并顺手清掉坏文件 */
  static readDisk(key: string): CachedPage | null {
    const p: string | null = PageCache.fileFor(key);
    if (p === null) {
      return null;
    }
    try {
      if (!fileIo.accessSync(p)) {
        return null;
      }
      const text: string = fileIo.readTextSync(p);
      if (text.length === 0) {
        return null;
      }
      const obj: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const ver: Object | undefined = obj.v;
      // 版本不符：直接丢弃（宁可重新请求，也不用格式不明的旧数据）
      if (typeof ver !== 'number' || ver > PageCache.VERSION) {
        PageCache.deleteQuietly(p);
        return null;
      }
      const body: Object | undefined = obj.body;
      const at: Object | undefined = obj.at;
      if (typeof body !== 'string' || body.length === 0 || typeof at !== 'number') {
        PageCache.deleteQuietly(p);
        return null;
      }
      const page: CachedPage = new CachedPage(body, at);
      // 读出来就放进内存层：同一次进程内再进这个页面就不用再读盘
      PageCache.memory.set(key, page);
      return page;
    } catch (e) {
      // 文件损坏（写到一半被杀、磁盘满…）→ 删掉它，让下次走网络。
      // 不删的话每次进页面都会重复解析失败、白等一次 IO。
      Logger.warn('[cache] read failed, dropping: ' + key);
      PageCache.deleteQuietly(p);
      return null;
    }
  }

  /** 写入两层（磁盘失败不影响内存层：本次会话仍然受益） */
  static write(key: string, body: string): void {
    const page: CachedPage = new CachedPage(body, Date.now());
    PageCache.memory.set(key, page);
    const p: string | null = PageCache.fileFor(key);
    if (p === null) {
      return;
    }
    try {
      const wrapper: Record<string, Object> = {
        'v': PageCache.VERSION,
        'at': page.fetchedAt,
        'body': body
      };
      PageCache.writeText(p, JSON.stringify(wrapper));
    } catch (e) {
      Logger.warn('[cache] write failed: ' + key);
    }
  }

  /**
   * 清掉某账号的**全部**缓存（登出时调用）。
   *
   * 内存层按 key 前缀匹配（key 以账号开头）；磁盘层靠文件名前缀匹配。
   * 这是「换账号后 B 不能看到 A 数据」这条边界的最后一环 ——
   * 漏了它，B 进成绩页会先看到 A 的成绩、再被网络响应覆盖。
   */
  static clearAccount(account: string): void {
    if (account.length === 0) {
      return;
    }
    const prefix: string = account + '|';
    const doomed: string[] = [];
    PageCache.memory.forEach((_v: CachedPage, k: string) => {
      if (k.startsWith(prefix)) {
        doomed.push(k);
      }
    });
    for (let i = 0; i < doomed.length; i++) {
      PageCache.memory.delete(doomed[i]);
    }

    const dir: string = PageCache.dirPath();
    const filePrefix: string = PageCache.safe(account) + '_';
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        if (names[i].startsWith(filePrefix)) {
          PageCache.deleteQuietly(dir + '/' + names[i]);
        }
      }
    } catch (e) {
      // 目录不存在等情况：没有东西可清
    }
  }

  // ==================== 内部 ====================

  private static dirPath(): string {
    const ctx: common.UIAbilityContext | common.Context | null = ContextHolder.getAny();
    const base: string = ctx === null ? '' : ctx.filesDir;
    return base + '/' + PageCache.DIR;
  }

  /** key → 文件绝对路径；上下文不可用时返回 null */
  private static fileFor(key: string): string | null {
    const ctx: common.UIAbilityContext | common.Context | null = ContextHolder.getAny();
    if (ctx === null) {
      return null;
    }
    const dir: string = PageCache.dirPath();
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    } catch (e) {
      return null;
    }
    return dir + '/' + PageCache.safe(key) + '.json';
  }

  /**
   * 把 key 变成安全的文件名，形如 `<账号>_<其余部分的编码>`。
   *
   * 账号放最前是为了 [clearAccount] 能按前缀清理。
   *
   * 其余部分**用十六进制编码而不是哈希**：哈希有碰撞可能，而碰撞的后果是
   * 「两个不同页面互相覆盖缓存」—— 症状是进 A 页看到 B 页的内容，
   * 只在特定页面组合下复现，极难排查。
   */
  private static safe(key: string): string {
    const bar: number = key.indexOf('|');
    const account: string = bar > 0 ? key.substring(0, bar) : key;
    const rest: string = bar > 0 ? key.substring(bar) : '';
    let safeAccount: string = '';
    for (let i = 0; i < account.length; i++) {
      const c: string = account.charAt(i);
      const ok: boolean =
          (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          c === '.' || c === '_' || c === '-';
      safeAccount += ok ? c : '_';
    }
    if (rest.length === 0) {
      return safeAccount;
    }
    let out: string = '';
    for (let i = 0; i < rest.length; i++) {
      const code: number = rest.charCodeAt(i);
      const plain: boolean =
          (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5A) ||
          (code >= 0x61 && code <= 0x7A) || code === 0x2E || code === 0x2D || code === 0x5F;
      if (plain) {
        out += rest.charAt(i);
      } else {
        out += '%' + code.toString(16).padStart(4, '0');
      }
    }
    return safeAccount + '_' + out;
  }

  /** 写文本；父目录不存在时先建（与 TimetableStore 的写法一致） */
  private static writeText(path: string, text: string): void {
    let file: fileIo.File | null = null;
    try {
      // 用 try/finally 保证文件句柄一定关闭：writeSync 若抛错而没关闭，
      // 后续写入会因句柄泄漏而失败
      file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          // 忽略关闭失败
        }
      }
    }
  }

  private static deleteQuietly(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      // 忽略：删不掉不影响主流程
    }
  }
}

/**
 * 页面数据加载器：把「两层缓存 + 取数规则」编排成一个方法。
 *
 * 每个页面只写三件事：
 *   1. 缓存 key（[PageCache.keyOf]，含账号与页面参数）；
 *   2. 怎么从服务器拿原文（`() => api.getXxxHtml()`）；
 *   3. 怎么把原文解析成模型。
 * 其余（读内存、读盘、判断要不要联网、写回两层）都由本类负责，
 * 这样五个页面的取数逻辑完全一致，不会各写各的、渐渐走偏。
 */
export class PageDataLoader<T> {
  /** 缓存 key（必须含账号） */
  private key: string;
  /** 请求服务器**原文** */
  private fetch: () => Promise<string>;
  /** 原文 → 模型 */
  private parse: (body: string) => T;
  /** 数据在这个时长内视为新鲜（不联网） */
  private ttlMs: number;

  constructor(key: string, fetch: () => Promise<string>, parse: (body: string) => T, ttlMs: number) {
    this.key = key;
    this.fetch = fetch;
    this.parse = parse;
    this.ttlMs = ttlMs;
  }

  /**
   * 同步读内存层：用于**首帧**判断能否直接渲染。
   *
   * 单独提供是因为 [load] 是异步的，而页面希望第一帧就有内容：
   * 先 peek 到内容就渲染，再 await load 决定要不要联网 ——
   * 这样切页完全没有加载态闪烁。
   */
  peek(): T | null {
    const hit: CachedPage | null = PageCache.peek(this.key);
    if (hit === null) {
      return null;
    }
    try {
      return this.parse(hit.body);
    } catch (e) {
      // 内存里的原文解析失败（解析器改过了？）→ 当作没有，
      // 让 load() 去读磁盘或走网络
      Logger.warn('[cache] parse failed (memory): ' + this.key);
      return null;
    }
  }

  /**
   * 只读缓存（内存 → 磁盘），**绝不联网**；没有缓存返回 null。
   *
   * 存在的理由是「强制刷新失败后回退到上次成功的数据」：
   * 那种场景下不能复用 [load] —— load 在缓存过期时会去联网，
   * 而这时联网正是刚刚失败的那件事，再走一遍只是白等一次超时。
   */
  async loadCached(): Promise<T | null> {
    let hit: CachedPage | null = PageCache.peek(this.key);
    if (hit === null) {
      hit = PageCache.readDisk(this.key);
    }
    if (hit === null) {
      return null;
    }
    try {
      return this.parse(hit.body);
    } catch (e) {
      Logger.warn('[cache] parse failed (cached): ' + this.key);
      return null;
    }
  }

  /**
   * 按「缓存优先、网络兜底」取数。
   *
   * [force] 为 true 表示这是用户主动刷新：只要网络成功就用新数据，
   * 失败则把异常抛给调用方 —— 但**不会**因为失败就把已有缓存丢掉
   * （调用方拿到异常后仍然可以继续显示旧内容）。
   */
  async load(force: boolean): Promise<PageLoadResult<T>> {
    // 1) 内存层
    const mem: CachedPage | null = PageCache.peek(this.key);
    if (mem !== null && !force && !mem.isStale(this.ttlMs)) {
      try {
        return new PageLoadResult<T>(this.parse(mem.body), PageDataSource.memory);
      } catch (e) {
        Logger.warn('[cache] parse failed (memory), falling back: ' + this.key);
      }
    }

    // 2) 磁盘层（readDisk 命中时会写回内存层）
    const disk: CachedPage | null = PageCache.readDisk(this.key);
    if (disk !== null && !force && !disk.isStale(this.ttlMs)) {
      try {
        return new PageLoadResult<T>(this.parse(disk.body), PageDataSource.disk);
      } catch (e) {
        Logger.warn('[cache] parse failed (disk), falling back: ' + this.key);
      }
    }

    // 3) 网络。到达这里说明：没有缓存、缓存过期、或用户要求强制刷新。
    const body: string = await this.fetch();
    // 只有成功才写缓存 —— 失败时保留旧的（可能已过期，但比没有强）
    PageCache.write(this.key, body);
    return new PageLoadResult<T>(this.parse(body), PageDataSource.network);
  }
}
