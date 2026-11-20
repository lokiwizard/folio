// Drive the visible editor as a user would. Check the saved object independently
// of keyboard focus and compare exported pixels with/without the text.
const assert = require('node:assert/strict');
module.exports = async function verifyTextBox({ win, app, button, readState }) {
  const paper = win.locator('.markupPaper'),
    frame = win.locator('.markupTextFrame');
  const field = win.getByRole('textbox', { name: '文本框内容', exact: true });
  const mark = (s) => s.cards.find((c) => c.kind === 'pin');
  const boxes = (s) => mark(s).drawing.objects.filter((o) => o.type === 'FolioTextBox');
  const r = await paper.boundingBox();
  const x = r.x + r.width * 0.25,
    y = r.y + r.height * 0.32,
    width = Math.min(142, r.width * 0.35),
    height = Math.min(58, r.height * 0.3);
  const scale = await paper.evaluate((p) => p.getBoundingClientRect().width / parseFloat(p.style.width));
  const cd = await win.context().newCDPSession(win);
  const selectAll = process.platform === 'darwin' ? 'Meta+a' : 'Control+a';
  await button('文本框').click();
  await win.mouse.move(x, y);
  await win.mouse.down();
  await win.mouse.move(x + width, y + height, { steps: 8 });
  assert.ok(await frame.isVisible());
  assert.ok(Math.abs((await frame.boundingBox()).width - width) < 3);
  await win.mouse.up();
  assert.ok(await field.isVisible());
  assert.ok(
    await field.evaluate((t) => document.activeElement === t && getComputedStyle(t).opacity === '1')
  );
  assert.equal(await frame.isVisible(), false);
  await win.keyboard.type('Figure A');
  await win.keyboard.press('Enter');
  const chinese = '中文输入时需要在所画的文本框宽度内换行，光标应当始终停留在文字旁边。';
  await cd.send('Input.imeSetComposition', { text: 'zhongwen', selectionStart: 8, selectionEnd: 8 });
  assert.ok((await field.inputValue()).includes('zhongwen'));
  await cd.send('Input.insertText', { text: chinese });
  const original = 'Figure A\n' + chinese;
  assert.equal(await field.inputValue(), original);
  // Text remains active while using its style controls.
  await button('蓝色').click();
  const typeSize = win.locator('.markupField input[title="字号"]');
  await typeSize.fill('27');
  await typeSize.press('Enter');
  assert.ok(await field.evaluate((t) => document.activeElement === t));
  await win.keyboard.press('Control+Enter');
  const first = await readState((s) => {
    assert.equal(boxes(s).length, 1);
    const o = boxes(s)[0];
    assert.equal(o.text, original);
    assert.equal(o.fill, '#3579df');
    assert.equal(o.fontSize, 27);
    assert.ok(Math.abs(o.width - width / scale) < 3 / scale);
    assert.ok(o.minimumBoxHeight > 12);
    assert.ok(o.height > o.fontSize * 2);
    return o;
  });
  await button('文本框').click();
  await win.mouse.click(x + 10, y + 8);
  assert.equal(await field.inputValue(), original);
  await win.keyboard.press(selectAll);
  await win.keyboard.type('discard this');
  await win.keyboard.press('Escape');
  assert.equal(await field.count(), 0);
  assert.ok(await win.locator('dialog.markupSheet').isVisible());
  await readState((s) => assert.equal(boxes(s)[0].text, original));
  await win.mouse.dblclick(x + 9, y + 8);
  assert.equal(await field.inputValue(), original);
  await win.keyboard.press(selectAll);
  await win.keyboard.type('Figure B');
  let finalText = 'Figure B';
  if (process.platform === 'win32') {
    await app.evaluate(({ clipboard }) => clipboard.writeText(' · 粘贴'));
    await win.keyboard.press('End');
    await win.keyboard.press('Control+v');
    finalText += ' · 粘贴';
  }
  await win.keyboard.press('Enter');
  await win.keyboard.insertText(chinese);
  finalText += '\n' + chinese;
  // Commit by clicking outside the field. Undo and redo must cover the whole edit.
  await win.mouse.click(r.x + r.width * 0.94, r.y + r.height * 0.95);
  await readState((s) => {
    assert.equal(boxes(s).length, 1);
    assert.equal(boxes(s)[0].text, finalText);
  });
  await button('撤销').click();
  await readState((s) => assert.equal(boxes(s)[0].text, original));
  await button('重做').click();
  await readState((s) => assert.equal(boxes(s)[0].text, finalText));
  await button('文本框').click();
  await win.mouse.click(r.x + r.width * 0.85, r.y + r.height * 0.89);
  assert.equal(await field.inputValue(), '');
  await win.keyboard.type('temporary');
  await win.keyboard.press('Escape');
  await readState((s) => assert.equal(boxes(s).length, 1));
  await win.mouse.click(x + 8, y + 9);
  await button('编辑文字').click();
  await win.keyboard.press(selectAll);
  await win.keyboard.press('Backspace');
  await win.keyboard.press('Control+Enter');
  await readState((s) => assert.equal(boxes(s).length, 0));
  await button('撤销').click();
  await readState((s) => assert.equal(boxes(s)[0].text, finalText));
  // The image returned by the export code must contain actual rendered glyphs.
  const changed = await win.evaluate(async () => {
    const { artwork } = await import('./editor.mjs');
    const { S } = await import('./ui.mjs');
    const card = S.state.cards.find((c) => c.kind === 'pin'),
      without = structuredClone(card);
    without.drawing.objects = without.drawing.objects.filter((o) => o.type !== 'FolioTextBox');
    const pixels = async (c) => {
      const image = await artwork(c, 950);
      return image.getContext('2d').getImageData(0, 0, image.width, image.height).data;
    };
    const a = await pixels(card),
      b = await pixels(without);
    let count = 0;
    for (let i = 0; i < a.length; i += 4)
      if (a[i] !== b[i] || a[i + 1] !== b[i + 1] || a[i + 2] !== b[i + 2]) count++;
    return count;
  });
  assert.ok(changed > 30, 'Saved text must appear in exported pixels');
  // Reopen the saved editor and resize the lower right handle, preserving its type size.
  await button('完成').click();
  await win.locator('.card img').click();
  await win.locator('.upper-canvas').waitFor();
  await win.waitForFunction(
    () =>
      document.querySelector('.markupStage canvas')?.clientWidth ===
      document.querySelector('.markupStage')?.clientWidth
  );
  const reopened = await paper.boundingBox();
  const newScale = await paper.evaluate(
    (p) => p.getBoundingClientRect().width / parseFloat(p.style.width)
  );
  const before = await readState((s) => boxes(s)[0]);
  const left = reopened.x + before.left * newScale,
    top = reopened.y + before.top * newScale;
  await win.mouse.click(left + 8, top + 9);
  await button('编辑文字').waitFor();
  const boxRight = left + before.width * newScale,
    boxBottom = top + before.height * newScale;
  await win.mouse.move(boxRight, boxBottom);
  await win.mouse.down();
  await win.mouse.move(boxRight + 28, boxBottom + 14, { steps: 5 });
  await win.mouse.up();
  await readState((s) => {
    const o = boxes(s)[0];
    assert.ok(o.width > before.width + 5);
    assert.equal(o.fontSize, first.fontSize);
    assert.equal(o.text, finalText);
  });
  await win.keyboard.press('F2');
  assert.equal(await field.inputValue(), finalText);
  await win.keyboard.press('Escape');
  await cd.detach();
  console.log(
    'PASS visible text frame, Chinese IME composition, wrapping, mixed multiline typing, re-edit, cancel, empty deletion, history, saved pixels, reopen and resize'
  );
};
