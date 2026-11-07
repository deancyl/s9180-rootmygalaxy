#!/bin/sh
# sync.sh - 把 docs/wiki/*.md 同步到 GitHub Wiki
#
# 前置条件（只需一次）：在 GitHub 网页上打开 https://github.com/deancyl/s9180-rootmygalaxy/wiki
# 点击 "Create the first page"，随便保存一页（例如标题 Home）——这一步会在服务端初始化
# wiki 仓库（s9180-rootmygalaxy.wiki.git）。未初始化前 push 会返回 "Repository not found"。
#
# 用法（在仓库根目录执行）：
#   sh docs/wiki/sync.sh
#
# 说明：wiki 页面名 = 文件名（去掉 .md）。Home.md 即 Wiki 首页。
set -e
REPO_HTTPS=https://github.com/deancyl/s9180-rootmygalaxy.wiki.git

if [ ! -d docs/wiki ]; then
  echo "ERROR: 请在仓库根目录执行（找不到 docs/wiki）" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> clone wiki repo"
git clone --depth 1 "$REPO_HTTPS" "$TMP" 2>/dev/null || {
  echo "ERROR: wiki 仓库尚不存在。请先在网页创建首个 Wiki 页面后再重试。" >&2
  exit 1
}

echo "==> copy pages"
cp docs/wiki/*.md "$TMP"/

cd "$TMP"
if [ -z "$(git status --porcelain)" ]; then
  echo "==> 无变化，跳过"
  exit 0
fi

git add -A
git -c user.name="deancyl" -c user.email="deancyl@users.noreply.github.com" \
  commit -m "wiki: sync from docs/wiki ($(date '+%Y-%m-%d'))"
git push
echo "==> 完成：https://github.com/deancyl/s9180-rootmygalaxy/wiki"
