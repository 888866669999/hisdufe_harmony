/*
 * CampusCalendarService：从学校官网获取校历与作息表
 *
 * 数据来源：山东财经大学「校园服务 → 最新校历」
 *   https://www.sdufe.edu.cn/xyfw/zxxl.htm
 *
 * 这个页面**是可以直接抓的**（实测无 UA / Referer / Cookie 要求）：
 *   正文里有一张 HTML 表格「日常教学时刻表」，
 *   两张校历图片挂在 `/virtual_attach_file.vsb?...e=.jpg` 这类地址上。
 *   两年前写 AcademicCalendar 时判断「页面是图片 + JS 反爬、抓不到」，
 *   那个结论对正文的数字部分并不成立，因此这里补上联网获取。
 *
 * 策略：**联网抓最新 → 落盘缓存 → 离线用缓存 → 首次无网用内置兜底**
 *   1. 作息时刻决定「上课提醒」的触发时间，网络抖动不该让提醒算错；
 *   2. 校历图是两张 1MB+ 的大图，每次打开都下载既慢又费流量；
 *   3. 学校一学期才更新一次，没必要每次刷新。
 *
 * 安全：**刻意不复用教务系统的 HttpClient**。那个客户端的 CookieJar
 * 按整串 Cookie 头存储、不带域名作用域，请求头里还硬编码了教务系统的
 * Origin/Referer。用它访问公网校网，等于把教务系统的会话 JSESSIONID
 * 发给第三方站点。这里用独立的裸 http 客户端，不带任何 Cookie。
 */
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { ContextHolder } from '../common/ContextHolder';
import { Logger } from '../common/Logger';
import { UrlGuard } from '../common/UrlGuard';
import {
  KEY_CAMPUS_SECTIONS, KEY_CAMPUS_IMAGES, KEY_CAMPUS_IMAGE_URLS,
  KEY_CAMPUS_UPDATED, KEY_CAMPUS_FETCHED_AT, CAMPUS_DIR
} from '../common/Constants';
import { PrefStore } from './PrefStore';
import { CampusCalendarParser } from '../parser/CampusCalendarParser';
import { AcademicCalendar, OFFICIAL_SECTIONS, OfficialSection } from './AcademicCalendar';
import { SectionTimeStore, SectionTime } from './SectionTimeStore';

/** 官网校历页地址 */
export const CALENDAR_PAGE_URL: string = 'https://www.sdufe.edu.cn/xyfw/zxxl.htm';

/** 校历抓取允许访问的主机（含子域）。地址由页面内容决定，限定域名可掐断「被篡改后指向任意站点」。 */
const CAMPUS_ALLOWED_HOSTS: string[] = ['sdufe.edu.cn'];

/** 抓取结果 */
export class CampusCalendar {
  /** 作息行（`第一、二节  08:30 - 10:00` / `课间休息  10:00 - 10:20`） */
  sections: string[] = [];
  /** 校历图片的**本地绝对路径**（下载成功才有） */
  images: string[] = [];
  /** 官网标注的更新时间，如 `2026年7月` */
  updated: string = '';
  /** true = 本次联网抓到的；false = 缓存或内置兜底 */
  live: boolean = false;

  hasImages(): boolean {
    return this.images.length > 0;
  }
}

export class CampusCalendarService {
  private static mem: CampusCalendar | null = null;
  /** 上次刷新的错误（供设置页展示，空表示没问题） */
  private static lastError: string = '';

  static errorText(): string {
    return CampusCalendarService.lastError;
  }

  // ==================== 缓存路径 ====================

  private static baseDir(): string {
    const ctx = ContextHolder.get();
    if (ctx === null) {
      return '';
    }
    return ctx.filesDir + '/' + CAMPUS_DIR;
  }

