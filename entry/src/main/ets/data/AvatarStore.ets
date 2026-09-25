/*
 * AvatarStore：自定义头像的保存 / 读取 / 清除
 *
 * ===== 存哪里（与 Flutter 端 avatar_store.dart 同一策略）=====
 * 把用户选中的图片**复制**到应用文件目录下的 `avatar/`，而不是记住相册里
 * 那个 URI。原因很实际：相册里的原图随时可能被用户删掉，而选择器给出的
 * URI 不带持久读权限 —— 直接记路径的做法会在某次重启后让头像变成空白，
 * 且原因极难联想。复制一份之后头像就是应用自己的资源了。
 *
 * ===== 文件名带版本号（而不是固定 avatar.png）=====
 * 换头像时文件内容变了、路径若不变，ArkUI 的 Image 会直接命中它自己的
 * 解码缓存 —— 表现是「保存成功了但界面还是旧头像」，只能杀进程才好。
 * 追加查询串（`?v=2`）不行：那会被当成文件路径的一部分而打不开。
 * 因此每次保存写一个新名字 `avatar_<时间戳>.png`，并把同目录下的旧文件
 * 删掉 —— 目录里始终只有一个文件，路径每次都变，缓存无从命中。
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ContextHolder } from '../common/ContextHolder';
import { Logger } from '../common/Logger';

export class AvatarStore {
  private static readonly DIR: string = 'avatar';
  private static readonly PREFIX: string = 'avatar_';
  private static readonly SUFFIX: string = '.png';

  /** 内存缓存：避免头像组件每帧都做一次 listFile 同步 IO */
  private static cached: string | null = null;
  /** 是否已经查过（用于区分「没查过」与「查过但没有」） */
  private static probed: boolean = false;

  private static dirPath(): string {
    const ctx: common.Context | null = ContextHolder.getAny();
    if (ctx === null) {
      return '';
    }
    return ctx.filesDir + '/' + AvatarStore.DIR;
  }

  /** 目录里现有的头像文件；没有返回空串（目录里至多一个） */
  private static existing(): string {
    const dir: string = AvatarStore.dirPath();
    if (dir.length === 0) {
      return '';
    }
    try {
      if (!fileIo.accessSync(dir)) {
        return '';
      }
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const n: string = names[i];
        if (n.startsWith(AvatarStore.PREFIX) && n.endsWith(AvatarStore.SUFFIX)) {
          return dir + '/' + n;
        }
      }
    } catch (e) {
      Logger.warn('avatar list failed');
    }
    return '';
  }

  /** 头像文件绝对路径；未设置时返回空串 */
  static current(): string {
    if (AvatarStore.probed) {
      return AvatarStore.cached === null ? '' : AvatarStore.cached;
    }
    AvatarStore.probed = true;
    const p: string = AvatarStore.existing();
    AvatarStore.cached = p.length > 0 ? p : null;
    return p;
  }

  /** 是否已有自定义头像 */
  static has(): boolean {
    return AvatarStore.current().length > 0;
  }

  /** 供 Image 组件用的 URI；未设置时返回空串 */
  static uri(): string {
    const p: string = AvatarStore.current();
    return p.length === 0 ? '' : ('file://' + p);
  }

  /**
   * 从选择器给出的 URI 复制一份到应用目录。
   *
   * 先把内容读进内存再写目标文件，而不是 fileIo.copyFile —— 选择器给的是
   * `file://media/...` 这类由媒体库托管的路径，直接拷有时会因权限/句柄失败，
   * 读 + 写两条标准接口更稳。
   *
   * @param srcUri 选择器返回的 URI（形如 file://media/Photo/...）
   * @returns 成功时返回新的头像路径，失败返回空串
   */
  static async saveFrom(srcUri: string): Promise<string> {
    const dir: string = AvatarStore.dirPath();
    if (dir.length === 0 || srcUri.length === 0) {
      return '';
    }
    const old: string = AvatarStore.current();
    let src: fileIo.File | null = null;
    let dst: fileIo.File | null = null;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const target: string = dir + '/' + AvatarStore.PREFIX +
        Date.now().toString() + AvatarStore.SUFFIX;

      src = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(src.fd);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      const read: number = fileIo.readSync(src.fd, buf);
      if (read <= 0) {
        return '';
      }

      dst = fileIo.openSync(target,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(dst.fd, buf);

      AvatarStore.cached = target;
      AvatarStore.probed = true;
      // 旧头像在新文件写成功后才删：中途失败时旧头像仍可用
      AvatarStore.removeQuietly(old);
      return target;
    } catch (e) {
      Logger.warn('avatar save failed: ' + e);
      return '';
    } finally {
      AvatarStore.closeQuietly(src);
      AvatarStore.closeQuietly(dst);
    }
  }

  /** 清除自定义头像（回到姓名末字的占位） */
  static async clear(): Promise<void> {
    const p: string = AvatarStore.current();
    AvatarStore.cached = null;
    AvatarStore.probed = true;
    AvatarStore.removeQuietly(p);
  }

  private static removeQuietly(p: string): void {
    if (p.length === 0) {
      return;
    }
    try {
      if (fileIo.accessSync(p)) {
        fileIo.unlinkSync(p);
      }
    } catch (e) {
      Logger.warn('avatar remove failed');
    }
  }

  private static closeQuietly(f: fileIo.File | null): void {
    if (f === null) {
      return;
    }
    try {
      fileIo.closeSync(f);
    } catch (e) {
      // 关闭失败无需处理
    }
  }
}
