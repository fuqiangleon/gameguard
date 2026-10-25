# GameGuard

远程设置孩子 Mac 上 Minecraft / Roblox 的游戏时间。

- **家长控制台**：`index.html`，部署在 GitHub Pages，手机打开即可设置。配置保存在一个 Secret Gist 里。
- **Mac 端**：`mac/` 目录。在孩子的 Mac 上用管理员账户运行
  `sudo ./install.sh "https://gist.githubusercontent.com/<用户名>/<gist id>/raw/gameguard.txt"`
  每分钟检查一次，每 5 分钟读取一次 Gist 配置。

网页里不包含任何密钥：Gist 地址和 GitHub 令牌只保存在家长自己设备的浏览器里。
令牌请使用 Fine-grained token，只授予 **Gists: Read and write** 权限。
