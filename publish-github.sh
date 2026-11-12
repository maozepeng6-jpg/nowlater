#!/bin/zsh
# 一键把 NowLater 推上 GitHub：
#   1) gh 设备码登录（会显示一个一次性代码，浏览器里粘贴一次）
#   2) 创建公开仓库 nowlater 并推送本目录
#   3) 打一个 v1.0.10 的 Release，附带打包好的 app
#
# 用法：cd NowLater && ./publish-github.sh
set -e
cd "$(dirname "$0")"

GH="$HOME/.local/bin/gh"
if [[ ! -x "$GH" ]]; then
  echo "gh 没装。先跑："
  echo "  curl -L -o /tmp/gh.zip https://gh-proxy.com/https://github.com/cli/cli/releases/download/v2.103.3/gh_2.103.3_macOS_arm64.zip"
  echo "  unzip -oq /tmp/gh.zip -d /tmp && mkdir -p ~/.local/bin && cp /tmp/gh_2.103.3_macOS_arm64/bin/gh ~/.local/bin/gh"
  exit 1
fi

if ! "$GH" auth status >/dev/null 2>&1; then
  "$GH" auth login --hostname github.com --git-protocol https --web --skip-ssh-key
fi

# 让 git push 能用 gh 的 token（否则会弹「输入用户名」）
"$GH" auth setup-git >/dev/null 2>&1 || true

"$GH" repo create nowlater --public --source=. --remote=origin --push \
  --description "藏在 Mac 刘海里的极简待办：现在 / 稍后 · 每日汇总 · 跨天承接（A minimal todo living in the MacBook notch）"

./build.sh
mkdir -p dist
cd build && ditto -c -k --sequesterRsrc --keepParent NowLater.app ../dist/NowLater-1.0.10.zip && cd ..
"$GH" release create v1.0.10 dist/NowLater-1.0.10.zip \
  --title "NowLater v1.0.10" \
  --notes "首个公开版本。下载 zip 解压后拖入「应用程序」即可。Ad-hoc 签名，首次打开若被 Gatekeeper 拦：系统设置 → 隐私与安全性 → 仍要打开。"

echo "完成。"
