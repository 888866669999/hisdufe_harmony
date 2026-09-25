/*
 * ProfileService：个人信息的唯一加载入口 + 姓名/学号的就绪保障
 *
 * ===== 为什么要有这个模块（真机 bug）=====
 * 姓名显示在**外壳**上（宽屏侧栏的标题下、内容页顶栏右侧），但它原先只有
 * `ProfilePage.applyProfile` 会往 AppStorage 里写 —— 于是冷启动后不点进
 * 「我的」，侧栏/顶栏就一直是空的（用户反馈「必须进我的才能加载出姓名」）。
 *
 * 修法不是「在 Index 里再写一遍同样的请求」，而是把加载器收口到这里：
 *   - `identity()`：给外壳用。先吃内存/磁盘缓存（**不联网**）立刻把姓名补上，
 *     缓存没有再触发一次联网，成功后再发布；
 *   - `loader()`：ProfilePage 用它取完整资料（同一份缓存 key 与 TTL）。
 * 两条路径共用同一个 PageDataLoader 定义，不会出现「一边改了 TTL、另一边还是旧值」。
 *
 * ===== 为什么外壳侧也愿意联网一次 =====
 * 冷启动时磁盘上通常有上一次的资料缓存（TTL 6 小时），绝大多数情况零请求。
 * 只有全新设备/首次登录才会真的发一次 —— 而那种情况下姓名本来就得联网才有。
 * 这一请求与「进我的页」时发的那次完全一样，不增加教务系统的负担。
 */
import { PageCache, PageDataLoader, PageLoadResult } from './PageCache';
import { ProfileParser } from '../parser/ProfileParser';
import { StudentProfile } from '../model/Models';
import { CACHE_PROFILE, TTL_PROFILE, AS_STUDENT_NAME, AS_STUDENT_ID } from '../common/Constants';
import { AppState } from './AppState';
import { Logger } from '../common/Logger';

export class ProfileService {
  /**
   * 已经预取过身份的账号。
   *
   * 用**账号**而不是布尔标记：退出登录/换账号后账号会变，
   * 下次调用自然重新预取 —— 于是这里不必反向依赖 AppState 的登出流程
   * （那会形成 AppState ↔ ProfileService 的循环 import）。
   */
  private static prefetchedFor: string = '';

  /** 个人资料的加载器（与 ProfilePage 共用；key 随账号变化，故每次现取） */
  static loader(): PageDataLoader<StudentProfile> {
    return new PageDataLoader<StudentProfile>(
      PageCache.keyOf(AppState.account, CACHE_PROFILE),
      () => AppState.apiInstance().getProfileHtml(),
      (body: string) => ProfileParser.parse(body),
      TTL_PROFILE);
  }

  /**
   * 把姓名/学号发布到 AppStorage（外壳读它显示）。
   *
   * 空值不覆盖已有值：一次「只回了一半」的响应不该把已经显示出来的姓名抹掉。
   */
  static publish(p: StudentProfile): void {
    if (p.name.length > 0) {
      AppStorage.setOrCreate(AS_STUDENT_NAME, p.name);
    }
    if (p.studentId.length > 0) {
      AppStorage.setOrCreate(AS_STUDENT_ID, p.studentId);
    }
  }

  /**
   * 确保外壳能拿到姓名：缓存优先，必要时联网。
   *
   * 调用点：登录成功后、以及冷启动恢复会话后（见 Index.restore）。
   * **绝不抛异常** —— 它是外壳的装饰性数据，不能因为取不到姓名就影响启动。
   *
   * @param allowNetwork false 时只读缓存（用于「先让界面出字」的第一步）
   */
  static async ensureIdentity(allowNetwork: boolean = true): Promise<void> {
    const loader: PageDataLoader<StudentProfile> = ProfileService.loader();

    // 1) 内存缓存：同步拿到，界面立刻有字
    const mem: StudentProfile | null = loader.peek();
    if (mem !== null) {
      ProfileService.publish(mem);
      return;
    }

    // 2) 磁盘缓存：不联网
    try {
      const disk: StudentProfile | null = await loader.loadCached();
      if (disk !== null) {
        ProfileService.publish(disk);
        return;
      }
    } catch (e) {
      Logger.warn('profile disk cache read failed');
    }

    if (!allowNetwork) {
      return;
    }

    // 3) 真的没有缓存 → 联网一次（等价于「进我的页」那一次请求）
    try {
      const r: PageLoadResult<StudentProfile> = await loader.load(false);
      ProfileService.publish(r.data);
    } catch (e) {
      // 会话失效不在这里处理：外壳没有弹窗的资格，交给「我的」页在
      // 用户主动进入时按 ReAuthService 的既有流程处理。
      Logger.warn('profile identity prefetch failed');
    }
  }

  /**
   * 启动期的一次性预取（同一个账号只跑一次）。
   *
   * 单独包一层而不是让调用方自己判断，是为了让「登录后」与「冷启动恢复后」
   * 两条路径都能安全地调用它 —— 两条路径在同一次启动里都可能触发。
   */
  static async prefetchOnce(): Promise<void> {
    const acct: string = AppState.account;
    if (acct.length === 0 || ProfileService.prefetchedFor === acct) {
      return;
    }
    ProfileService.prefetchedFor = acct;
    await ProfileService.ensureIdentity(true);
  }
}
