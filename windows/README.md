# Folio for Windows

Windows x64 的桌面客户端。当前测试安装包为 `FolioSetup-1.1.0-x64.exe`。PDF.js、字体映射、KaTeX 和 qpdf 随程序分发。阅读与导出可离线使用。

Ctrl+O 打开文件，Ctrl+F 查找，Ctrl+L 定位，Ctrl+D 添加书签，Ctrl+[ 返回，Ctrl+P 打印。右上角“框选图表”可将区域固定在右侧。点便签预览图可标注，拖入“问 AI”可引用原始裁图。标注时按住 Shift 可画正圆、正方形或锁定直线角度。选择「文本框」后单击图上空白处或拖出范围，即可输入多行文字。双击已有文字可继续编辑，Esc 取消本次修改。双击形状可输入文字，拖动箭头端点可调整方向。空格加拖动可平移，Ctrl 加滚轮可缩放，Ctrl+0 显示全图。Ctrl+Enter 在标注时结束文字编辑，在问答时发送问题。每篇论文按 PDF 文件内容识别，阅读记录存放在用户应用数据目录，API 密钥由 Electron safeStorage 调用 Windows DPAPI 加密。

## 构建

在本目录安装 Node.js 24 后运行：

```sh
npm ci
npm test
npm run dist
```

输出位于仓库的 `dist/windows/`。运行 `npm run start` 开发调试。执行 `npm run prepare:assets` 后，`npm run test:ui` 使用临时用户目录、真实窗口和样例 PDF 做回归。`FOLIO_TEST_EXE` 可指定已安装的 Folio.exe。Windows 工作流会构建、静默安装并测试已安装的程序。
