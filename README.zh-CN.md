# OpenGlasses

[English](README.md)

一款开源的语音 AI 助手应用，专为 Ray-Ban Meta 智能眼镜打造。内置 85+ 原生工具，支持多 LLM（云端 + 本地设备）并自动路由模型，多角色同时唤醒，在 Ray-Ban Display 眼镜上提供镜内 HUD 与免提任务操作，本地设备知识图谱，实时翻译，免提现场作业指导，实时视觉教练，MCP 工具服务器，以及 CarPlay + Apple Watch 配套应用——全部通过语音免提控制。

> **注意**：Meta Wearables SDK 目前处于**开发者预览**阶段。尚不支持 App Store 分发——每位用户需使用自己的 Meta 开发者凭据从源码构建应用。

---

## 快速开始

1. 构建并安装到你的 iPhone 上（参见[从源码构建](#从源码构建)）
2. 在 **设置 → AI 模型** 中添加 AI 模型（Anthropic、OpenAI、Gemini 或本地模型）
3. 通过 Meta AI 应用配对你的 Ray-Ban Meta 眼镜
4. 说 **"Hey OpenGlasses"** 然后提问

---

## 功能特性

### 角色 — 多 AI 个性

每个角色都有自己的唤醒词、AI 模型和个性。所有角色同时监听。

| 语音指令 | 功能说明 |
|---------|---------|
| "Hey Claude" | 路由到 Claude Sonnet，使用你的专业提示词 |
| "Hey Jarvis" | 路由到本地设备模型，简洁风格 |
| "Hey Computer" | 路由到 GPT-4o，技术型人格 |

**配置方法：** 设置 → 角色 → 添加。选择唤醒词，分配模型和提示词预设。

### 本地设备 LLM

完全在 iPhone 上运行 AI 模型——无需互联网、无需云端、无需 API 密钥。

1. 设置 → AI 模型 → 添加模型 → 选择 **"Local (On-Device)"**
2. **下载与管理模型** → 从 HuggingFace 下载
3. 选择已下载的模型并点击 **添加**

**推荐模型：**

| 模型 | 大小 | 最适用场景 |
|------|------|-----------|
| **Gemma 4 E2B**（默认 Agent） | 3.6 GB | 最佳本地 Agent——视觉、工具调用、140+ 种语言（需 8 GB 内存） |
| SmolVLM2 2.2B | 1.5 GB | 视觉——识别照片 + 视频 |
| Qwen 2.5 3B | 1.8 GB | 强大的文本推理 + 工具调用 |
| Gemma 2 2B | 1.5 GB | 轻量级通用用途 |
| Qwen 2.5 0.5B | 0.4 GB | 超轻量，基础功能 |

**Gemma 4 E2B** 是默认的本地 Agent——未配置云端模型时会自动运行。模型持久化存储，下载后可完全离线运行。在 设置 → 工具 中启用 **离线模式** 可禁用需要互联网的工具。

### 85+ 原生工具

全部通过语音激活。自然表达你的需求——AI 会选择合适的工具。

| 类别 | 工具 |
|------|------|
| **信息查询** | 网络搜索（Perplexity + DuckDuckGo）、新闻、天气、日期/时间、词典、汇率 |
| **生产力** | 日历、提醒事项、闹钟、计时器、番茄钟、备忘录、上下文笔记（GPS+时间标记）、剪贴板 |
| **通讯** | 电话、iMessage、WhatsApp、Telegram、电子邮件、联系人查询 |
| **导航** | 路线规划（Apple/Google Maps）、附近地点、保存位置、地理围栏提醒 |
| **媒体** | 音乐控制（播放/暂停/跳过 + 按歌曲/艺术家搜索）、Shazam 歌曲识别、打开应用 |
| **智能家居** | HomeKit（灯光、开关、风扇、恒温器、门锁、场景）、Home Assistant（REST API）、Siri 快捷指令 |
| **视觉** | QR/条形码扫描器、人脸识别、智能捕获（名片/收据/海报 → 操作）、货币/药品/颜色识别（无障碍）、隐私滤镜 |
| **记忆** | 物品记忆（"我的钥匙在哪里？"）、社交上下文（按人保存的信息）、用户记忆、语音教学技能 |
| **AI 功能** | 实时翻译、实时教练（实时视觉指导）、记忆回放（环境音频回溯）、环境字幕、会议摘要、对话摘要 |
| **健身** | 运动追踪、锻炼日志、HealthKit、姿势分析、步数目标 |
| **设备** | 手电筒、亮度、设备信息、步数统计 |
| **安全** | 紧急信息（本地号码 + GPS）、每日简报、导航辅助（无障碍预设） |
| **集成** | OpenClaw Gateway（50+ 技能）、MCP 服务器（通用工具协议）、自定义工具 |

### 实时教练 — 实时视觉指导

眼镜会观察你正在做的事情，并循环给出简短的口头纠正——每次一句精炼的话，不重复。内置领域：体态、烹饪技巧、吉他、攀岩、运动战术——也可自定义。

| 语音指令 | 功能说明 |
|---------|---------|
| "Coach my posture" | 定期对你的体态给出口头反馈 |
| "Watch my knife technique" | 实时烹饪手法指导 |
| "Stop coaching" | 结束会话 |

### 智能捕获

对准名片、收据或活动海报——OpenGlasses 在本地设备读取并主动提供操作。

| 语音指令 | 功能说明 |
|---------|---------|
| "Save this card" | 提取 姓名/公司/电话/邮箱 → 保存到通讯录 |
| "Log this receipt" | 提取 商家/金额/日期 → 记录开支 |
| "Add this event" | 提取 标题/日期/地点 → 创建日历事件 |

### 语音教学技能

在运行时教 AI 新行为——无需编写代码。

| 语音指令 | 功能说明 |
|---------|---------|
| "Learn that when I say expense this, create a note tagged EXPENSE" | 保存技能，永久自动应用 |
| "Learn that when I say goodnight, turn off all lights" | 触发 HomeKit/HA 执行指令 |
| "List skills" | 显示所有已学技能 |
| "Forget expense this" | 删除该技能 |

### 物品记忆

记住你放置物品的位置。使用 GPS 计算距离。

| 语音指令 | 功能说明 |
|---------|---------|
| "Remember my car is in lot B level 3" | 保存位置（含 GPS + 时间戳） |
| "Where are my keys?" | "你的钥匙在厨房台面上，2 小时前放的。距离你现在的位置很近。" |
| "Where did I park?" | 检索车辆位置及距离 |

### 实时翻译

持续实时翻译外语口语。

| 语音指令 | 功能说明 |
|---------|---------|
| "Start translating Spanish to English" | 开始持续翻译 |
| "Stop translating" | 结束翻译会话，报告翻译计数 |
| "Switch to Japanese to English" | 即时切换语言 |

支持 25+ 种语言，包括西班牙语、法语、德语、日语、中文、韩语、阿拉伯语等。

### 社交上下文

建立关于你遇到的人的信息档案。

| 语音指令 | 功能说明 |
|---------|---------|
| "Remember Sarah works at Google and likes hiking" | 信息已保存 |
| "What do I know about Sarah?" | "关于 Sarah：在 Google 工作，喜欢徒步旅行。首次记录于 3 天前。" |

配合人脸识别使用——当 AI 识别某人时，可以回忆你关于他们的笔记。

### 本地设备知识大脑

一个私密的本地设备知识图谱，悄无声息地将你告诉它的一切——人物、地点、事物及其相互关系——串联起来，完全无需云端调用。笔记、社交上下文、人脸相遇记录和会议摘要都会汇入其中，AI 可以一步查询整个图谱。

| 语音指令 | 功能说明 |
|---------|---------|
| "Who did I meet at the conference?" | 回忆你遇到的人以及相遇的地点与时间 |
| "How do I know Sarah?" | 追溯将你与对方联系起来的事实与关系 |

原生优先——无需任何外部网关即可工作，所有数据都保留在手机本地。

### 打断功能

在 AI 说话时随时说出任意唤醒词即可打断。AI 会立即停止并开始聆听你的新问题。

### 提示词预设

无需重新配置即可切换 AI 个性。内置预设：

| 预设 | 风格 |
|------|------|
| **默认** | 均衡，2-4 句，对话式 |
| **简洁** | 最多 1-2 句，无废话 |
| **技术** | 精确，专业术语，信息密集 |
| **创意** | 有趣，机智，富有表现力 |
| **导航辅助** | 空间感知，障碍物检测，标志阅读 |

在 设置 → 系统提示词 中创建自定义预设。

### 自定义工具

无需编写代码即可定义新工具。映射到 Siri 快捷指令或 URL Scheme。

设置 → 透明度 → 自定义工具 → 添加：
- **快捷指令工具**：按名称触发 Siri 快捷指令
- **URL 工具**：打开带参数替换的 URL

示例：创建一个 "log_water" 工具，当 AI 判断你需要时运行你的 "Log Water" 快捷指令。

### MCP 服务器（Model Context Protocol）

从手机直接连接任何 MCP 兼容的工具服务器。

设置 → 透明度 → MCP 服务器 → 添加：
- 输入服务器 URL + 认证头
- 点击 "发现工具"——所有工具自动出现
- AI 可以与原生工具一起调用它们

热门 MCP 服务器：Home Assistant、Notion、GitHub、Slack、Todoist 等数百种。

### Home Assistant 集成

通过 REST API 直接控制你的 HA 实例——可与 HomeKit 配合使用或替代 HomeKit。

设置 → 服务 → Home Assistant：
- **HA URL**：例如 `http://192.168.1.100:8123`
- **Token**：长期访问令牌（HA → 个人资料 → 安全）

语音指令："Turn on the living room lights"、"Set thermostat to 72"、"Run the goodnight automation"、"List all sensors"

### 透明度与隐私

清楚查看 AI 接收了什么数据以及发出了哪些网络请求。

| 设置 | 显示内容 |
|------|---------|
| **工具** | 所有 85+ 工具及启用/禁用开关 |
| **提示词检视器** | 完整系统提示词、注入的上下文、Token 估算 |
| **网络活动** | 所有 HTTP 请求，按 Meta/AI/App/其他 分类 |
| **离线模式** | 一键禁用所有需要互联网的工具 |

针对**提示词注入**对智能体路径进行了加固——不可信内容（网页、扫描文本、工具输出）无法劫持助手去运行敏感工具。高影响操作仍需明确确认，并受智能体模式开关的限制。

### 相机与直播

- **语音拍照** — "take a picture" 或 "what's this?"
- **QR/条形码扫描器** — "scan this code"（Vision 框架，离线可用）
- **实时相机预览** — 实时查看眼镜视角
- **视频录制** — MP4 格式，可配置比特率
- **RTMP 直播** — 直播到 YouTube、Twitch、Kick
- **WebRTC 浏览器直播** — 可分享的 URL，点对点观看
- **隐私滤镜** — 自动模糊旁观者面部

### Ray-Ban Display HUD（镜内显示）

在 Ray-Ban **Display** 眼镜上，OpenGlasses 会将内容镜像到镜内抬头显示（HUD）——并让你通过 **Neural Band（神经腕带）**免提操作。该功能为增量式，默认关闭（设置 → 硬件 → 眼镜显示）；在没有显示屏的眼镜上为安全空操作。

- **AI 回复与实时字幕** — 语音回答和环境字幕会实时显示在镜内。
- **通知与导航卡片** — 日历与地理围栏提醒，以及逐步导航辅助指引，配有图标和安全提示样式。
- **交互式任务卡片** — 将工作流或现场作业流程以 **当前 / 下一步** 卡片呈现，并通过 Neural Band（完成 / 跳过 / 返回，或分支选择）或语音（"next"、"done"、"skip"、"back"）完成各步骤。

基于 Meta 的本地显示设计系统构建，因此对比度、颜色和易读性会自动针对波导显示进行优化。

### 文字转语音

24 种 ElevenLabs 语音（10 种女声，14 种男声），支持 iOS 备用方案：
- **女声**：Rachel、Sarah、Matilda、Emily、Charlotte、Alice、Lily、Dorothy、Serena、Nicole
- **男声**：Brian、Adam、Daniel、George、Chris、Charlie、James、Dave、Drew、Callum、Bill、Fin、Liam、Thomas

**情感感知 TTS** 自动调整语调——好消息更温暖，指令更沉稳，警告更谨慎。

### 实时模式

| 模式 | 工作原理 |
|------|---------|
| **语音模式** | 唤醒词 → 转录 → 任意 LLM → TTS（最灵活） |
| **Gemini Live** | 与 Google Gemini 的实时音频/视频流 |
| **OpenAI Realtime** | 与 OpenAI 的实时音频/视频流 |

### 智能模型路由

将模型分配到 **快速**、**均衡** 和 **最佳** 三个层级，然后让 OpenGlasses 按请求自动选择——用快速的本地模型做实时教练，用你最强的云端模型做疑难诊断。或者关闭路由，将所有请求固定到单一模型。

**配置方法：** 设置 → AI 模型 → 模型路由。

### CarPlay 与 Apple Watch

- **CarPlay** — 在车载屏幕上免提使用语音助手。
- **Apple Watch** — 配套应用与小组件，用于快速控制和一目了然的状态查看。

---

## 企业版功能

面向团队和受监管行业的商业功能。这些功能在开源核心之外单独授权——参见[许可证](#许可证)或联系 Skunkworks NZ。

### 现场作业助手 — 引导式现场服务

为技术人员及其他双手忙碌的工作提供免提的分步指导。流程会根据你的口头报告或相机所见进行分支，在每一步之前提示安全注意事项，引用其来源资料，并写入可导出的审计会话日志。遇到难题？升级到带眼镜视频的远程真人专家。领域知识存放在你可以自行编写和扩展的 **Vault（知识库）**（如制冷、暖通空调、电气）中。

| 语音指令 | 功能说明 |
|---------|---------|
| "Start a refrigeration session" | 加载知识库并开始流程 |
| "The gauge reads 38 psi" | AI 评估读数并分支到正确的下一步 |
| "Next step" / "Go back" / "Repeat that" | 免提导航流程 |
| "Call an expert" | 通过实时眼镜视频接通远程真人 |

### 医疗合规

为临床录音提供专业级保护措施，以应用内订阅形式提供。

- **静态加密** — 录音和转录文本以 `NSFileProtectionComplete` 加密保护
- **生物识别应用锁** — 每次启动均需 Face ID / Touch ID
- **审计日志** — 每个数据访问事件都带时间戳并可导出
- **医疗导出** — 支持 FHIR R4、HL7 及 PDF 导出到 Epic、Cerner 等
- **数据保留** — 可配置自动清除与安全删除
- **防数据泄露** — 禁用云端工具，排除在 iCloud 备份之外
- **国际合规框架** — HIPAA、GDPR、澳大利亚隐私法、新西兰 HIPC、PIPEDA、英国 DPA

---

## 系统要求

- **iOS 26+**
- **Xcode 26+**
- **实体 iPhone**（需要 Bluetooth、相机、麦克风）
- **Ray-Ban Meta 智能眼镜**（通过 Meta AI 应用配对）
- 至少一个 LLM：API 密钥（Anthropic、OpenAI、Gemini 等）或已下载的本地模型

---

## 从源码构建

### 1. 克隆仓库

```bash
git clone https://github.com/straff2002/OpenGlasses.git
cd OpenGlasses
```

### 2. Meta 开发者凭据

1. 前往 [wearables.developer.meta.com](https://wearables.developer.meta.com/)
2. 创建账号、组织和应用
3. 记下你的 **Meta App ID** 和 **Client Token**
4. 在 Meta 控制台 → iOS 设置中，输入你的 Apple Team ID、Bundle ID 和 Universal Link URL

### 3. 配置 Info.plist

更新 `OpenGlasses/Info.plist`：

```xml
<key>MWDAT</key>
<dict>
    <key>AppLinkURLScheme</key>
    <string>https://YOUR-DOMAIN/YOUR-PATH</string>
    <key>MetaAppID</key>
    <string>YOUR_META_APP_ID</string>
    <key>ClientToken</key>
    <string>AR|YOUR_META_APP_ID|YOUR_CLIENT_TOKEN_HASH</string>
    <key>TeamID</key>
    <string>$(DEVELOPMENT_TEAM)</string>
</dict>
```

### 4. Universal Links

在 `https://YOUR-DOMAIN/.well-known/apple-app-site-association` 托管一个 `apple-app-site-association` 文件：

```json
{
  "applinks": {
    "details": [{
      "appID": "YOUR_TEAM_ID.YOUR_BUNDLE_ID",
      "paths": ["/YOUR-PATH/*"]
    }]
  }
}
```

### 5. 启用开发者模式

在 iPhone 上：Meta AI 应用 → 设置 → 关于 → 连续点击版本号 **5 次** → 开启开发者模式。

### 6. 构建与运行

```bash
open OpenGlasses.xcodeproj
```

选择你的 iPhone，在 Signing 中设置你的 Team，然后运行（⌘R）。

---

## 配置

所有设置都在应用内完成——无需编辑源代码。

### API 密钥（设置 → AI 模型）

| 服务 | 用途 | 获取方式 |
|------|------|---------|
| Anthropic | Claude LLM | [console.anthropic.com](https://console.anthropic.com/) |
| OpenAI | GPT + Realtime | [platform.openai.com](https://platform.openai.com/) |
| Google Gemini | Gemini Live | [aistudio.google.com](https://aistudio.google.com/) |
| Groq | 快速推理 | [console.groq.com](https://console.groq.com/) |
| ElevenLabs | 自然语音 TTS | [elevenlabs.io](https://elevenlabs.io/) |
| Perplexity | 网络搜索 | [perplexity.ai/settings/api](https://perplexity.ai/settings/api) |

### 服务（设置 → 服务与集成）

| 服务 | 设置项 |
|------|--------|
| **ElevenLabs** | API 密钥 + 语音选择（24 种语音） |
| **Perplexity** | API 密钥（未设置时回退到 DuckDuckGo） |
| **直播** | 平台 + RTMP URL + 直播密钥 |
| **OpenClaw** | 启用 + 连接模式 + 主机/端口 + Token |
| **Home Assistant** | URL + 长期访问令牌 |

---

## 常见问题排查

| 问题 | 解决方案 |
|------|---------|
| 唤醒词无法检测 | 点击麦克风按钮重启；检查 Bluetooth 音频路由 |
| 眼镜无声音输出 | 在 iOS 设置中验证 Bluetooth 连接 |
| 眼镜无法连接 | 点击 "连接眼镜"；在 Meta AI 应用中启用开发者模式 |
| HomeKit 找不到设备 | HomeKit 在首次工具调用时初始化——说 "list smart home devices" 并等待 10 秒 |
| 本地模型崩溃 | Gemma 4 E2B 需要约 8 GB 内存；6GB 设备请使用更小的模型（0.5B–2B） |
| 模型下载卡住 | 保持应用在前台；短暂切到后台后下载会继续 |
| "不受信任的开发者" | 设置 → 通用 → VPN 与设备管理 → 验证（需要联网） |

---

## 依赖项

| 包 | 用途 |
|---|------|
| [meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios) | 眼镜连接 + 相机 |
| [HaishinKit](https://github.com/shogo4405/HaishinKit.swift) | RTMP 直播推流 |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 本地设备 LLM 推理 |
| [WebRTC](https://github.com/stasel/WebRTC) | 点对点浏览器直播 + 专家视频 |
| [SystemNotification](https://github.com/danielsaidi/SystemNotification) | 应用内通知横幅 |

---

## 参与贡献

欢迎贡献！这是一个完全开源的项目。Fork、改进、提交 PR。

主要贡献方向：
- 新的原生工具
- 本地模型优化
- 翻译质量改进
- 更多 MCP 服务器集成
- UI/UX 改进

## 许可证

BSL 1.1（Business Source License 1.1）——非商业用途免费。商业用途需从 Skunk0 / Skunkworks NZ 获取单独许可。2030 年 3 月 24 日转换为 Apache 2.0。详见 LICENSE 文件。

## 致谢

由 [Skunk0](https://github.com/straff2002) 在 Skunkworks NZ 构建

技术支持：[Anthropic Claude](https://www.anthropic.com/)、[Meta Wearables SDK](https://wearables.developer.meta.com/)、[Apple MLX](https://github.com/ml-explore/mlx-swift)、[ElevenLabs](https://elevenlabs.io/)、[HaishinKit](https://github.com/shogo4405/HaishinKit.swift)

---

**注意**：这是一个独立的开源项目，与 Meta 或 Anthropic 无关联。
