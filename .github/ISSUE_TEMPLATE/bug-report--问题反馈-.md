---
name: Bug report (问题反馈)
about: 描述你在使用中遇到的问题（issue 语言：1. 中文；2. 英文）
title: ''
labels: ''
assignees: ''

---

**提问前请确认**
1. 已搜索过已有 issue，确认不是重复问题
2. 已说明问题发生在**客户端**还是**服务端**（本仓库只包含客户端）
3. issue 标题尽量包含模块，例如：`[播放] 转码流首帧黑屏`

**Describe the bug 描述你遇到的问题**
简洁有效的说明。

**To Reproduce 如何重现问题**
1. 连接服务器 → 登录
2. 进入 '...' 页面
3. 执行 '...' 操作
4. 得到 '...' 结果

**Expected behavior 期待的效果**
简单描述预期行为。

**Screenshots / Logs 截图或日志**
如有必要请附截图；崩溃或播放失败请附 HDC 日志（`hdc hilog`）。
**提交前请删除日志中的服务器地址、用户名、访问令牌等敏感信息。**

**版本说明**
- 客户端版本 / 构建方式：[e.g. 自编译 debug HAP / release HAP]
- 设备型号与系统：[e.g. HarmonyOS 5.0.0 / Mate 60]
- 安装包是否签名：[是 / 否（未签名 HAP 无法安装，请先看 README「签名」章节）]
- Jellyfin 服务端版本：[e.g. 10.10.3]
- 服务器访问方式：[局域网 http:// / 反向代理子路径 / https://]
- 播放相关问题时补充：媒体编码格式、是否转码（服务端 Dashboard 可见）

**Additional context 其他说明**
添加你认为有必要的内容，否则不写。
