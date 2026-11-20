// Exercise a populated workspace with the two real figures from Folio's example
// notes. This creates a temporary two-page PDF. Distribution needs no sample files.
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');

module.exports = async function sidebarPreview({ app, win, dir, root, output }) {
  const images = await Promise.all(
    ['001', '002'].map(async (n) =>
      (
        await fs.readFile(path.join(root, '../docs/examples/ip-adapter/figures', 'clip-' + n + '.png'))
      ).toString('base64')
    )
  );
  const pdf = path.join(dir, 'IP-Adapter · 图表精读.pdf');
  const data = await app.evaluate(async ({ BrowserWindow }, images) => {
    const sample = new BrowserWindow({ show: false, webPreferences: { sandbox: true } });
    try {
      const titles = ['Decoupled cross-attention', 'Image and text prompts'];
      const html =
        '<style>@page{size:612pt 792pt;margin:0}*{box-sizing:border-box}body{margin:0;color:#222;font-family:Georgia,serif}section{height:792pt;padding:40pt;break-after:page}section:last-child{break-after:auto}h1{font-size:27pt;margin:0 0 12pt}h2{font-size:18pt;margin:0 0 20pt}img{width:532pt;height:auto;display:block}p{font-size:12pt}</style>' +
        images
          .map(
            (img, i) =>
              '<section><h1>IP-Adapter</h1><h2>' +
              titles[i] +
              '</h2><img src="data:image/png;base64,' +
              img +
              '"><p>Figure ' +
              (i ? 8 : 2) +
              '. ' +
              titles[i] +
              '.</p></section>'
          )
          .join('');
      await sample.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));
      await sample.webContents.executeJavaScript(
        'Promise.all(Array.from(document.images,i=>i.decode())).then(()=>true)'
      );
      return (
        await sample.webContents.printToPDF({ preferCSSPageSize: true, printBackground: true })
      ).toString('base64');
    } finally {
      sample.destroy();
    }
  }, images);
  await fs.writeFile(pdf, Buffer.from(data, 'base64'));
  await app.evaluate(({ dialog }, pdf) => {
    dialog.showOpenDialog = async () => ({ filePaths: [pdf] });
  }, pdf);
  await win.keyboard.press('Control+o');
  await win.waitForFunction(() => document.title.startsWith('IP-Adapter'));
  await win.waitForSelector('.textLayer span');
  await win.evaluate(async () => {
    const { S, save } = await import('./ui.mjs');
    const { hooks, view, go, navigation } = await import('./reader.mjs');
    const { apply } = await import('./settings.mjs');
    S.settings.lang = 'zh';
    S.settings.theme = 'light';
    apply();
    for (const [i, title, note] of [
      [1, '图 2 · 模型架构', '对照右上角的两块注意力，分别追踪图像和文本特征。'],
      [2, '图 8 · 图文提示', '同一张参考图，加上不同文字，哪些细节会改变？'],
    ]) {
      const p = await S.doc.getPage(i),
        ops = await p.getOperatorList();
      const { OPS, Util } = await import('../assets/pdf/build/pdf.mjs');
      let m = [1, 0, 0, 1, 0, 0];
      const stack = [];
      let rect;
      for (let j = 0; j < ops.fnArray.length; j++) {
        const f = ops.fnArray[j],
          a = ops.argsArray[j];
        if (f === OPS.save) stack.push([...m]);
        if (f === OPS.restore) m = stack.pop() || m;
        if (f === OPS.transform) m = Util.transform(m, a);
        if (f === OPS.paintImageXObject) {
          const x = m[4],
            y = m[5];
          rect = [
            Math.min(x, x + m[0]),
            Math.min(y, y + m[3]),
            Math.max(x, x + m[0]),
            Math.max(y, y + m[3]),
          ];
          break;
        }
      }
      if (!rect || rect[2] - rect[0] < 100) throw Error('Missing embedded sample figure');
      S.state.cards.push({
        id: crypto.randomUUID(),
        kind: 'pin',
        scale: 1,
        title,
        note,
        anchors: [{ page: i, rect }],
      });
    }
    hooks.shell();
    hooks.cards('pin');
    await navigation('pages');
    go(2);
    view.currentScaleValue = 'page-width';
    save();
  });
  if (!(await win.locator('#navigation').isVisible())) await win.locator('#navToggle').click();
  await win.getByRole('button', { name: '页面', exact: true }).click();
  await win.waitForFunction(
    () =>
      document.querySelectorAll('.card img').length === 2 &&
      [...document.querySelectorAll('.card img,.thumbnail img')].every(
        (i) => i.complete && i.naturalWidth
      )
  );
  await win.mouse.move(0, 0);
  await win.screenshot({ path: path.join(output, 'Folio-Windows-sidebars.png') });
  await win.locator('.card img').first().click();
  await win.getByRole('button', { name: '箭头', exact: true }).click();
  await win.getByRole('button', { name: '蓝色', exact: true }).click();
  const box = await win.locator('.markupPaper').boundingBox();
  await win.mouse.move(box.x + 0.43 * box.width, box.y + 0.39 * box.height);
  await win.mouse.down();
  await win.mouse.move(box.x + 0.55 * box.width, box.y + 0.24 * box.height, { steps: 9 });
  await win.mouse.up();
  await win.waitForFunction(
    () => !document.querySelector('.markupTools button[aria-label="撤销"]').disabled
  );
  assert.equal(await win.locator('.markupSegments button:visible').count(), 7);
  await win.mouse.move(0, 0);
  await win.screenshot({ path: path.join(output, 'Folio-Windows-figure-editor.png') });
  await win.getByRole('button', { name: '完成', exact: true }).click();
};
