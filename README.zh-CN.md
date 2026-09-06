# OpenGlasses

### 抬头看世界，开口就有帮手。

让智能眼镜成为随身 AI 助手。眼前看不懂的，开口问；听不懂的，随时翻译；值得记住的，留下线索。从获取答案到完成小事，无需掏出手机。

**AI 由你选，开口就能用，离线也能聊。**

[开始使用](#开始使用) · [探索功能](docs/CAPABILITIES.md) · [团队应用](#让专业知识来到工作现场) · [English](README.md)

---

## 需要帮助时，开口就好

### 看见，理解，然后行动

读懂一块标牌，了解眼前的设备，或把名片上的信息保存为联系人。OpenGlasses 让相机参与对话，提供场景描述、文字识别、智能采集与实时视觉指导。

*“我面前是什么？” · “保存这张名片。” · “记下这张收据。”*

[了解视觉与采集 →](docs/CAPABILITIES.md#see-and-capture)

### 让交流自然继续

随口问个问题，也可以开启连续的语音对话。翻译外语、查看实时字幕，或切换拥有不同声音、模型和唤醒词的助手。用语音、Siri，或轻点一下，就能开始。

*“开始把西班牙语翻译成英语。” · “Hey Jarvis…”*

[了解语音与翻译 →](docs/CAPABILITIES.md#talk-and-translate)

### 记住那些值得记住的细节

记下停车位置，保存有关人物和地点的笔记，把已采集的对话整理成会议记录。启用记忆回放后，还能补听刚才错过的内容。留下的线索，日后开口就能查。

*“记住，我的车停在 B 区三层。” · “刚才说了什么？”*

[了解记忆与回顾 →](docs/CAPABILITIES.md#remember-and-recall)

### 想做什么，说出来

查日程、设提醒、找路线、控制音乐，或打开客厅的灯。连接 Home Assistant、Siri 快捷指令、MCP 工具服务器和 OpenClaw，把常用服务带进对话。教会助手一套日常操作，再用你起的名字调用它。

*“今天有什么安排？” · “打开客厅的灯。”*

[了解操作与集成 →](docs/CAPABILITIES.md#take-action)

### 分享你眼中的世界

用语音拍照、录视频，通过 RTMP 直播，或通过 WebRTC 把实时画面分享给浏览器中的观众。兼容的显示眼镜还能将回答、字幕和下一步任务呈现在眼前。

[了解拍摄与分享 →](docs/CAPABILITIES.md#see-and-capture) · [查看显示支持 →](docs/CAPABILITIES.md#devices-and-displays)

## 你的助手，由你选择

使用云端模型，在自己的服务器上运行 AI，或让整套语音交互都在 iPhone 上完成。OpenGlasses 允许你分别选择 AI 模型、语音识别和朗读引擎，也能为不同请求分配不同模型。

### 没有网络，iPhone 上的 AI 也能陪你聊

走出 Wi-Fi 和移动网络覆盖范围，助手依然随行。通过 **Apple MLX** 或 **llama.cpp** 运行兼容的本地模型，也支持导入 **GGUF** 模型。搭配 **SenseVoice** 语音识别与 **Kokoro** 语音合成，即可在手机上完成整套语音对话，无需云端 API 密钥。

提前下载模型，选用本地引擎，并为工具启用离线模式。模型能否运行及其表现取决于 iPhone 的硬件；视觉理解与工具调用能力取决于所选模型。联网服务仍需网络连接。

你还可以决定启用哪些工具，检查发送给助手的上下文，并查看网络活动。

[选择 AI →](docs/CAPABILITIES.md#choose-your-ai) · [隐私控制 →](docs/CAPABILITIES.md#privacy-and-control)

## 让专业知识来到工作现场

**Field Assist 现场作业助手**让操作流程与参考资料随问随到。按步骤完成作业，口述读数，查询故障，遇到难题时请远程专家一起看现场。

团队可以导入自己的手册与知识库，获取附有来源的答案，并导出会话记录。临床录音功能另提供生物识别访问控制、数据保留设置、审计记录及医疗数据导出选项。

这些功能按不同权限等级开放。[了解专业功能](docs/CAPABILITIES.md#field-and-clinical-work)、[创建现场知识库](docs/field-assist-vault-guide.md)，或[联系 Skunkworks NZ](mailto:g@skunkworks.kiwi)了解团队授权。

## 开始使用

准备一台运行 **iOS 26 或更高版本的 iPhone**。配对兼容的 **Meta 智能眼镜**，即可免手持使用相机和音频功能；没有眼镜时，也可以先体验手机端功能，并使用手机相机作为替代。

1. **构建应用。** 按照[源码构建指南](docs/BUILDING.md)准备 Xcode 26+、依赖项、签名及 Meta 开发者配置。
2. **选择 AI。** 在 **设置 → AI 模型** 中连接服务商，或下载兼容的本地模型。
3. **连接眼镜。** 在 Meta AI 应用中配对，完成开发者设置，然后在 OpenGlasses 中连接并授予相机权限。
4. **开口试试。** 启用监听，说出 **“OpenGlasses”**，或轻点麦克风。先问问眼前的东西是什么。

相机与显示功能取决于设备及 SDK 支持。Ray-Ban Display 提供镜内显示接入；**EVEN G2 支持仍处于实验阶段**。选择设备组合前，请查看[设备说明](docs/CAPABILITIES.md#devices-and-displays)。

## 继续探索

以下详细指南目前为英文。

| 你想做什么 | 从这里开始 |
|---|---|
| 了解功能、示例与配置 | [功能指南](docs/CAPABILITIES.md) |
| 构建、配置或排查问题 | [源码构建指南](docs/BUILDING.md) |
| 导入现场手册与操作流程 | [Field Assist 知识库指南](docs/field-assist-vault-guide.md) |
| 创建可复用的助手能力 | [技能包编写指南](docs/skillpack-authoring.md) |
| 发布扩展包 | [技能包](skillpacks/README.md) · [知识库包](vaultpacks/README.md) |
| 了解工程进展与未来规划 | [开发计划](docs/plans/README.md) |

## 一起把它做得更好

欢迎贡献新的工具与集成，改进本地推理、翻译和日常使用体验。Fork 项目，提交 Pull Request 即可参与。

OpenGlasses 采用 **[BSL 1.1](LICENSE)，源代码可用**，允许非商业用途，注明于 2030 年 3 月 24 日转为 Apache 2.0。商业用途需要另行授权，请联系 [g@skunkworks.kiwi](mailto:g@skunkworks.kiwi)。

由 **Skunkworks NZ** 的 [Skunk0](https://github.com/straff2002) 开发。本项目独立于 Meta 和 Anthropic。
