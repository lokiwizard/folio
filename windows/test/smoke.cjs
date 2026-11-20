// Runs against either the development runtime or a freshly installed Windows EXE.
// Dialogs choose files in the temporary directory. PDF content is never uploaded.
const { _electron } = require('playwright-core');
const assert = require('node:assert/strict'),
  fs = require('node:fs/promises'),
  os = require('node:os'),
  path = require('node:path');
const { createHash } = require('node:crypto');
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function eventually(fn) {
  let failure;
  for (let i = 0; i < 80; i++) {
    try {
      return await fn();
    } catch (e) {
      failure = e;
      await delay(100);
    }
  }
  throw failure;
}
async function run() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'folio-ui-')),
    root = path.resolve(__dirname, '..'),
    fixture = path.join(root, '../Tests/Fixtures/embedded-highlights.pdf');
  const pdf = path.join(dir, '双栏 test.pdf');
  await fs.copyFile(fixture, pdf);
  const original = await fs.readFile(pdf),
    id = createHash('sha256').update(original).digest('hex');
  const profile = path.join(dir, 'profile'),
    statePath = path.join(profile, 'Folio', id + '.json');
  const state = async () => JSON.parse(await fs.readFile(statePath, 'utf8'));
  const readState = async (check) => eventually(async () => check(await state()));
  const app = await _electron.launch({
    executablePath: process.env.FOLIO_TEST_EXE || require('electron'),
    args: [
      '--user-data-dir=' + profile,
      ...(process.env.FOLIO_TEST_SCALE
        ? ['--force-device-scale-factor=' + process.env.FOLIO_TEST_SCALE]
        : []),
      ...(process.env.FOLIO_TEST_EXE ? [] : [root]),
      pdf,
    ],
    timeout: 35000,
  });
  let win;
  try {
    win = await app.firstWindow();
    const errors = [];
    win.on('pageerror', (err) => errors.push(err.message));
    win.on('console', (m) => {
      if (m.type() === 'error') {
        console.error('RENDERER', m.text().slice(0, 600));
        errors.push(m.text());
      }
    });
    win.setDefaultTimeout(12000);
    await app.evaluate(({ dialog }, dir) => {
      dialog.showSaveDialog = async (_, options) => ({
        canceled: false,
        filePath: dir + '/' + (options.defaultPath.endsWith('.md') ? 'notes.md' : 'pages.pdf'),
      });
    }, dir);
    const button = (name) => win.getByRole('button', { name, exact: true });
    await win.waitForSelector('#desk:not([hidden])');
    await win.waitForSelector('.textLayer span');
    await readState((s) => {
      assert.equal(s.cards.filter((c) => c.source).length, 2);
      assert.equal(s.cards.find((c) => c.source?.startsWith('1/')).text, 'Alpha result\nBeta result');
    });
    console.log('PASS opened PDF, imported both original highlights and extracted two-column text');
    await button('批注').click();
    await win.locator('.folioMark').first().click();
    await button('取消高亮').click();
    await readState((s) => assert.equal(s.cards.length, 1));
    await button('撤销删除').click();
    await readState((s) => assert.equal(s.cards.length, 2));
    const span = win.locator('.textLayer span').filter({ hasText: 'Unrelated text' }).first();
    await span.scrollIntoViewIfNeeded();
    await span.hover();
    const lineBox = await span.boundingBox();
    await win.mouse.move(lineBox.x + 1, lineBox.y + lineBox.height / 2);
    await win.mouse.down();
    await win.mouse.move(lineBox.x + lineBox.width - 1, lineBox.y + lineBox.height / 2, { steps: 12 });
    await win.waitForFunction(() => getSelection().toString().includes('nrelated'));
    await win.mouse.up();
    await button('默认高亮').click();
    await readState((s) => assert.ok(s.cards.some((c) => !c.source && c.text.includes('nrelated'))));
    const manual = win.locator('.card').filter({ hasText: 'nrelated' });
    await manual.getByRole('button', { name: '卡片操作' }).click();
    await button('删除').click();
    await readState((s) => assert.equal(s.cards.length, 2));
    await win.locator('#clip').click();
    const page = win.locator('.page[data-page-number="1"]'),
      box = await page.boundingBox();
    await win.mouse.move(box.x + box.width * 0.09, box.y + box.height * 0.1);
    await win.mouse.down();
    await win.mouse.move(box.x + box.width * 0.8, box.y + box.height * 0.55, { steps: 9 });
    await win.mouse.up();
    await button('固定').click();
    const pin = win.locator('.card img');
    await pin.waitFor();
    await win.waitForFunction(() => document.querySelector('.card img')?.naturalWidth > 0);
    await pin.click();
    await button('矩形').click();
    const draw = win.locator('.markupPaper');
    const surface = await draw.boundingBox();
    await win.mouse.move(surface.x + surface.width * 0.15, surface.y + surface.height * 0.2);
    await win.mouse.down();
    await win.mouse.move(surface.x + surface.width * 0.7, surface.y + surface.height * 0.7, {
      steps: 7,
    });
    await win.mouse.up();
    await readState((s) =>
      assert.equal(s.cards.find((c) => c.kind === 'pin').drawing.objects.length, 1)
    );
    const objs = () => state().then((s) => s.cards.find((c) => c.kind === 'pin').drawing.objects);
    const gesture = async (name, from, to, shift = false) => {
      await button(name).click();
      await win.mouse.move(surface.x + surface.width * from[0], surface.y + surface.height * from[1]);
      if (shift) await win.keyboard.down('Shift');
      await win.mouse.down();
      await win.mouse.move(surface.x + surface.width * to[0], surface.y + surface.height * to[1], {
        steps: 8,
      });
      await win.mouse.up();
      if (shift) await win.keyboard.up('Shift');
    };
    await win.locator('.markupField input[title="线宽"]').fill('9');
    await win.locator('.markupField input[title="线宽"]').press('Enter');
    await win.locator('.markupProperties select').selectOption('dash');
    await button('蓝色').click();
    await button('形状文字').click();
    await win.locator('.shapeLabelInput').fill('模块 A');
    await win.locator('.shapeLabelInput').press('Control+Enter');
    await eventually(async () => {
      const [rect] = await objs();
      assert.equal(rect.label, '模块 A');
      assert.equal(rect.strokeWidth, 9);
      assert.equal(rect.stroke, '#3579df');
      assert.deepEqual(rect.strokeDashArray, [27, 18]);
    });
    await gesture('椭圆', [0.2, 0.2], [0.31, 0.34], true);
    await eventually(async () => {
      const o = (await objs()).at(-1);
      assert.equal(o.type, 'FolioEllipse');
      assert.ok(Math.abs(o.rx - o.ry) < 0.01);
    });
    await gesture('直线', [0.1, 0.8], [0.38, 0.75]);
    await gesture('箭头', [0.46, 0.76], [0.67, 0.78]);
    await eventually(async () => assert.equal((await objs()).at(-1).arrow, true));
    const endX = surface.x + surface.width * 0.67,
      endY = surface.y + surface.height * 0.78;
    const arrowBefore = (await objs()).at(-1);
    await win.mouse.move(endX, endY);
    await win.mouse.down();
    await win.mouse.move(endX + 18, endY - 21, { steps: 6 });
    await win.mouse.up();
    await eventually(async () => {
      const changed = (await objs()).at(-1);
      assert.deepEqual(changed.points[0], arrowBefore.points[0]);
      assert.notDeepEqual(changed.points[1], arrowBefore.points[1]);
    });
    await gesture('画笔', [0.45, 0.16], [0.76, 0.24]);
    await eventually(async () => assert.equal((await objs()).length, 5));
    await button('撤销').click();
    await eventually(async () => assert.equal((await objs()).length, 4));
    await button('重做').click();
    await eventually(async () => assert.equal((await objs()).length, 5));
    await button('放大标注').click();
    const enlarged = await draw.boundingBox();
    assert.ok(enlarged.width > surface.width * 1.2);
    await win.locator('.markupStage').focus();
    await win.keyboard.down('Space');
    await win.mouse.move(surface.x + surface.width * 0.5, surface.y + surface.height * 0.5);
    await win.mouse.down();
    await win.mouse.move(surface.x + surface.width * 0.5 + 30, surface.y + surface.height * 0.5 + 20, {
      steps: 4,
    });
    await win.mouse.up();
    await win.keyboard.up('Space');
    const moved = await draw.boundingBox();
    assert.ok(Math.abs(moved.x - enlarged.x - 30) < 2, 'Pan delta = ' + (moved.x - enlarged.x));
    await button('全图').click();
    console.log(
      'PASS all drawing tools, constrained shape, independent style edits, inline shape labels, undo/redo, zoom and pan'
    );
    await require('./text-box.cjs')({ win, app, button, readState });
    if (process.env.FOLIO_SCREENSHOT_DIR) {
      await fs.mkdir(process.env.FOLIO_SCREENSHOT_DIR, { recursive: true });
      await win.screenshot({
        path: path.join(process.env.FOLIO_SCREENSHOT_DIR, 'Folio-Windows-markup.png'),
      });
    }
    await button('完成').click();
    await win.waitForSelector('dialog', { state: 'detached' });
    await win.locator('#display').click();
    await button('旋转').click();
    await readState((s) => assert.equal(s.rotations[1], 90));
    await win.locator('#zoom').selectOption('page-fit');
    await win.locator('#page').fill('2');
    await win.locator('#page').press('Enter');
    await win.locator('.card').getByRole('button', { name: '第 1 页' }).click();
    await readState((s) => assert.equal(s.page, 1));
    await win.keyboard.press('Control+d');
    await win.locator('dialog input').fill('Figure A');
    await button('确定').click();
    await readState((s) => assert.equal(s.bookmarks[0].name, 'Figure A'));
    const markRow = win.locator('.bookmarkRow');
    await markRow.hover();
    await markRow.getByRole('button', { name: '重命名' }).click();
    await win.locator('dialog input').fill('图表 A');
    await button('确定').click();
    await readState((s) => assert.equal(s.bookmarks[0].name, '图表 A'));
    await markRow.hover();
    await markRow.getByRole('button', { name: '删除书签' }).click();
    await win.locator('#navList .navEmpty').waitFor();
    assert.match(await win.locator('#navList').innerText(), /Ctrl\+D/);
    assert.equal(await win.locator('#navList button').count(), 0);
    await win.locator('#more').click();
    const addBookmark = button('添加书签');
    assert.equal(await addBookmark.locator('kbd').innerText(), 'Ctrl+D');
    await addBookmark.click();
    await win.locator('dialog input').fill('图表 A');
    await button('确定').click();
    await readState((s) => assert.equal(s.bookmarks[0].name, '图表 A'));
    assert.equal(await win.locator('#navList').getByRole('button', { name: '添加书签' }).count(), 0);
    await button('页面').click();
    await win.locator('.thumbnail img').first().waitFor();
    await button('目录').click();
    await win.locator('.navEmpty,.outlineItem').first().waitFor();
    await button('书签').click();
    // Reopen old-orientation artwork, close without edits and check that the stored scene stays identical.
    const prior = JSON.stringify((await state()).cards.find((c) => c.kind === 'pin').drawing);
    await win.locator('.card img').click();
    await button('完成').click();
    await readState((s) =>
      assert.equal(JSON.stringify(s.cards.find((c) => c.kind === 'pin').drawing), prior)
    );
    await win.keyboard.press('Control+f');
    await win.locator('#query').fill('Alpha');
    await win.waitForFunction(() => document.querySelector('#matches').textContent.includes('/ 1'));
    await win.locator('#closeFind').click();
    console.log('PASS deletion/undo, clip, draw, zoom, rotate, source navigation, bookmarks and search');
    // Send the real print layout through Chromium's PDF printer in place of a
    // physical printer dialog on the unattended runner.
    await app.evaluate(({ BrowserWindow }) => {
      const wc = BrowserWindow.getAllWindows()[0].webContents;
      wc.print = async (_options, callback) => {
        try {
          const data = await wc.printToPDF({ printBackground: true });
          globalThis.__folioPrint = data.subarray(0, 5).toString();
          callback(true, '');
        } catch (error) {
          callback(false, error.message);
        }
      };
    });
    await win.locator('#more').click();
    await button('打印当前页').click();
    await eventually(async () =>
      assert.equal(await app.evaluate(() => globalThis.__folioPrint), '%PDF-')
    );
    if (process.env.FOLIO_SCREENSHOT_DIR) {
      await fs.mkdir(process.env.FOLIO_SCREENSHOT_DIR, { recursive: true });
      await win.screenshot({
        path: path.join(process.env.FOLIO_SCREENSHOT_DIR, 'Folio-Windows-reading.png'),
      });
    }
    await win.locator('#more').click();
    await button('导出 Markdown 笔记…').click();
    const md = await eventually(() => fs.readFile(path.join(dir, 'notes.md'), 'utf8'));
    assert.match(md, /> Alpha result\n> Beta result/);
    const imgPath = md.match(/!\[\]\((figures-[^\)]+\.png)\)/)[1];
    assert.ok((await fs.stat(path.join(dir, imgPath))).size > 100);
    await win.locator('#more').click();
    await button('提取页面为 PDF…').click();
    await win.locator('dialog input').fill('2, 1–2');
    await button('确定').click();
    await eventually(async () => assert.ok((await fs.stat(path.join(dir, 'pages.pdf'))).size > 500));
    await win.locator('#more').click();
    await button('返回最近打开').click();
    await win.locator('#recents button').first().click();
    await win.waitForSelector('.card img');
    await readState((s) => {
      assert.equal(s.cards.length, 3);
      assert.equal(s.rotations[1], 90);
    });
    await win.locator('#more').click();
    await button('界面语言').click();
    await win.locator('#more').click();
    await button('Settings…').click();
    await button('Dark').click();
    await win.waitForFunction(() => document.documentElement.dataset.dark === 'true');
    await win.locator('dialog .dialogHead button').click();
    console.log('PASS Markdown + PNG, reordered PDF, saved state and language/appearance controls');
    await win.locator('#ask').click();
    await button('Prompts').click();
    await win.locator('dialog textarea').fill('Explain this figure');
    await button('OK').click();
    await button('Explain this figure').click();
    assert.equal(await win.locator('#question').inputValue(), 'Explain this figure');
    if (process.platform === 'win32') {
      await win.locator('#more').click();
      await button('Settings…').click();
      await button('AI services').click();
      await win.locator('dialog input[type=url]').fill('https://folio-test.invalid/v1');
      await win.locator('dialog input:not([type])').fill('fixture-model');
      await win.locator('dialog input[type=password]').fill('folio-fixture-dummy-key');
      await button('Save and use').click();
      await win.waitForFunction(() =>
        document.querySelector('dialog input[type=password]')?.placeholder.includes('saved')
      );
      await win.locator('dialog .dialogHead button').click();
      const ciphertext = await fs.readFile(path.join(profile, 'Folio', 'credentials.json'), 'utf8');
      assert.ok(!ciphertext.includes('folio-fixture-dummy-key'));
      await app.evaluate(() => {
        globalThis.fetch = async (url, options) => {
          if (url !== 'https://folio-test.invalid/v1/chat/completions')
            throw Error('Unexpected destination');
          if (options.headers.Authorization !== 'Bearer folio-fixture-dummy-key')
            throw Error('Credential mismatch');
          const body = JSON.parse(options.body);
          globalThis.__folioTestRequest = body;
          return new Response(
            'data: ' +
              JSON.stringify({ choices: [{ delta: { content: '**Result** $x^2$' } }] }) +
              '\n\ndata: [DONE]\n\n',
            { headers: { 'content-type': 'text/event-stream' } }
          );
        };
      });
      await button('Figures').click();
      await win.locator('.card').dragTo(win.locator('#ask'));
      await win.locator('#question').fill('Explain the reference');
      const files = win.locator('.composer input[type=file]');
      await files.setInputFiles({
        name: 'fixture.txt',
        mimeType: 'text/plain',
        buffer: Buffer.from('fixture passage'),
      });
      await win.waitForFunction(() =>
        document.querySelector('.composer')?.innerText.includes('fixture.txt')
      );
      await button('Preview').click();
      await win.locator('dialog img').waitFor();
      await win.locator('dialog .dialogHead button').click();
      await button('Send').click();
      await win.waitForSelector('.message math');
      await readState((s) => assert.match(s.chats[0].turns[0].answer, /Result/));
      const payload = await app.evaluate(() => globalThis.__folioTestRequest);
      assert.match(JSON.stringify(payload), /fixture passage/);
      assert.equal(payload.messages.at(-1).content.filter((p) => p.type === 'image_url').length, 1);
      console.log(
        'PASS Windows credential encryption, drag-to-AI, attachment, preview, streaming, math and chat history'
      );
    }
    // Check encrypted input and the extracted PDF through the real open dialog path.
    const locked = path.join(dir, 'locked.pdf'),
      unlocked = path.join(dir, 'unlocked.pdf');
    const wasm = await WebAssembly.compile(
      await fs.readFile(require.resolve('@jspawn/qpdf-wasm/qpdf.wasm'))
    );
    const qpdf = await require('@jspawn/qpdf-wasm')({
      instantiateWasm(imports, ready) {
        const instance = new WebAssembly.Instance(wasm, imports);
        ready(instance);
        return instance.exports;
      },
    });
    qpdf.FS.writeFile('/in.pdf', original);
    assert.equal(
      qpdf.callMain(['/in.pdf', '--encrypt', 'reader-test', 'owner-test', '256', '--', '/locked.pdf']),
      0
    );
    await fs.writeFile(locked, qpdf.FS.readFile('/locked.pdf'));
    await app.evaluate(
      ({ dialog }, paths) => {
        dialog.showOpenDialog = async () => ({ filePaths: [paths.locked] });
        dialog.showSaveDialog = async () => ({ filePath: paths.unlocked, canceled: false });
      },
      { locked, unlocked }
    );
    await win.keyboard.press('Control+o');
    await win.locator('dialog input[type=password]').fill('reader-test');
    await button('OK').click();
    await win.waitForFunction(() => document.title.startsWith('locked.pdf'));
    await win.locator('#more').click();
    await button('Extract pages to PDF…').click();
    await win.locator('dialog input').fill('2, 1');
    await button('OK').click();
    await eventually(async () => assert.ok((await fs.stat(unlocked)).size > 500));
    await app.evaluate(({ dialog }, out) => {
      dialog.showOpenDialog = async () => ({ filePaths: [out] });
    }, unlocked);
    await win.keyboard.press('Control+o');
    await win.waitForFunction(() => document.title.startsWith('unlocked.pdf'));
    assert.equal(await win.locator('#pageCount').textContent(), '/ 2');
    const extraction = await win.evaluate(async () => {
      const { S } = await import('./ui.mjs');
      const first = await S.doc.getPage(1),
        second = await S.doc.getPage(2);
      return {
        angle: first.rotate,
        empty: !(await first.getTextContent()).items.length,
        marks: (await second.getAnnotations()).filter((a) => a.subtype === 'Highlight').length,
      };
    });
    assert.ok(extraction.angle !== 0 && extraction.empty);
    assert.equal(extraction.marks, 1);
    console.log(
      'PASS AES-256 unlock, ordered unencrypted export, source rotation and original PDF annotations'
    );
    assert.deepEqual(await fs.readFile(pdf), original);
    if (process.env.FOLIO_SCREENSHOT_DIR)
      await require('./sidebar-preview.cjs')({
        app,
        win,
        dir,
        root,
        output: process.env.FOLIO_SCREENSHOT_DIR,
      });
    // Open a card written with the previous text wrapping settings. Its PDF page
    // has been rotated since capture. Quit with unconfirmed text still in focus.
    const legacy = await state();
    const legacyPin = legacy.cards.find((c) => c.kind === 'pin');
    const legacyBox = legacyPin.drawing.objects.find((o) => o.type === 'FolioTextBox');
    legacyBox.text = 'Legacy';
    legacyBox.splitByGrapheme = false;
    legacyBox.strokeWidth = 4;
    await fs.writeFile(statePath, JSON.stringify(legacy));
    await app.evaluate(({ dialog }, pdf) => {
      dialog.showOpenDialog = async () => ({ filePaths: [pdf] });
    }, pdf);
    await win.keyboard.press('Control+o');
    await win.locator('.card img[data-id="' + legacyPin.id + '"]').click();
    await win.locator('.markupStage .upper-canvas').waitFor();
    await win.waitForFunction(
      () =>
        document.querySelector('.markupPaper').getBoundingClientRect().width > 40 &&
        document.querySelector('.upper-canvas').clientWidth ===
          document.querySelector('.markupStage').clientWidth
    );
    const point = await win.evaluate(async () => {
      const { S } = await import('./ui.mjs');
      const pin = S.state.cards.find((c) => c.kind === 'pin'),
        box = pin.drawing.objects.find((o) => o.type === 'FolioTextBox');
      const paper = document.querySelector('.markupPaper'),
        area = paper.getBoundingClientRect();
      const x = box.left + box.width / 2,
        y = box.top + box.height / 2;
      return {
        x: area.x + (1 - y / pin.drawingSize.height) * area.width,
        y: area.y + (x / pin.drawingSize.width) * area.height,
      };
    });
    await win.mouse.dblclick(point.x, point.y);
    const activeInput = win.locator('.markupTextInput');
    assert.equal(await activeInput.inputValue(), 'Legacy');
    await activeInput.fill('关闭时保存的中文');
    await Promise.all([
      win.waitForEvent('close'),
      app.evaluate(({ BrowserWindow }) => {
        setTimeout(() => BrowserWindow.getAllWindows()[0].close(), 0);
      }),
    ]);
    await readState((s) => {
      const pin = s.cards.find((c) => c.kind === 'pin');
      assert.equal(pin.rotation, 90);
      assert.equal(pin.drawing.objects.find((o) => o.type === 'FolioTextBox').text, '关闭时保存的中文');
    });
    console.log(
      'PASS edited legacy text after page rotation and persisted active typing on window close'
    );
    assert.deepEqual(errors, []);
    console.log('PASS original file is byte-identical; no renderer errors');
  } catch (e) {
    if (win && !win.isClosed())
      console.error('Window:', (await win.locator('body').innerText({ timeout: 2000 })).slice(-2400));
    throw e;
  } finally {
    if (!win?.isClosed()) await app.close();
    await fs.rm(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 250 });
  }
}
run().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
