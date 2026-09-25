/*
 * hi山财 · 应用入口
 */
import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { ContextHolder } from '../common/ContextHolder';
import { PrefStore } from '../data/PrefStore';
import { WeekService } from '../data/WeekService';
import { AppState } from '../data/AppState';
import { CardSnapshotStore } from '../data/CardSnapshotStore';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 注入上下文，供 preferences / window 等模块使用
    ContextHolder.set(this.context);
    // 初始化本地存储与周次服务（幂等，失败不阻塞启动）
    PrefStore.init().then(() => {
      // 进入应用即与系统时间对齐当前周次（超过 6 小时才真正重算）
      return WeekService.align(false);
    }).catch(() => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', 'week align skipped');
    });
    // 跟随系统深浅色
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'setColorMode failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'loadContent succeeded');
      EntryAbility.applyTransparentWindowBackground(windowStage);
    });
  }

  /**
   * 把**窗口背景**设为透明。
   *
   * ===== 为什么需要它 =====
   * 页面里「没有内容的那部分」原先会露出窗口背景色（系统默认是白/黑），
   * 于是成绩页列表下方那块空白只能自己铺一层底色 —— 但那层底色是**实心**的：
   * 自由窗口下看起来就是一块不透明的板子，而它下面是桌面。
   *
   * 窗口背景设为透明后，未被页面绘制的区域会**透出下层**
   * （自由窗口 → 桌面；全屏 → 壁纸），成绩页底部因此是真正透明的。
   *
   * 注意作用范围：只有**自己不铺底色**的页面会透出来。其余页面仍由
   * Index 铺 `bg`（见那里的 pageBackground），所以观感不变。
   */
  private static applyTransparentWindowBackground(windowStage: window.WindowStage): void {
    try {
      windowStage.getMainWindow().then((win: window.Window) => {
        // 全透明：ARGB 的 alpha 段为 00
        win.setWindowBackgroundColor('#00000000');
        hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'window background set transparent');
      }).catch((e: Object) => {
        // 拿不到主窗口不影响功能，只是底部会退回系统默认底色
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'getMainWindow failed: %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setWindowBackgroundColor failed: %{public}s', JSON.stringify(e));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // 回到前台时刷新桌面卡片快照：周次/日期可能已经变了
    CardSnapshotStore.refresh().catch(() => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', 'card snapshot refresh skipped');
    });
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // 退到后台时把内存中的会话写回本地：
    // 服务器可能在交互过程中轮换过 JSESSIONID，及时落盘才能保住登录态。
    // 这是 fire-and-forget 调用，必须自带 .catch，否则写入失败会变成
    // 未处理的 Promise rejection（且发生在退后台时，更难排查）。
    AppState.persistSession().catch(() => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', 'persist session skipped');
    });
    // 同时刷新卡片快照，保证用户回桌面看到的是最新课程
    CardSnapshotStore.refresh().catch(() => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', 'card snapshot refresh skipped');
    });
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Ability onBackground');
  }
}
