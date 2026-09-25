/*
 * CredentialStore：账号密码的可选安全保存
 *
 * 实现方式：系统密钥库 Asset Store（@kit.AssetStoreKit）。
 * 为什么用它而不是 preferences：
 *   - 密钥库条目由系统加密保护，可设置为「首次解锁后可读」，
 *     不会被同设备其他应用或普通文件读取到；
 *   - preferences 是明文存储，不适合放密码。
 *
 * 隐私约定：只有用户在登录页显式勾选「记住账号密码」时才写入；
 * 取消勾选或退出登录时主动删除。默认不勾选。
 */
import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';

/** 保存的凭据 */
export class Credential {
  account: string = '';
  password: string = '';

  constructor(account: string, password: string) {
    this.account = account;
    this.password = password;
  }
}

export class CredentialStore {
  /** 固定别名：账号与密码打包为一个 secret 存储 */
  private static readonly ALIAS: string = 'sdufe_jw_credential';
  /** 账号与密码的分隔符（换行不会出现在账号/密码中） */
  private static readonly SEP: string = '\n';

  /**
   * 读取结果的内存缓存 + 共享 Promise。
   *
   * 为什么必须做这两件事：
   *   1. **并发去重**：启动阶段 `Index.restore` 会调 `refreshCredentialFlag()`，
   *      同时 `verifySessionInBackground` 也会查一次凭据。两路并发打同一个
   *      密钥库接口时，主线程曾出现过卡死（appfreeze THREAD_BLOCK_6S）。
   *      共享同一个 Promise 后，同一时刻只会真正发起一次查询。
   *      这与 PrefStore.init 用的是同一种套路。
   *   2. **结果缓存**：凭据只会被本应用的 save/clear 改动，改动时主动失效即可，
   *      其余读取直接命中缓存，避免反复进密钥库。
   */
  private static cached: Credential | null = null;
  private static cachedValid: boolean = false;
  /**
   * 代次：每次 save/clear 自增。
   * 用于识别「读密钥库期间凭据已被改动」的竞态（见 doLoad）。
   */
  private static generation: number = 0;
  private static inFlight: Promise<Credential | null> | null = null;

  private static bytes(s: string): Uint8Array {
    return new util.TextEncoder().encodeInto(s);
  }

  private static text(b: Uint8Array): string {
    return new util.TextDecoder().decodeToString(b);
  }

  private static queryMap(): asset.AssetMap {
    const q: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    q.set(asset.Tag.ALIAS, CredentialStore.bytes(CredentialStore.ALIAS));
    q.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL as asset.Value);
    return q;
  }

  /** 是否已保存凭据 */
  static async exists(): Promise<boolean> {
    const c: Credential | null = await CredentialStore.load();
    return c !== null && c.password.length > 0;
  }

  /**
   * 读取凭据；不存在或读取失败返回 null。
   * 并发调用共享同一次查询，结果带缓存（见上方字段说明）。
   */
  static async load(): Promise<Credential | null> {
    if (CredentialStore.cachedValid) {
      return CredentialStore.copyOf(CredentialStore.cached);
    }
    if (CredentialStore.inFlight !== null) {
      await CredentialStore.inFlight;
      return CredentialStore.copyOf(CredentialStore.cached);
    }
    CredentialStore.inFlight = CredentialStore.doLoad();
    try {
      await CredentialStore.inFlight;
    } finally {
      CredentialStore.inFlight = null;
    }
    return CredentialStore.copyOf(CredentialStore.cached);
  }

  /** 真正读取密钥库（只可能同时存在一个） */
  private static async doLoad(): Promise<Credential | null> {
    // 记下发起时的代次；若期间发生了 save/clear（代次变了），
    // 说明这次读到的结果已经过时，不能再写进缓存。
    const gen: number = CredentialStore.generation;
    let result: Credential | null = null;
    try {
      const res: Array<asset.AssetMap> = await asset.query(CredentialStore.queryMap());
      if (res.length > 0) {
        const secret: asset.Value | undefined = res[0].get(asset.Tag.SECRET);
        if (secret !== undefined) {
          const packed: string = CredentialStore.text(secret as Uint8Array);
          const idx: number = packed.indexOf(CredentialStore.SEP);
          result = idx < 0
            ? new Credential('', packed)
            : new Credential(packed.substring(0, idx), packed.substring(idx + 1));
        }
      }
    } catch (e) {
      // NOT_FOUND 属正常情况（用户没勾选过「记住账号密码」），不打印为错误
      result = null;
    }
    if (gen !== CredentialStore.generation) {
      // 读取期间凭据已被改动（例如用户刚点了「取消记住账号密码」）：
      // 不能把过时结果写回缓存，否则刚删掉的凭据会「复活」，
      // 后续 tryAutoLogin 可能用已删除的旧密码静默登录。
      Logger.info('credential load superseded by concurrent change');
      return CredentialStore.copyOf(CredentialStore.cached);
    }
    CredentialStore.cached = result;
    CredentialStore.cachedValid = true;
    return result;
  }

  /** 复制一份，避免调用方改到缓存对象 */
  private static copyOf(c: Credential | null): Credential | null {
    return c === null ? null : new Credential(c.account, c.password);
  }

  /** 保存或更新凭据 */
  static async save(account: string, password: string): Promise<void> {
    await CredentialStore.clear();
    const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attrs.set(asset.Tag.ALIAS, CredentialStore.bytes(CredentialStore.ALIAS));
    attrs.set(asset.Tag.SECRET, CredentialStore.bytes(account + CredentialStore.SEP + password));
    // 首次解锁后可读：兼顾安全与开机后自动填充
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED as asset.Value);
    try {
      await asset.add(attrs);
      // 写入成功后更新缓存，后续读取无需再进密钥库
      CredentialStore.cached = new Credential(account, password);
      CredentialStore.cachedValid = true;
      Logger.info('credential saved to keystore');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.warn('credential save failed: ' + err.code);
      CredentialStore.invalidate();
    }
  }

  /** 删除已保存凭据 */
  static async clear(): Promise<void> {
    // 代次自增：让任何在飞的 doLoad 结果失效，避免刚删除的凭据被写回缓存
    CredentialStore.generation = CredentialStore.generation + 1;
    const q: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    q.set(asset.Tag.ALIAS, CredentialStore.bytes(CredentialStore.ALIAS));
    try {
      await asset.remove(q);
    } catch (e) {
      // 不存在时忽略
    }
    CredentialStore.cached = null;
    CredentialStore.cachedValid = true;
  }

  /** 让缓存失效，下次读取重新查密钥库 */
  private static invalidate(): void {
    CredentialStore.cachedValid = false;
    CredentialStore.cached = null;
  }
}
