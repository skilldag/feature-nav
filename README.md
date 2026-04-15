# feature-nav

基于 GitNexus 的代码功能特性导航 - CLI 工具

## 安装

```bash
cd src
npm install
npm link
```

## 快速开始

```bash
# 同步数据
fn sync ~/path/to/repo

# 查看标注状态
fn st

# 标注 Label
fn save-label Components '{"feature_name":"UI组件库","feature_description":"..."}'

# 标注 Process
fn process-next
fn save-process <id> '{"feature_name":"...","description":"..."}'
```

## 命令

| 命令           | 说明                 |
| -------------- | -------------------- |
| `sync [repo]`  | 同步 GitNexus 数据   |
| `ls [name]`    | 列出/查看 labels     |
| `st`           | 查看标注进度         |
| `p <label>`    | 查看 label 下的流程  |
| `process-next` | 下一条待标注 process |
| `save-label`   | 保存 label 标注      |
| `save-process` | 保存 process 标注    |

## 标注状态

- Labels: 43/43 ✅
- Processes: 36/36 ✅
- Total: 179/179 (100%)

## Neovim 插件

配套 Neovim 插件：[feature-nav.nvim](https://github.com/your-github/feature-nav.nvim)
