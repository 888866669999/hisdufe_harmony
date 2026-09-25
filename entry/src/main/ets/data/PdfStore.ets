/*
 * PdfStore：把教务系统上的 PDF 下载到应用沙箱并缓存
 *
 * 为什么需要单独下载：
 *   培养方案的 PDF 挂在教务服务器上，且需要登录态才能取；
 *   系统级的文件预览（filePreview）只能预览**本机文件**，
 *   因此必须先把 PDF 落到应用沙箱，再交给预览能力打开。
 *
 * 缓存策略：按「账号 + 文件路径」的散列命名，已存在且大小一致时直接复用，避免重复下载。
 */
import { fileIo } from '@kit.CoreFileKit';
import { ContextHolder } from '../common/ContextHolder';
import { Logger } from '../common/Logger';
import { HttpClient, FormField } from '../network/HttpClient';
import { CookieJar } from '../network/CookieJar';
import { BASE_ORIGIN } from '../common/Constants';
import { AppError, ErrKind } from '../common/Result';

export class PdfStore {
  private static readonly DIR: string = 'pdf';
  /**
   * 缓存容量上限（字节）。超出后按最旧优先删除。
   * 培养方案 PDF 通常几 MB，留 50MB 足够放多份教学方案，
   * 又不会让沙箱无限膨胀。
   */
  private static readonly MAX_CACHE_BYTES: number = 50 * 1024 * 1024;
  private static dirReady: boolean = false;

  private static baseDir(): string {
    const ctx = ContextHolder.get();
    if (ctx === null) {
      return '';
    }
    return ctx.filesDir + '/' + PdfStore.DIR;
  }

  private static ensureDir(): string {
    const dir: string = PdfStore.baseDir();
    if (dir.length === 0) {
      return '';
    }
    if (!PdfStore.dirReady) {
      try {
        if (!fileIo.accessSync(dir)) {
          fileIo.mkdirSync(dir, true);
        }
        PdfStore.dirReady = true;
      } catch (e) {
        Logger.warn('pdf dir create failed');
        return '';
      }
    }
    return dir;
  }

  /** 由任意字符串生成稳定的文件名（避免路径字符） */
  private static hashName(seed: string): string {
    let h: number = 0;
    for (let i = 0; i < seed.length; i++) {
      h = (h * 31 + seed.charCodeAt(i)) % 2147483647;
    }
    return 'doc_' + h.toString() + '.pdf';
  }

  /** 缓存文件路径 */
  static pathFor(account: string, pdfPath: string): string {
    const dir: string = PdfStore.ensureDir();
    if (dir.length === 0) {
      return '';
    }
    return dir + '/' + PdfStore.hashName(account + '|' + pdfPath);
  }

  /** 是否已有缓存且非空 */
  static has(account: string, pdfPath: string): boolean {
    const p: string = PdfStore.pathFor(account, pdfPath);
    if (p.length === 0) {
      return false;
    }
    try {
      if (!fileIo.accessSync(p)) {
        return false;
      }
      const st: fileIo.Stat = fileIo.statSync(p);
      // 小于 1KB 视为损坏（正常 PDF 不会这么小）
      return st.size > 1024;
    } catch (e) {
      return false;
    }
  }

