# 阅读器

原生 SwiftUI iOS 阅读器，支持 TXT、EPUB 文字导入、分页与滚动阅读、书签、全文搜索和局域网网页传书。最低 iOS 17，Bundle Identifier 为 `cn.nicemoe.book`。

## 开发与构建

用 Xcode 16 或更新版本打开 `Photo.xcodeproj`，选择 `Photo` scheme。真机运行需要配置自己的签名 Team。

```bash
python3 Tools/Checks/run_reader_tests.py
xcodebuild build -project Photo.xcodeproj -scheme Photo \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

回归测试使用项目中的真实解析与存储代码，检查 EPUB 短章节、相对路径、CRC、损坏的 XML/ZIP、解压限制、Unicode 定位、TXT 章节内容保留以及并发快照写入顺序。测试需要 macOS 和 Swift 编译器。

推送 `main` 后 GitHub Actions 先执行回归测试，再构建未签名 IPA，可从运行页面的 Artifacts 下载。未签名 IPA 需要自行签名后安装。签名工作流支持手动触发，所需证书和描述文件 Secrets 见 `.github/workflows/build-signed-ipa.yml`。

## 使用

- 通过“文件”导入 TXT 或 EPUB；EPUB 提取文字，不保留图片和原版式。
- 在同一局域网开启 WiFi 传输，浏览器访问 App 显示的地址。端口由系统分配，重启服务后以新地址为准。
- 也可以通过系统文件共享将书放入 `Documents/Books`；回到前台时扫描新增、修改和删除的文件。
- 支持分页、卷页、滚动、自动翻页、字体、主题、亮度和书内搜索。

## 代码结构

- `BookLibrary`：书架状态、导入协调、进度及书签。
- `BookDisk`、`BookPaths`、`BookText`：文件扫描、正文存储、路径与按章读取。
- `SnapshotWriter`：串行原子保存，按修订号阻止旧快照覆盖新进度。
- `MiniZip`、`EpubParser`、`TextDecoding`、`ChapterSplitter`：格式解析与章节切分。
- `PageSource`、`Paginator`、`ChapterScrollView`：按章排版及有限容量缓存。
- `HTTPServer`、`WiFiService`、`WebUI`：本地网页传输。

正文统一存储为 UTF-8 TXT，章节表记录字节范围；阅读、搜索和书签偏移统一使用 UTF-16，与 CoreText 一致。书目和进度保存在 Application Support 的 `books.json`，章节表单独保存。

索引损坏或文件读写失败会显示错误，停止对应操作，不将失败伪装成空书架、空正文或导入成功。旧版本缺少新增字段时执行明确的数据迁移。
