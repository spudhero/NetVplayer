# NetVplayer 项目 TMDB 凭据

TMDB API 对非商业用途免费，要求在应用内注明来源。商业用途需要另行授权，见[官方 FAQ](https://developer.themoviedb.org/docs/faq)。NetVplayer 的关于页面已有官方标识和声明。

## 申请

使用项目负责人自己的 TMDB 账号登录[API 设置](https://www.themoviedb.org/settings/api)，选择创建。申请需要确认用途并接受 [API 使用条款](https://www.themoviedb.org/api-terms-of-use)，账号负责人应阅读并确认。

申请资料：

| 字段 | 内容 |
| --- | --- |
| 应用名称 | `NetVplayer` |
| 类型 | macOS 桌面应用（选择页面提供的对应项） |
| 网站 | `https://spudhero.github.io/NetVplayer/` |
| 项目源码 | `https://github.com/spudhero/NetVplayer` |
| 用途 | 免费、非商业用途；为用户本地或 NAS 视频匹配电影、电视剧资料。 |

英文用途说明：

> NetVplayer is a free, open-source macOS media player for non-commercial use. It organizes video files from users' local folders and NAS shares. The application uses the TMDB API to search for matching movies and TV shows and display titles, descriptions, posters, and ratings. TMDB attribution is included in the application's About page. The application is publicly distributed free of charge.

公开分发用途应明确写进申请，不应描述成仅开发者自己使用。联系人信息填写账号负责人的真实资料。

## 配置官方发布

取得项目的 **API Read Access Token** 后，在 `spudhero/NetVplayer` 的 GitHub Settings → Secrets and variables → Actions 添加仓库 Secret：

```text
NETVPLAYER_TMDB_READ_ACCESS_TOKEN
```

值填写完整令牌。也可使用 `NETVPLAYER_TMDB_API_KEY`，但只能配置其中一种；[官方认证文档](https://developer.themoviedb.org/docs/authentication-application)说明两者均支持应用认证。

不要把真实凭据写进源码、文档、截图、聊天或命令行参数。GitHub Secret 在发布工作流中注入环境；本地打包使用同名环境变量。

## 本机开发与打包

`NetVplayer/script/build_and_run.sh` 在没有非空的显式 TMDB 环境变量时，读取 `~/.config/netvplayer/tmdb.env`。配置保存在仓库外，目录权限使用 `0700`、文件权限使用 `0600`；也可通过 `NETVPLAYER_TMDB_CREDENTIAL_FILE` 指定其他本地文件。

文件只填写一种凭据，格式为一行 `NETVPLAYER_TMDB_READ_ACCESS_TOKEN=完整项目令牌` 或 `NETVPLAYER_TMDB_API_KEY=完整项目密钥`。不要加 `export`、引号或 shell 命令；脚本只读取这两个允许的赋值，不执行文件内容。显式设置的非空环境变量优先，两种凭据同时存在仍会被打包检查拒绝。

使用规范脚本打包或安装时自动注入 `Contents/Resources/TMDB.json`；单独运行 `swift build` 不会完成应用资源注入。更换凭据后需重新打包，再执行下面的安装包检查。GitHub Secret 无法读回，不把“CI 已配置”当作本机已经注入的证据。

应用客户端凭据会随安装包分发，并非不可提取的服务器秘密。使用 NetVplayer 项目专用凭据；其他应用的密钥或用户个人覆盖凭据不能替代项目默认值。

## 发布检查

发布工作流先执行：

```bash
python3 script/package_tmdb_credentials.py --validate-only --require --verify-online
```

该检查实际读取中文电影和电视剧搜索、详情、评分与海报路径。缺失、认证失败、网络不可达或资料不完整都会停止发布，日志不输出凭据或响应正文。

公开打包将凭据写入 `Contents/Resources/TMDB.json`，随后对 ZIP 解压出的应用再次核对：

```bash
python3 script/package_tmdb_credentials.py \
  --app-bundle /absolute/path/to/extracted/NetVplayer.app --audit-only --require
```

未发布开发版的个人覆盖由本机加密凭据库管理，优先于安装包默认值；公开旧版凭据按启动迁移合同恢复，备份不包含凭据。