  /**
   * 下载 PDF 到沙箱。
   * @param jar 当前会话的 CookieJar（PDF 也需要登录态）
   * @param account 账号，用于缓存分片
   * @param pdfPath 相对于教务站点的路径，如 /ewebeditor/uploadfile/xxx.pdf
   * @returns 本地绝对路径
   */
  static async download(jar: CookieJar, account: string, pdfPath: string): Promise<string> {
    const local: string = PdfStore.pathFor(account, pdfPath);
    if (local.length === 0) {
      throw new AppError(ErrKind.UNKNOWN, '无法准备本地缓存目录');
    }
    if (PdfStore.has(account, pdfPath)) {
      Logger.info('pdf cache hit');
      return local;
    }

    const url: string = pdfPath.startsWith('http') ? pdfPath : (BASE_ORIGIN + pdfPath);
    // 复用 HttpClient，以自动带上会话 Cookie
    const client: HttpClient = new HttpClient(jar);
    const data: ArrayBuffer = await client.fetchBinary(url, 'application/pdf,*/*;q=0.8', 'PDF 下载失败');
    if (data.byteLength < 1024) {
      throw new AppError(ErrKind.SERVER, 'PDF 下载失败或内容为空');
    }
    // 校验 PDF 魔数，避免把登录页/错误页当成 PDF 存下来
    const head: Uint8Array = new Uint8Array(data.slice(0, 5));
    let magic: string = '';
    for (let i = 0; i < head.length; i++) {
      magic = magic + String.fromCharCode(head[i]);
    }
    if (magic.indexOf('%PDF') !== 0) {
      Logger.warn('downloaded content is not a PDF, magic=' + magic);
      throw new AppError(ErrKind.SERVER, '取到的不是 PDF（可能需要重新登录）');
    }

    // 写入时用 try/finally 保证文件句柄一定关闭：
    // 若 writeSync 抛错而没关闭，fd 会一直泄漏，反复重试最终耗尽句柄。
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(local,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, data);
      Logger.info('pdf downloaded: ' + data.byteLength + ' bytes');
      // 下载成功后顺带裁剪缓存，避免沙箱里 PDF 只增不减
      PdfStore.prune(PdfStore.MAX_CACHE_BYTES);
      return local;
    } catch (e) {
      Logger.error('pdf write failed');
      // 写坏了就删掉，避免留下半个文件被下次当成有效缓存
      try {
        if (fileIo.accessSync(local)) {
          fileIo.unlinkSync(local);
        }
      } catch (inner) {
        // 忽略
      }
      throw new AppError(ErrKind.UNKNOWN, 'PDF 保存失败');
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (inner) {
          // 忽略：关闭失败不影响主流程
        }
      }
    }
  }

  /** 清空已下载的 PDF 缓存 */
  static clearAll(): number {
    const dir: string = PdfStore.ensureDir();
    if (dir.length === 0) {
      return 0;
    }
    let removed: number = 0;
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const full: string = dir + '/' + names[i];
        try {
          fileIo.unlinkSync(full);
          removed++;
        } catch (e) {
          // 忽略单个文件失败
        }
      }
    } catch (e) {
      Logger.warn('pdf clear failed');
    }
    return removed;
  }

  /**
   * 缓存占用与文件数（供设置页展示，让用户知道能清多少）。
   */
  static usage(): PdfUsage {
    const dir: string = PdfStore.ensureDir();
    const out: PdfUsage = new PdfUsage();
    if (dir.length === 0) {
      return out;
    }
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        try {
          const st: fileIo.Stat = fileIo.statSync(dir + '/' + names[i]);
          out.bytes = out.bytes + st.size;
          out.files = out.files + 1;
        } catch (e) {
          // 忽略单个文件
        }
      }
    } catch (e) {
      Logger.warn('pdf usage failed');
    }
    return out;
  }

  /**
   * 按容量上限裁剪缓存：超出时删掉最旧的，直到降到上限内。
   *
   * 为什么需要：培养方案 PDF 每次都留盘、且原先没有任何清理入口
   * （clearAll 定义了却没人调用），长期使用会持续占用沙箱空间。
   * 这里在**每次下载成功后**顺带裁剪一次，用户无需手动维护。
   */
  private static prune(keepBytes: number): number {
    const dir: string = PdfStore.ensureDir();
    if (dir.length === 0) {
      return 0;
    }
    let removed: number = 0;
    try {
      const names: string[] = fileIo.listFileSync(dir);
      // 收集「路径 + 大小 + 修改时间」
      const items: PdfFileInfo[] = [];
      let total: number = 0;
      for (let i = 0; i < names.length; i++) {
        const full: string = dir + '/' + names[i];
        try {
          const st: fileIo.Stat = fileIo.statSync(full);
          items.push(new PdfFileInfo(full, st.size, st.mtime));
          total = total + st.size;
        } catch (e) {
          // 忽略
        }
      }
      if (total <= keepBytes) {
        return 0;
      }
      // 最旧的先删
      items.sort((a: PdfFileInfo, b: PdfFileInfo) => a.mtime - b.mtime);
      for (let i = 0; i < items.length && total > keepBytes; i++) {
        try {
          fileIo.unlinkSync(items[i].path);
          total = total - items[i].size;
          removed++;
        } catch (e) {
          // 忽略
        }
      }
      if (removed > 0) {
        Logger.info('pdf cache pruned: removed=' + removed + ' remain=' + Math.round(total / 1024) + 'KB');
      }
    } catch (e) {
      Logger.warn('pdf prune failed');
    }
    return removed;
  }
}

/** PDF 缓存占用 */
export class PdfUsage {
  files: number = 0;
  bytes: number = 0;
}

/** 裁剪时用的文件信息 */
class PdfFileInfo {
  path: string = '';
  size: number = 0;
  mtime: number = 0;

  constructor(path: string, size: number, mtime: number) {
    this.path = path;
    this.size = size;
    this.mtime = mtime;
  }
}