  private static ensureDir(): string {
    const dir: string = CampusCalendarService.baseDir();
    if (dir.length === 0) {
      return '';
    }
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    } catch (e) {
      Logger.warn('campus dir create failed');
      return '';
    }
    return dir;
  }

  private static pathFor(index: number): string {
    const dir: string = CampusCalendarService.ensureDir();
    if (dir.length === 0) {
      return '';
    }
    return dir + '/calendar_' + index.toString() + '.jpg';
  }

  // ==================== 读取（不联网）====================

  /** 从缓存 / 内置构造数据 */
  private static async offline(): Promise<CampusCalendar> {
    const out: CampusCalendar = new CampusCalendar();
    const cachedSections: string[] = CampusCalendarService.split(
      await PrefStore.getText(KEY_CAMPUS_SECTIONS));
    out.sections = cachedSections.length > 0
      ? cachedSections : AcademicCalendar.sectionLines();
    out.images = CampusCalendarService.existingImages(
      CampusCalendarService.split(await PrefStore.getText(KEY_CAMPUS_IMAGES)));
    out.updated = await PrefStore.getText(KEY_CAMPUS_UPDATED);
    out.live = false;
    return out;
  }

  /** 当前可用的校历（内存 → 缓存 → 内置） */
  static async load(): Promise<CampusCalendar> {
    if (CampusCalendarService.mem !== null) {
      return CampusCalendarService.mem;
    }
    CampusCalendarService.mem = await CampusCalendarService.offline();
    return CampusCalendarService.mem;
  }

  /** 缓存是否过期（从未抓过也算过期），默认 7 天 */
  static async isStale(maxAgeMs: number = 7 * 24 * 3600 * 1000): Promise<boolean> {
    const raw: string = await PrefStore.getText(KEY_CAMPUS_FETCHED_AT);
    const at: number = parseInt(raw, 10);
    if (isNaN(at) || at <= 0) {
      return true;
    }
    return Date.now() - at > maxAgeMs;
  }

  // ==================== 抓取 ====================

  /**
   * 联网抓最新校历与作息；成功则落盘并返回，失败返回 null（保留原缓存）
   *
   * **从不抛异常**：校历抓不到不该影响任何主流程。
   */
  static async refresh(): Promise<CampusCalendar | null> {
    CampusCalendarService.lastError = '';
    const req: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: {
          // 只带最小必要头；实测该站对 UA 不挑剔，给个常规值更稳妥
          'User-Agent': 'Mozilla/5.0 (Phone; HarmonyOS) AppleWebKit/537.36 ' +
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'zh-CN,zh;q=0.9'
          // 刻意不带 Cookie / Origin / Referer
        } as Record<string, string>,
        connectTimeout: 15000,
        readTimeout: 25000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      };

      // 首跳也校验（虽然这是我们自己写的常量，但保持一致：所有出站请求都过 UrlGuard）
      UrlGuard.check(CALENDAR_PAGE_URL, CAMPUS_ALLOWED_HOSTS);
      const res: http.HttpResponse = await req.request(CALENDAR_PAGE_URL, options);
      if (res.responseCode !== 200) {
        CampusCalendarService.lastError = '校历页返回 ' + res.responseCode.toString();
        return null;
      }
      const html: string = typeof res.result === 'string'
        ? res.result as string : JSON.stringify(res.result);

      const sections: string[] = CampusCalendarParser.sectionLines(html);
      const urls: string[] = CampusCalendarParser.imageUrls(html, CALENDAR_PAGE_URL);
      const updated: string = CampusCalendarParser.updated(html);

      // 图片逐张下载（最多两张：两个学期）
      const local: string[] = [];
      const limit: number = urls.length < 2 ? urls.length : 2;
      for (let i = 0; i < limit; i++) {
        const p: string = await CampusCalendarService.downloadImage(urls[i], i);
        if (p.length > 0) {
          local.push(p);
        }
      }

      // 两者都没解析出来（学校改版）就不要覆盖已有缓存，宁可继续用旧的
      if (sections.length === 0 && local.length === 0) {
        CampusCalendarService.lastError = '未能从校历页解析出作息表或校历图';
        return null;
      }

      const out: CampusCalendar = new CampusCalendar();
      out.sections = sections.length > 0
        ? sections : (await CampusCalendarService.offline()).sections;
      out.images = local.length > 0
        ? local : (await CampusCalendarService.offline()).images;
      out.updated = updated;
      out.live = true;

      await CampusCalendarService.savePrefs(out, urls);
      // 官网作息「顺手」同步到本地（仅在用户没自定义过时），
      // 这样上课提醒用的是官网最新时刻，而不是随包固化的旧值。
      if (out.sections.length > 0) {
        await CampusCalendarService.applyOfficialSectionsIfDefault(out.sections);
      }
      CampusCalendarService.mem = out;
      Logger.info('campus calendar refreshed, images=' + out.images.length.toString());
      return out;
    } catch (e) {
      CampusCalendarService.lastError = '网络异常';
      Logger.warn('campus calendar refresh failed: ' + JSON.stringify(e));
      return null;
    } finally {
      req.destroy();
    }
  }

  /** 下载一张校历图到沙箱；失败返回空串 */
  private static async downloadImage(url: string, index: number): Promise<string> {
    const path: string = CampusCalendarService.pathFor(index);
    if (path.length === 0) {
      return '';
    }
    // 图片地址来自**官网页面解析结果**，属不可信输入：
    // 限定域名 + 拒绝环回/私有/保留地址，避免页面被篡改后
    // 把应用当成内网扫描器（SSRF）。
    try {
      UrlGuard.check(url, CAMPUS_ALLOWED_HOSTS);
    } catch (e) {
      Logger.warn('campus image blocked by UrlGuard: ' + url);
      return CampusCalendarService.exists(path) ? path : '';
    }
    const req: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: { 'Accept': 'image/*' } as Record<string, string>,
        connectTimeout: 15000,
        readTimeout: 30000,
        usingCache: false,
        // 图片必须按二进制取，按 STRING 取会损坏 JPEG
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      };
      const res: http.HttpResponse = await req.request(url, options);
      if (res.responseCode !== 200) {
        return CampusCalendarService.exists(path) ? path : '';
      }
      const buf: ArrayBuffer = res.result as ArrayBuffer;
      if (buf === undefined || buf === null || buf.byteLength < 1024) {
        return CampusCalendarService.exists(path) ? path : '';
      }
      // JPEG 魔数校验：抓回来的可能是 HTML 错误页，别把错误页当图片存下来
      const head: Uint8Array = new Uint8Array(buf.slice(0, 2));
      if (head.length < 2 || head[0] !== 0xFF || head[1] !== 0xD8) {
        return CampusCalendarService.exists(path) ? path : '';
      }
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, buf);
      } finally {
        fileIo.closeSync(file);
      }
      return path;
    } catch (e) {
      Logger.warn('campus image download failed: ' + JSON.stringify(e));
      return CampusCalendarService.exists(path) ? path : '';
    } finally {
      req.destroy();
    }
  }

  private static async savePrefs(c: CampusCalendar, urls: string[]): Promise<void> {
    await PrefStore.putText(KEY_CAMPUS_SECTIONS, c.sections.join('\n'));
    await PrefStore.putText(KEY_CAMPUS_IMAGES, c.images.join('\n'));
    await PrefStore.putText(KEY_CAMPUS_IMAGE_URLS, urls.join('\n'));
    await PrefStore.putText(KEY_CAMPUS_UPDATED, c.updated);
    await PrefStore.putText(KEY_CAMPUS_FETCHED_AT, Date.now().toString());
  }

  /** 清掉缓存（设置页用） */
  static async clearCache(): Promise<void> {
    const dir: string = CampusCalendarService.baseDir();
    if (dir.length > 0) {
      try {
        if (fileIo.accessSync(dir)) {
          fileIo.rmdirSync(dir);
        }
      } catch (e) {
        Logger.warn('campus cache clear failed');
      }
    }
    CampusCalendarService.mem = null;
    await PrefStore.putText(KEY_CAMPUS_SECTIONS, '');
    await PrefStore.putText(KEY_CAMPUS_IMAGES, '');
    await PrefStore.putText(KEY_CAMPUS_IMAGE_URLS, '');
    await PrefStore.putText(KEY_CAMPUS_UPDATED, '');
  }

  /** 设置页一行摘要：让用户知道现在用的是联网版、缓存还是内置版 */
  /**
   * 设置页的副标题：只说「能不能看」，不暴露数据来源与缓存细节。
   *
   * 刻意**不**显示「已获取官网最新版 / 显示上次缓存的版本 / 更新于 x」——
   * 那些是内部策略，用户看到只会多出「数据是不是过期了」的疑问。
   * 唯一值得外显的是「学校官网更新到哪一版」这个**官方信息**。
   */
  static async hint(c: CampusCalendar): Promise<string> {
    if (c.updated.length === 0) {
      return '查看官方校历与作息表';
    }
    return '官网 ' + c.updated + ' 版';
  }

  // ==================== 小工具 ====================

  private static split(raw: string): string[] {
    const out: string[] = [];
    if (raw.trim().length === 0) {
      return out;
    }
    const parts: string[] = raw.split('\n');
    for (let i = 0; i < parts.length; i++) {
      const t: string = parts[i].trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }

  private static exists(p: string): boolean {
    try {
      return fileIo.accessSync(p);
    } catch (e) {
      return false;
    }
  }

  /** 只保留磁盘上确实存在的图片路径 */
  private static existingImages(paths: string[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < paths.length; i++) {
      if (CampusCalendarService.exists(paths[i])) {
        out.push(paths[i]);
      }
    }
    return out;
  }

  /**
   * 若用户**没有自定义过**作息，就用官网最新值刷新本地作息。
   *
   * 只在 `SectionTimeStore.isDefault()` 为真时写入 —— 用户手动调过的时间
   * 是用户意图，不能被一次联网静默覆盖。返回是否发生了更新。
   */
  static async applyOfficialSectionsIfDefault(sectionLines: string[]): Promise<boolean> {
    const rows: string[][] = CampusCalendarParser.mapToGridRows(sectionLines);
    if (rows.length !== 5) {
      return false;
    }
    await SectionTimeStore.load();
    if (!SectionTimeStore.isDefault()) {
      return false;
    }
    const official: OfficialSection[] = OFFICIAL_SECTIONS;
    let changed: boolean = false;
    for (let i = 0; i < 5; i++) {
      if (official[i].start !== rows[i][0] || official[i].end !== rows[i][1]) {
        changed = true;
        break;
      }
    }
    if (!changed) {
      return false;
    }
    const list: SectionTime[] = [];
    for (let i = 0; i < 5; i++) {
      list.push(new SectionTime(i, official[i].label, rows[i][0], rows[i][1]));
    }
    await SectionTimeStore.save(list);
    Logger.info('sections updated from official site');
    return true;
  }

}
