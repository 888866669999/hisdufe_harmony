/*
 * SessionCookieStore：会话 cookie（JSESSIONID）的加密落盘
 *
 * ===== 为什么必须加密（而不是放在 preferences 里）=====
 * JSESSIONID 是**持有即可用**的凭据：拿到它就等于拿到该学生的完整登录态，
 * 不需要账号密码、也不受验证码保护。
 *
 * 而 preferences 是**明文**的 XML。实测确认过：在调试设备上
 * `hdc shell cat /data/app/el2/100/base/<bundle>/haps/entry/preferences/sdufe_jw_pref`
 * 能直接把 `session_cookie` 的值原文打印出来。更关键的是本应用的
 * `backup_config.json` 是 `allowToBackupRestore: true` —— 整个沙箱会进系统备份，
 * 明文凭据因此可能被带到云端或另一台设备上。
 *
 * 因此把会话 cookie 从 preferences 迁到**系统密钥库**（Asset Store），
 * 与 CredentialStore 保存账号密码用的是同一套机制：
 *   - 条目由系统加密保护，其他应用无法读取；
 *   - 设定 `DEVICE_FIRST_UNLOCKED`：开机首次解锁后可读，
 *     这样开机自启/后台刷新仍能恢复会话，但设备锁定时读不到。
 *
 * ===== 兼容旧版本（平滑迁移）=====
 * 升级前 preferences 里已经有明文 cookie。直接不读它会导致**所有老用户
 * 被登出一次**，这不能接受。因此 [load] 的顺序是：
 *   1. 先读密钥库；
 *   2. 密钥库里没有，再读一次 preferences 的旧值；
 *   3. 若旧值存在 → 立刻写入密钥库并把 preferences 里的明文抹掉，然后返回。
 * 这样迁移对用户完全无感，且明文只多存在最后一次。
 */
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';

export class SessionCookieStore {
  /** 密钥库别名。与凭据（sdufe_jw_credential）分开，便于独立清除 */
  private static readonly ALIAS: string = 'sdufe_jw_session';

  private static bytes(s: string): Uint8Array {
    return new util.TextEncoder().encodeInto(s);
  }

  private static text(b: Uint8Array): string {
    return new util.TextDecoder().decodeToString(b);
  }

  private static aliasMap(): asset.AssetMap {
    const m: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    m.set(asset.Tag.ALIAS, SessionCookieStore.bytes(SessionCookieStore.ALIAS));
    return m;
  }

  /** 读取会话；不存在返回空串。失败一律当作「没有会话」，不抛异常。 */
  static async load(): Promise<string> {
    try {
      const q: asset.AssetMap = SessionCookieStore.aliasMap();
      q.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL as asset.Value);
      const res: asset.AssetMap[] = await asset.query(q);
      if (res.length > 0) {
        const secret: asset.Value | undefined = res[0].get(asset.Tag.SECRET);
        if (secret !== undefined) {
          return SessionCookieStore.text(secret as Uint8Array);
        }
      }
    } catch (e) {
      // NOT_FOUND 是常态（尚未登录过），不当作错误
    }
    return '';
  }

  /** 写入会话；失败返回 false（调用方据此决定是否降级，见 PrefStore.saveCookie） */
  static async save(cookie: string): Promise<boolean> {
    // 先删再写：asset.add 对已存在的别名会报错，无法直接覆盖
    await SessionCookieStore.remove();
    if (cookie.length === 0) {
      return true;
    }
    try {
      const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      attrs.set(asset.Tag.ALIAS, SessionCookieStore.bytes(SessionCookieStore.ALIAS));
      attrs.set(asset.Tag.SECRET, SessionCookieStore.bytes(cookie));
      // 首次解锁后可读：兼顾安全与开机后的会话恢复
      attrs.set(asset.Tag.ACCESSIBILITY,
        asset.Accessibility.DEVICE_FIRST_UNLOCKED as asset.Value);
      await asset.add(attrs);
      return true;
    } catch (e) {
      Logger.warn('session cookie save to keystore failed');
      return false;
    }
  }

  /** 删除会话 */
  static async remove(): Promise<void> {
    try {
      await asset.remove(SessionCookieStore.aliasMap());
    } catch (e) {
      // 不存在时忽略
    }
  }
}
