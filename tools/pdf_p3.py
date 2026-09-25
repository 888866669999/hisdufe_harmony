import io

p = 'entry/src/main/ets/components/PdfViewer.ets'
s = io.open(p, encoding='utf-8').read()

# ================= 3) 渲染/预取/缓存裁剪：改为以视口为中心的多页窗口 =================
start = s.index('  /** 渲染指定页到 currentMap；同时预渲染相邻页 */')
end = s.index('  /**\n   * 取一页的位图。')
new_render = '''  /**
   * 把「视口附近的页」渲染出来，并释放滑远的页。
   *
   * 这是上下滑动阅读的核心：既不能一次渲染全部（内存爆），
   * 也不能只渲染一页（滑动时白屏）。策略是**只保留视口前后各
   * WINDOW_KEEP 页**，其余释放。
   *
   * @param first 当前第一页可见下标
   * @param last  当前最后一页可见下标
   */
  private syncWindow(first: number, last: number): void {
    if (this.doc === null) {
      return;
    }
    const lo: number = Math.max(0, first - WINDOW_KEEP);
    const hi: number = Math.min(this.pageCount - 1, last + WINDOW_KEEP);

    // 渲染窗口内尚未渲染的页
    const next: number[] = [];
    for (let i = lo; i <= hi; i++) {
      next.push(i);
      if (!this.maps.has(i)) {
        const pm: image.PixelMap | null = PdfViewer.tryRenderOne(this.doc, i);
        if (pm !== null) {
          const m: Map<number, image.PixelMap> = this.maps;
          m.set(i, pm);
          this.maps = m;
        }
      }
    }

    // 释放窗口外的页（保留窗口外一页做缓冲，避免来回滑时反复渲染）
    const keepLo: number = Math.max(0, first - WINDOW_KEEP - 1);
    const keepHi: number = Math.min(this.pageCount - 1, last + WINDOW_KEEP + 1);
    const toRelease: number[] = [];
    this.maps.forEach((pm: image.PixelMap, key: number) => {
      if (key < keepLo || key > keepHi) {
        toRelease.push(key);
      }
    });
    if (toRelease.length > 0) {
      const m: Map<number, image.PixelMap> = this.maps;
      for (let i = 0; i < toRelease.length; i++) {
        const k: number = toRelease[i];
        const pm: image.PixelMap | undefined = m.get(k);
        if (pm !== undefined) {
          try {
            pm.release();
          } catch (e) {
            // 单个释放失败不影响其它
          }
        }
        m.delete(k);
      }
      this.maps = m;
    }

    this.visiblePages = next;
  }

  /** 渲染一页；失败返回 null（不抛异常，滑动时单页失败不该中断整个阅读） */
  private static tryRenderOne(doc: pdfService.PdfDocument, index: number): image.PixelMap | null {
    try {
      return PdfViewer.renderOne(doc, index);
    } catch (e) {
      return null;
    }
  }

'''
s = s[:start] + new_render + s[end:]

# 删除旧的 prefetch / prefetchOne / trimCache（已被 syncWindow 取代）
start2 = s.index('  /** 预渲染相邻页（失败忽略，不影响当前页浏览） */')
end2 = s.index('  // ==================== 缩放 ====================')
s = s[:start2] + s[end2:]

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('part3 ok')