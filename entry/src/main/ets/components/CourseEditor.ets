/*
 * CourseEditor：课程编辑弹窗
 *
 * 支持新增 / 修改 / 删除某一格里的课程，并可增删同一格的课程条目。
 * 结果通过 onSaved 回调交回课表页，由课表页统一落盘。
 */
import { CourseEntry } from '../model/Models';
import { Theme } from '../theme/Theme';
import { GlassKit } from '../theme/GlassKit';
import { SECTIONS, SectionDef } from '../common/Constants';

/** 编辑结果 */
export class EditorResult {
  /** 该格最终的课程列表（已按界面上的编辑结果） */
  entries: CourseEntry[];
  /** 是否发生了删除（用于提示） */
  removed: boolean;

  constructor(entries: CourseEntry[], removed: boolean) {
    this.entries = entries;
    this.removed = removed;
  }
}

@Component
export struct CourseEditor {
  /** 弹窗标题用的节次与星期文本 */
  sectionLabel: string = '';
  weekdayLabel: string = '';
  /** 初始课程列表（深拷贝后的，可直接编辑） */
  @Prop entries: CourseEntry[] = [];
  /** 起始周 / 结束周的可选范围 */
  private maxWeek: number = 30;

  onSaved?: (result: EditorResult) => void;
  onCancel?: () => void;

  /** 当前编辑的条目草稿 */
  @State drafts: CourseEntry[] = [];
  @State activeIndex: number = 0;
  @State errorText: string = '';

