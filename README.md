# feishu.nvim

中文 | [English](README_en.md)

![feishu.nvim cover](assets/ascii-art-text.png)

> ⚠️AIGC警告：本项目的代码几乎完全由 gpt-5.4 生成，可能存在潜在的bug，虽然现在可以正常运行:)

一个基于 Neovim 的飞书前端，使用 `feishu-cli` 作为后端。

## 特性

- 在 Neovim 里浏览飞书云文档、知识库、云盘、搜索结果和最近打开内容。
- 用通用的 bitable 视图读写多维表格，支持分组、picker 和链接跳转。
- 把 `docx` / 可导出的 wiki 文档打开为 Markdown buffer，并在 `:w` 后异步同步回飞书。
- 浏览聊天、预览历史消息，并在独立 compose buffer 里发送消息。
- 为 `sheet`、普通文件和暂未原生支持的资源提供 preview / metadata / 下载 fallback。
- 所有后端能力由 [`chijw/feishu-cli`](https://github.com/chijw/feishu-cli) 提供，插件本身不维护单独的飞书 API 客户端。

## 依赖

- Neovim `0.10+`
  - 插件依赖 Lua API、floating window、`vim.system()` 等现代接口
- `feishu-cli`
  - 推荐使用 [`chijw/feishu-cli`](https://github.com/chijw/feishu-cli)
  - 二进制名仍然是 `feishu-cli`
  - 必须能在 `PATH` 里找到，或者在 `setup()` 里通过 `external_cmd` 指定绝对路径
- 一个已配置好的飞书开放平台应用
  - 需要 `App ID` 和 `App Secret`
  - 需要在应用里配置 OAuth 重定向地址

## 先配置 backend：feishu-cli

登录和 token 管理由 `feishu-cli` 负责。

### 1. 安装 feishu-cli

推荐直接安装 `chijw/feishu-cli` 的 release 版本。系统里能执行 `feishu-cli` 即可。

已安装的话先确认：

```bash
feishu-cli version
```

### 2. 配置 `config.yaml`

可以用环境变量，也可以用配置文件。日常使用更推荐配置文件。

先初始化：

```bash
feishu-cli config init
```

然后编辑 `~/.feishu-cli/config.yaml`：

```yaml
app_id: "cli_xxx"
app_secret: "xxx"
base_url: "https://open.feishu.cn"
owner_email: ""
transfer_ownership: false
debug: false

export:
  download_images: true
  assets_dir: "./assets"

import:
  upload_images: true
```

至少要把 `app_id` 和 `app_secret` 填好。

### 3. 配置飞书开放平台重定向 URL

在飞书开放平台里给你的应用添加 OAuth 重定向 URL。这个地址必须和你之后登录时用的端口一致。

例如：

```text
http://127.0.0.1:14530/callback
```

也可以使用其他端口，只要前后保持一致。

### 4. 登录拿 User Token

```bash
feishu-cli auth login --port 14530
```

如果 Neovim 跑在远程机器上、浏览器开在本地，可以改用手动模式：

```bash
feishu-cli auth login --manual --port 14530
```

完成后建议检查一下：

```bash
feishu-cli auth status -o json
feishu-cli auth token -o json
```

说明：

- `auth login` 默认会请求 `feishu-cli` 的推荐 scope 集，并自动补 `offline_access`
- 一般不要自己覆盖 scope，除非你明确知道缺了什么
- `:Feishu login` 会在浮动终端里执行 `feishu-cli auth login`

### 5. 推荐的用户权限范围

如果你希望插件里的 `云文档` / `消息` / `多维表格` 都能正常工作，User OAuth 至少应覆盖这类能力：

- 文档搜索：`search:docs:read`
- 知识库浏览：`wiki:space:retrieve` 或 `wiki:wiki:readonly`
- 文档导出/编辑：`docx:document`
- 多维表格：`bitable:app`
- IM：`im:*`
- 自动刷新登录态：`offline_access`

如果你直接使用 `feishu-cli auth login` 默认推荐 scope，通常不需要自己逐个手填。

## 安装插件

这个插件没有编译步骤。把仓库加入 runtimepath，并保证 `feishu-cli` 可用即可。

### `lazy.nvim` / LazyVim

```lua
{
  "chijw/feishu.nvim",
  config = function()
    require("feishu").setup({
      workspace = vim.fn.getcwd(),
      default_bitable_url = nil,
      auth = {
        redirect_port = 14530,
      },
    })
  end,
}
```

### Neovim 原生 `packages`

```bash
git clone git@github.com:chijw/feishu.nvim.git \
  ~/.local/share/nvim/site/pack/feishu/start/feishu.nvim
```

然后在你的配置里：

```lua
require("feishu").setup({})
```

### `vim-plug`（仅限 Neovim）

```vim
Plug 'chijw/feishu.nvim'
```

```lua
require("feishu").setup({})
```

`feishu.nvim` 是 Neovim-only 插件，不支持传统 Vim。

## 配置

最小配置：

```lua
require("feishu").setup({
  workspace = vim.fn.getcwd(),
  auth = {
    redirect_port = 14530,
  },
})
```

一个更完整的例子：

```lua
require("feishu").setup({
  workspace = "/path/to/your/workspace",
  tenant_host = "xcnpgx5jojlc.feishu.cn",
  default_bitable_url = "https://xxx.feishu.cn/base/xxxx?table=tblxxx&view=vewxxx",

  auth = {
    redirect_port = 14530,
    login_scopes = nil,
  },

  keymaps = {
    browser = "<leader>vf",
    dashboard = "",
    tasks = "",
    chats = "",
  },

  ui = {
    preview_width = 0.42,
    form_height = 0.40,
    compose_height = 0.32,
  },

  external_cmd = { "feishu-cli" },
  -- external_cmd = { "/absolute/path/to/feishu-cli" },
})
```

### 可用配置项

- `workspace`
  - 工作区根目录
  - 插件会在这里查找 `workspace.json`
- `tenant_host`
  - 飞书域名，部分链接解析会用到
- `default_bitable_url`
  - 默认打开的多维表格 URL
- `auth.redirect_port`
  - `:Feishu login` 默认使用的 OAuth 回调端口
- `auth.login_scopes`
  - 可选，自定义登录 scope；一般建议留空，直接用 `feishu-cli` 默认推荐值
- `keymaps.browser`
  - 默认是 `<leader>vf`
- `ui.preview_width`
  - 右侧 preview 宽度比例
- `ui.form_height`
  - 多维表格记录编辑窗口高度比例
- `ui.compose_height`
  - 消息编辑窗口高度比例
- `external_cmd`
  - 外部 backend 命令，默认是 `{ "feishu-cli" }`
- `cache_dir`
  - 可选，自定义本地缓存目录

### `workspace.json`

如果你不想把某些 workspace 相关配置写死在全局 `init.lua` 里，也可以在项目目录放一个 `workspace.json`：

```json
{
  "default_bitable_url": "https://xxx.feishu.cn/base/xxxx?table=tblxxx&view=vewxxx",
  "tenant_host": "xcnpgx5jojlc.feishu.cn",
  "auth": {
    "redirect_port": 14530
  }
}
```

插件会自动读取这些默认值。

## 命令

创建命令后，主入口是 `:Feishu`。

- `:Feishu`
- `:Feishu browse`
  - 打开根浏览页
- `:Feishu dashboard`
- `:Feishu auth`
  - 打开登录状态页
- `:Feishu login`
  - 打开一个 floating terminal，执行 `feishu-cli auth login --manual`
- `:Feishu login --port 14530`
  - 给登录过程额外透传参数
- `:Feishu bitable`
- `:Feishu tasks`
  - 兼容别名，打开的仍然是 bitable 视图
- `:Feishu chats`

默认快捷键：

- `<leader>vf`
  - 打开飞书根浏览页
- `<leader>vh`
  - 在当前 Feishu buffer 里打开快捷键帮助浮窗

## 使用方式

### 云文档

`<leader>vf` 进入根页面后，`Enter` 或 `l` 可以继续进入：

- `云文档`
- `消息`

在 `云文档` 里：

- 进入知识库、云盘、最近打开和搜索结果
- 直接打开 `docx` / `wiki` / `sheet` / `bitable`
- 在当前容器里新建文档
- 输入飞书链接后直接解析并打开资源

### 多维表格

多维表格视图按 schema 渲染，不依赖固定字段名。

支持的操作：

- 动态列渲染
- `h / l` 横向滚动
- `J / K` 快速移动
- `<S-Tab>` 切换同一个 base 内的 table
- `gr` 选择分组字段
- `a` / `A` 新增记录
- `i` 编辑记录
- `d` 删除记录
- `gd` / `o` 打开当前记录里的链接

记录编辑 buffer：

- `Enter` / `i` / `a` / `A` / `I` 进入当前字段编辑
- 单选、多选、负责人、关联记录等字段会弹 picker
- `c` 搜索并引用已有云文档
- `gd` / `o` 打开当前字段里的第一个 hyperlink
- `:w` 保存当前记录

### 文档

支持本地缓存的文档会以独立 Markdown buffer 打开。

可用操作：

- `:w` 保存后异步同步回飞书
- `gR` 重新导出远端内容到本地缓存
- `gS` 手动触发一次同步
- `gx` 打开远端页面

### 消息

消息页支持：

- chat 列表浏览
- 历史消息预览
- `i` 打开发送窗口
- `:w` 发送消息
- `s` / `S` 做本地筛选

## 资源支持情况

### 原生支持较好

- `bitable`
  - 读写、删除、分组、表单 picker、文档引用、hyperlink 跳转
- `docx` / 可解析 wiki 文档
  - 本地 Markdown 缓存
  - `:w` 异步回写
- `chat`
  - 浏览、预览、发送
- `sheet`
  - 只读预览

### 以 fallback 为主的资源

- `slides`
- `mindnote`
- 普通上传文件
- 其他没有专门原生 buffer 的资源

fallback 方式：

- 能导出为 Markdown 的，优先导成本地缓存
- 能预览的，优先开一个 metadata / preview buffer
- 普通文件可下载到本地缓存
- 实在不适合本地处理的，保留 `gx` 直接跳官方页面

## 常见问题

### 1. `:Feishu` 能打开，但 `云文档` 里是空的

通常是 scope 不够，不是插件崩了。优先检查：

```bash
feishu-cli auth status -o json
```

重点看这些 scope：

- `search:docs:read`
- `wiki:space:retrieve` 或 `wiki:wiki:readonly`
- `docx:document`

缺什么就重新登录。

### 2. `消息` 页面打不开或读不到聊天记录

先看 OAuth token 里是否真的有 `im:*` 相关用户权限。很多“看起来授权了”的情况，最后实际 token scope 并不完整。

### 3. `:Feishu login` 报重定向 URL 错误

说明飞书开放平台里配置的 redirect URL 和你实际使用的端口不一致。比如：

- 平台里写的是 `http://127.0.0.1:14530/callback`
- 你登录时也必须使用 `--port 14530`

### 4. 找不到 `feishu-cli`

如果 backend 不在 `PATH`，就在 `setup()` 里显式指定：

```lua
require("feishu").setup({
  external_cmd = { "/absolute/path/to/feishu-cli" },
})
```

## 设计原则

- 不在 Lua 里重复实现一整套飞书 API 客户端
- 所有交互尽量回归原生 Neovim buffer / window / `:w`
- 避免 workspace-specific hardcode
- 优先做“可维护的通用能力”，再考虑特殊工作流

## 当前 backend 约定

这个插件当前按 [`chijw/feishu-cli`](https://github.com/chijw/feishu-cli) 的命令与 JSON 输出进行开发和验证。

如果你换成别的 `feishu-cli` 变体，请至少保证这些能力存在且输出兼容：

- `auth login`
- `auth status -o json`
- `auth token -o json`
- 文档导出 / 导入
- bitable 表 / 字段 / 记录操作
- chat 列表 / 历史 / 发送
- wiki / drive / search / file metadata 相关命令
