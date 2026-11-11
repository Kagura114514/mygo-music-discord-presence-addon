# 第三方声明

本文件记录本插件分发包中包含或运行时使用的第三方内容。商标、作品及服务仍归各自权利人所有；本插件不代表或隶属于这些项目或公司。

## MyGo Music 图标

- 文件：`mygo-music-icon.png`
- 来源：[egoist/mygo-music `resources/icon.png`](https://github.com/egoist/mygo-music/blob/main/resources/icon.png)
- 上游项目许可证：仓库根目录标注 GNU AGPL-3.0；本分发包附有 `LICENSE`。如果该图标另有单独许可或权利声明，应以权利人的声明为准。
- 本插件仅将该图标用于标识 MyGo Music 播放状态，不主张拥有该图标，也不暗示得到 MyGo Music 作者背书。

## 网易云音乐资料

运行时，插件会向网易云音乐公开搜索接口查询歌曲元数据，以尝试获取专辑封面 URL；不包含网易云客户端代码，不读取或发送网易云账号 Cookie，也不打包歌曲音频或专辑图片。网易云音乐名称、曲目信息和封面内容的权利归其各自权利人所有。接口是否允许第三方插件使用，需遵守网易云音乐当前适用的服务条款；本项目不声称获得官方授权。

## Discord Rich Presence

插件通过用户电脑上的 Discord 桌面客户端本地 RPC 设置 Rich Presence，并引用公开的图片 URL。Discord 及其商标归 Discord Inc. 所有。本项目不包含 Discord SDK、Bot Token 或 Client Secret，也不代表 Discord 官方。