  aboutToAppear(): void {
    const copy: CourseEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      copy.push(this.entries[i].clone());
    }
    if (copy.length === 0) {
      // 空课程格：给一条空白草稿，作为「新增课程」
      copy.push(CourseEditor.blank());
    }
    this.drafts = copy;
    this.activeIndex = 0;
  }

  private static blank(): CourseEntry {
    const e: CourseEntry = new CourseEntry();
    e.id = 'local-' + Date.now().toString() + '-' + Math.floor(Math.random() * 100000).toString();
    e.startWeek = 1;
    e.endWeek = 18;
    e.parity = 0;
    e.local = true;
    return e;
  }

  private current(): CourseEntry {
    if (this.activeIndex < 0 || this.activeIndex >= this.drafts.length) {
      this.activeIndex = 0;
    }
    return this.drafts[this.activeIndex];
  }

  /**
   * 修改草稿字段。
   * ArkTS 对 @State 数组元素的可观测性有限，因此改完字段后用整体替换触发刷新。
   */
  private patch(field: string, value: string, numValue: number): void {
    const list: CourseEntry[] = [];
    for (let i = 0; i < this.drafts.length; i++) {
      const e: CourseEntry = this.drafts[i].clone();
      if (i === this.activeIndex) {
        if (field === 'name') {
          e.courseName = value;
        } else if (field === 'teacher') {
          e.teacher = value;
        } else if (field === 'room') {
          e.room = value;
        } else if (field === 'campus') {
          e.campus = value;
        } else if (field === 'startWeek') {
          e.startWeek = numValue;
        } else if (field === 'endWeek') {
          e.endWeek = numValue;
        } else if (field === 'parity') {
          e.parity = numValue;
        }
        e.weekText = e.weekSummary();
      }
      list.push(e);
    }
    this.drafts = list;
    this.errorText = '';
  }

  /** 追加一条草稿（新增课程） */
  private addDraft(): void {
    const list: CourseEntry[] = [];
    for (let i = 0; i < this.drafts.length; i++) {
      list.push(this.drafts[i].clone());
    }
    list.push(CourseEditor.blank());
    this.drafts = list;
    this.activeIndex = list.length - 1;
  }

  /**
   * 删除某条草稿。
   * 若删到一条不剩，补一条空白草稿，保证表单始终可用；
   * 提交时若所有草稿都没有课程名，则视为清空该时段的课程。
   */
  private removeDraft(idx: number): void {
    const list: CourseEntry[] = [];
    for (let i = 0; i < this.drafts.length; i++) {
      if (i !== idx) {
        list.push(this.drafts[i].clone());
      }
    }
    if (list.length === 0) {
      list.push(CourseEditor.blank());
    }
    this.drafts = list;
    if (this.activeIndex >= list.length) {
      this.activeIndex = list.length - 1;
    }
    if (this.activeIndex < 0) {
      this.activeIndex = 0;
    }
    this.errorText = '';
  }

  private save(): void {
    const out: CourseEntry[] = [];
    for (let i = 0; i < this.drafts.length; i++) {
      const e: CourseEntry = this.drafts[i];
      // 课程名为空且无其它信息视为删除
      if (e.courseName.trim().length === 0) {
        continue;
      }
      if (e.startWeek > e.endWeek) {
        const t: number = e.startWeek;
        e.startWeek = e.endWeek;
        e.endWeek = t;
      }
      e.weekText = e.weekSummary();
      out.push(e);
    }
    if (this.drafts.length > 0 && out.length === 0) {
      // 全部清空 = 删除该格所有课程
      if (this.onSaved !== undefined) {
        this.onSaved(new EditorResult([], true));
      }
      return;
    }
    for (let i = 0; i < out.length; i++) {
      if (out[i].courseName.trim().length === 0) {
        this.errorText = '请填写课程名称';
        return;
      }
    }
    if (this.onSaved !== undefined) {
      this.onSaved(new EditorResult(out, false));
    }
  }

  @Builder
  field(label: string, value: string, key: string, placeholder: string) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(Theme.FS_SMALL)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ placeholder: placeholder, text: value })
        .height(44)
        .fontSize(Theme.FS_BODY)
        .backgroundColor($r('app.color.surface_variant'))
        .backgroundEffect(GlassKit.fieldEffect())
        .borderRadius(Theme.RADIUS_SM)
        .onChange((v: string) => {
          this.patch(key, v, 0);
        })
    }
    .width('100%')
  }

  @Builder
  weekPicker(label: string, value: number, key: string) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(Theme.FS_SMALL)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Select(this.weekRange().map((n: number) => {
        const opt: SelectOption = { value: n.toString() };
        return opt;
      }))
        .value(value.toString())
        .font({ size: Theme.FS_BODY })
        .width('100%')
        .onSelect((index: number, v: string) => {
          const list: number[] = this.weekRange();
          if (index < list.length) {
            this.patch(key, '', list[index]);
          }
        })
    }
    .layoutWeight(1)
  }

  private weekRange(): number[] {
    const out: number[] = [];
    for (let i = 1; i <= this.maxWeek; i++) {
      out.push(i);
    }
    return out;
  }

  build() {
    Column({ space: Theme.GAP }) {
      // 标题
      Row() {
        Column({ space: 2 }) {
          Text(this.entries.length > 0 ? '编辑课程' : '添加课程')
            .fontSize(Theme.FS_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.weekdayLabel + ' · ' + this.sectionLabel)
            .fontSize(Theme.FS_SMALL)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      // 时段内的课程列表：始终显示，便于在同一时段追加第 2、3 门课；
      // 每项右侧的 × 单独响应删除，避免与「切换选中项」互相干扰。
      Row({ space: Theme.GAP_S }) {
        ForEach(this.drafts, (e: CourseEntry, idx: number) => {
          Row({ space: 0 }) {
            Text(e.courseName.length > 0 ? e.courseName : ('课程' + (idx + 1).toString()))
              .fontSize(Theme.FS_SMALL)
              .fontColor(idx === this.activeIndex ? $r('app.color.on_brand') : $r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 120 })
              .padding({ left: 10, right: 6, top: 4, bottom: 4 })
              .onClick(() => {
                this.activeIndex = idx;
              })
            Text('×')
              .fontSize(Theme.FS_SMALL)
              .fontColor(idx === this.activeIndex ? $r('app.color.on_brand') : $r('app.color.text_tertiary'))
              .padding({ left: 6, right: 10, top: 4, bottom: 4 })
              .onClick(() => {
                this.removeDraft(idx);
              })
          }
          .backgroundColor(idx === this.activeIndex ? $r('app.color.brand') : $r('app.color.surface_variant'))
          .borderRadius(12)
        }, (e: CourseEntry, idx: number) => e.id + '-' + idx.toString() + '-' + e.courseName)

        Text('+')
          .fontSize(Theme.FS_SECTION)
          .fontColor($r('app.color.brand'))
          .padding({ left: 10, right: 10, top: 2, bottom: 4 })
          .backgroundColor($r('app.color.brand_soft'))
          .borderRadius(12)
          .onClick(() => {
            this.addDraft();
          })
      }
      .width('100%')

      Scroll() {
        Column({ space: Theme.GAP }) {
          this.field('课程名称', this.current().courseName, 'name', '如 数据结构')
          this.field('教师', this.current().teacher, 'teacher', '如 张老师')
          Row({ space: Theme.GAP_S }) {
            Column({ space: 6 }) {
              Text('教室')
                .fontSize(Theme.FS_SMALL)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              TextInput({ placeholder: '如 9-316', text: this.current().room })
                .height(44)
                .fontSize(Theme.FS_BODY)
                .backgroundColor($r('app.color.surface_variant'))
                .backgroundEffect(GlassKit.fieldEffect())
                .borderRadius(Theme.RADIUS_SM)
                .onChange((v: string) => {
                  this.patch('room', v, 0);
                })
            }
            .layoutWeight(3)

            Column({ space: 6 }) {
              Text('校区')
                .fontSize(Theme.FS_SMALL)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              TextInput({ placeholder: '章丘', text: this.current().campus })
                .height(44)
                .fontSize(Theme.FS_BODY)
                .backgroundColor($r('app.color.surface_variant'))
                .backgroundEffect(GlassKit.fieldEffect())
                .borderRadius(Theme.RADIUS_SM)
                .onChange((v: string) => {
                  this.patch('campus', v, 0);
                })
            }
            .layoutWeight(2)
          }
          .width('100%')

          Row({ space: Theme.GAP_S }) {
            this.weekPicker('起始周', this.current().startWeek, 'startWeek')
            this.weekPicker('结束周', this.current().endWeek, 'endWeek')
          }
          .width('100%')

          // 单双周
          Column({ space: 6 }) {
            Text('单双周')
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Row({ space: Theme.GAP_S }) {
              ForEach(['每周', '单周', '双周'], (label: string, idx: number) => {
                Text(label)
                  .fontSize(Theme.FS_BODY)
                  .fontColor(this.current().parity === idx ? $r('app.color.on_brand') : $r('app.color.text_secondary'))
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .backgroundColor(this.current().parity === idx ? $r('app.color.brand') : $r('app.color.surface_variant'))
                  .borderRadius(Theme.RADIUS_SM)
                  .onClick(() => {
                    this.patch('parity', '', idx);
                  })
              }, (label: string) => label)
            }
            .width('100%')
          }
          .width('100%')

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.danger'))
              .width('100%')
          }

          // 删除当前条目
          // 仅当这一时段本来就有课程时才提供删除入口
          if (this.entries.length > 0) {
            Text(this.drafts.length > 1 ? '删除当前课程' : '删除这门课程')
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.danger'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 8 })
              .onClick(() => {
                if (this.drafts.length > 1) {
                  // 有多门：只移除当前这一门
                  this.removeDraft(this.activeIndex);
                  return;
                }
                // 只剩一门：清空该时段（提交时按空课程名过滤掉）
                const cleared: CourseEntry = new CourseEntry();
                cleared.id = this.drafts[0].id;
                cleared.startWeek = this.drafts[0].startWeek;
                cleared.endWeek = this.drafts[0].endWeek;
                cleared.parity = this.drafts[0].parity;
                cleared.local = true;
                this.drafts = [cleared];
                this.activeIndex = 0;
                this.errorText = '';
              })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)

      // 操作按钮：固定在弹窗底部。
      // 因为页面用的是 KeyboardAvoidMode.RESIZE，弹窗高度按百分比取值，
      // 键盘弹出时弹窗会随之收窄，按钮不会被键盘顶出可视区。
      Row({ space: Theme.GAP_S }) {
        Button('取消')
          .layoutWeight(1)
          .height(46)
          .fontSize(Theme.FS_BODY)
          .backgroundColor($r('app.color.surface_variant'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.onCancel !== undefined) {
              this.onCancel();
            }
          })
        Button('保存')
          .layoutWeight(1)
          .height(46)
          .fontSize(Theme.FS_BODY)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.on_brand'))
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(Theme.GAP_L)
    // 刻意**不设背景色**：面板的底由外层 GlassOverlay 的磨砂玻璃提供。
    // 这里再铺一层不透明 surface 会把玻璃整个盖住，等于没用。
  }
}
