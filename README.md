# process-videos

> 把视频教程预处理成可结构化消费的素材（字幕 + 关键帧），配合 AI 助手快速产出跟敲文档。

**适用场景**：你在跟着视频课程学习（尤其是编程课），视频内容繁琐但讲解节奏慢，你希望 AI 帮你整理成一份"看文档就能敲代码"的 Markdown 笔记，而不是被迫反复拖进度条。

## 它解决什么问题

让 AI 直接"看"视频既慢又不准：`.mp4` 文件大、语音转文字要几十分钟、截图分析很耗 token。

本项目把这个过程**拆成两步**：

1. **一次性预处理**（本仓库的 `preprocess-videos.sh`）：对视频做音频提取 + 字幕转写 + 关键帧截图，所有产物缓存到视频同级的 `video-notes-cache/`
2. **按需消费**（配套的 Cursor Skill）：AI 读缓存里的字幕和截图，几分钟就能产出文档

结果：同一批视频**预处理一次**（可能要 1-3 小时，但是一次性的后台任务），之后想让 AI 整理成什么样的文档都只需几分钟。

---

## 特性

- **缓存幂等**：用文件大小 + mtime 做指纹，视频没变就跳过不重跑
- **并行优化**：音频/截图提取并行，whisper 转写串行（因为单任务已吃满多核）
- **失败隔离**：单个视频失败不影响其他，支持 `--retry-failed` 重试
- **配套 Cursor Skill**：[SKILL.md](SKILL.md) 可复制到 `~/.cursor/skills-cursor/video-to-doc/`，让 AI 自动按规范产出文档
- **零侵入**：字幕不会搬到视频目录污染文件列表，默认全部在 `video-notes-cache/` 里

---

## 环境准备

### macOS

```bash
brew install ffmpeg whisper-cpp
```

### Linux

```bash
# ffmpeg
sudo apt install ffmpeg        # Debian/Ubuntu
sudo dnf install ffmpeg        # Fedora

# whisper-cpp 需要从源码编译：https://github.com/ggerganov/whisper.cpp
# 编译后把 main 改名或软链到 whisper-cli，放到 PATH 中
```

**首次运行**脚本时，如果本地没有 whisper 模型，会自动下载 `ggml-medium.bin`（约 1.4GB）到 `~/whisper-models/`。中文识别效果较好。

---

## 快速开始

```bash
# 1. 克隆本仓库到任意位置
git clone https://github.com/<your-name>/process-videos.git ~/Tools/process-videos

# 2. 对一个章节目录做预处理（目录下 20-30 个视频都会被处理）
~/Tools/process-videos/preprocess-videos.sh "/path/to/第16章 xxx"

# 3. 查看处理状态
~/Tools/process-videos/preprocess-videos.sh "/path/to/第16章 xxx" --status

# 4. 预处理完毕后，打开 Cursor，让 AI 帮你产出文档（见下方"提示词示例"）
```

### 处理结果

```
/path/to/第16章 xxx/
├── 16-1 xxx.mp4
├── 16-2 xxx.mp4
├── ...
└── video-notes-cache/          ← 预处理产物
    ├── manifest.tsv            ← 缓存索引
    ├── 16-1 xxx/
    │   ├── transcript.srt      ← 带时间戳的中文字幕
    │   ├── transcript.txt      ← 纯文本字幕
    │   ├── frames/
    │   │   ├── frame_001.jpg   ← 每 15 秒一张截图
    │   │   └── ...
    │   ├── .fingerprint
    │   └── whisper.log
    ├── 16-2 xxx/
    │   └── ...
```

---

## 命令参考

```bash
preprocess-videos.sh <视频目录>                    预处理目录下所有视频
preprocess-videos.sh <视频目录> --model small      换 whisper 模型
preprocess-videos.sh <视频目录> --status           查看缓存状态
preprocess-videos.sh <视频目录> --clean            删除缓存（交互确认）
preprocess-videos.sh <视频目录> --retry-failed     重跑失败的视频
preprocess-videos.sh --version                     显示版本
preprocess-videos.sh --help                        显示帮助
```

### whisper 模型选择

| 模型 | 大小 | 中文识别 | 速度（相对实时） |
|---|---|---|---|
| tiny | 75MB | 差 | ~10-20x |
| base | 142MB | 一般 | ~7-10x |
| small | 466MB | 尚可 | ~3-5x |
| **medium（默认）** | 1.4GB | **好** | ~1-2x |
| large-v3 | 2.9GB | 最好 | ~0.5x |

> 速度是 Apple Silicon 上的大致经验值，"1x" 代表转写耗时 ≈ 音频时长。

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `WHISPER_MODELS_DIR` | `~/whisper-models` | 模型存放目录 |
| `FRAME_INTERVAL` | `15` | 截图间隔（秒） |
| `VIDEO_EXTENSIONS` | `mp4 mkv mov avi webm flv` | 识别的视频扩展名 |

