# Mac_bilibili

一款面向 macOS 的哔哩哔哩第三方客户端，使用 SwiftUI 构建，注重原生桌面体验与视频播放能力。

**当前版本：20260718**

## 功能概览

- **首页推荐** — 浏览推荐视频流，支持加载更多
- **搜索** — 视频 / UP 主 / 番剧搜索，搜索历史与发现页
- **关注 & 排行** — 关注动态与热门排行
- **历史 & 收藏** — 同步观看历史与收藏列表（需登录）
- **视频播放** — 内置播放器，支持进度记忆、全屏、弹幕显示与设置
- **视频详情** — 评论、分 P、点赞/投币/收藏等互动信息
- **用户主页** — UP 主资料、投稿、动态；关注 / 粉丝列表
- **账号登录** — 通过内置 Web 登录同步 B 站 Cookie

## 系统要求

- macOS 27.0 或更高版本
- Xcode（建议使用最新 Beta / 与部署目标匹配的版本）

## 构建与运行

### 直接下载（推荐）

前往 [Releases](https://github.com/gaoxipeng/Mac_bilibili/releases) 下载最新 `bilibili-20260718-macOS.zip`，解压后将 `bilibili.app` 拖入「应用程序」即可。

> 当前安装包未签名/未公证。若 macOS 提示无法打开，请在「系统设置 → 隐私与安全性」中允许运行。

### 从源码构建

1. 克隆仓库：

   ```bash
   git clone https://github.com/gaoxipeng/Mac_bilibili.git
   cd Mac_bilibili
   ```

2. 用 Xcode 打开 `bilibili.xcodeproj`

3. 选择 **bilibili** scheme，运行目标选 **My Mac**

4. 点击 Run（⌘R）编译并启动

也可在终端构建（需已安装 Xcode 命令行工具）：

```bash
xcodebuild -scheme bilibili -destination 'platform=macOS' build
```

## 项目结构

```
Mac_bilibili/
├── bilibili/              # 应用源码
│   ├── bilibiliApp.swift  # 入口
│   ├── ContentView.swift  # 主导航与侧边栏
│   ├── AppModel.swift     # 全局状态与数据加载
│   ├── BilibiliAPI.swift  # B 站 API 封装
│   ├── AppViews.swift     # 首页、历史、关注等列表视图
│   ├── VideoDetailView.swift
│   ├── SearchViews.swift
│   └── …
└── bilibili.xcodeproj
```

## 技术栈

- **UI**：SwiftUI + 部分 AppKit（播放器、弹幕层、Web 登录）
- **网络**：URLSession，调用 B 站公开/需登录接口
- **播放**：AVFoundation
- **弹幕**：XML 解析 + 自研弹幕引擎与 overlay 渲染

## 登录说明

在侧边栏进入 **「我的」**，使用内置登录页完成 B 站账号授权。登录凭证保存在本机 Application Support 目录，用于拉取关注、历史、收藏等个人数据。

## 免责声明

本项目为个人学习与实验用途，**与哔哩哔哩官方无关**。请遵守 B 站用户协议与相关法律法规，勿用于商业用途或大规模爬取。API 与页面结构可能随时变化，功能不保证长期可用。

## 许可证

暂未指定开源许可证。如需二次分发或商用，请先与仓库维护者联系。
