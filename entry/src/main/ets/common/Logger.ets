/*
 * 统一日志封装（不打印个人敏感信息）
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN, LOG_TAG } from './Constants';

export class Logger {
  static debug(msg: string): void {
    hilog.debug(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }

  static info(msg: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }

  static warn(msg: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }

  static error(msg: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
  }
}