---

## 配合 AI 助手使用

### 第一步：把 `SKILL.md` 接入你的 AI 助手

**Cursor** 用户：

```bash
mkdir -p ~/.cursor/skills-cursor/video-to-doc
cp ~/Tools/process-videos/SKILL.md ~/.cursor/skills-cursor/video-to-doc/SKILL.md
```

**其他 AI 助手**（Claude Code、Windsurf 等）：把 `SKILL.md` 内容作为系统提示词或工作规范的一部分即可。

### 第二步：按下面的提示词示例发指令

---

## 提示词示例

### 场景 1：对某章节视频做预处理

```
请先跑预处理脚本，把这个目录里的所有视频转写好：
/Users/me/videos/第16章-动画开发

  运行：~/Tools/process-videos/preprocess-videos.sh "<上面的路径>"

跑完告诉我 status。
```

预期：AI 会帮你构造命令、后台跑、完成后报告状态。耗时取决于视频总时长，通常 1-3 小时。

---

### 场景 2：整理单个视频成跟敲文档

```
帮我整理这个视频的跟敲文档（预处理已完成）：
/Users/me/videos/第16章-动画开发/16-5 过渡动画实现.mp4

要求：
- 按视频顺序分步骤
- 每个步骤附时间戳（格式：⏱ MM:SS - MM:SS）
- 文档放到 docs/video-notes/ 下
```

预期：AI 读 `video-notes-cache/16-5 过渡动画实现/transcript.srt` + 若干张关键帧，对照你项目的当前代码，产出完整文档。

---

### 场景 3：多节视频合并成一份合集

```
把这 4 节视频合并成一份跟敲文档，按功能重组、一步到位（不要"先写错再改"的返工）：
- 16-5 xxx.mp4
- 16-6 xxx.mp4
- 16-7 xxx.mp4
- 16-8 xxx.mp4

放到 docs/video-notes/ 下，文件名用合集格式。
```

预期：AI 产出 1 份按**文件/功能模块**组织的总文档，而不是按视频章节堆叠。

---

### 场景 4：只快速了解视频讲了什么

```
帮我看一下这个视频大致讲了什么，不用出代码：
/Users/me/videos/第16章-动画开发/16-1 章节前言.mp4
```

预期：AI 读字幕给一段摘要，不生成跟敲文档。

---

### 场景 5：检查预处理状态

```
看一下这个目录的视频都处理到什么程度了：
/Users/me/videos/第16章-动画开发
```

预期：AI 运行 `--status` 列出每个视频的完成情况。

---

## 工作原理

```
  ┌──────────────┐       ┌───────────────────────┐      ┌──────────────┐
  │  video files │──────▶│ preprocess-videos.sh  │─────▶│  video-notes-│
  │  (*.mp4)     │       │  (ffmpeg + whisper)   │      │  cache/      │
  └──────────────┘       └───────────────────────┘      └──────┬───────┘
                                                                │
                                                                │ (SKILL 引导 AI 读取)
                                                                ▼
                                                       ┌──────────────────┐
                                                       │  Markdown 文档   │
                                                       │  (docs/video-    │
                                                       │   notes/xxx.md)  │
                                                       └──────────────────┘
```

**关键设计**：预处理产物是 AI 友好的（文本 SRT + JPG），所以 AI 消费成本极低，想重写文档只需几分钟。

---

## 常见问题

### Q：模型下载很慢怎么办？

手动从 HuggingFace 下载后放到 `~/whisper-models/`：

```bash
curl -L -o ~/whisper-models/ggml-medium.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin
```

### Q：中文识别有错别字？

whisper medium 对中文口语的准确率约 85-92%，有错别字正常。错别字不影响 AI 理解内容（AI 会结合上下文矫正）。如果要更高质量，用 `--model large-v3`（但更慢且需要 3GB 模型）。

### Q：如何递归处理子目录？

当前版本只处理一级目录（`-maxdepth 1`）。多章节的话分别对每个章节目录跑一遍。如果你有递归需求，欢迎 PR。

### Q：某个视频处理失败了？

先看失败原因：

```bash
cat "/path/to/video-notes-cache/失败的视频/whisper.log"
```

常见原因：
- 磁盘空间不足
- 视频文件损坏
- whisper 模型文件损坏（删除后重新下载）

然后用 `--retry-failed` 只重跑失败的。

### Q：想删除某个视频的缓存重跑？

删除缓存下对应的子目录即可：

```bash
rm -rf "/path/to/video-notes-cache/要重跑的视频"
```

下次运行时会自动重新处理这一个。

---

## License

MIT License，详见 [LICENSE](LICENSE)。

## 贡献

欢迎 PR！尤其以下方向：

- Windows / Linux 测试与兼容性
- 递归处理子目录
- 支持 YouTube 下载链接直接处理
- 支持其他语言（目前是中文优先）
