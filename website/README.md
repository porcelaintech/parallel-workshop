# 部署到 Cloudflare Pages

这是智囊的纯静态官网：没有后端、没有数据库、不接收用户提问或登录态。

## 目录

```text
website/
  index.html                 首页（macOS/Windows 两个独立下载按钮，读取 updates/local-service-update.json）
  download/macos/index.html  稳定入口 /download/macos/ → 对应 macOS Release 资产
  download/windows/index.html 稳定入口 /download/windows/ → 对应 Windows Release 资产
  docs/index.html            安装、使用、数据、故障排查
  privacy.html               隐私说明
  changelog.html             更新日志
  updates/                   更新索引（发布时由 CI/脚本生成）
  _headers                   Cloudflare Pages 响应头（更新索引不缓存）
  _redirects                 /download 等短链
  CNAME                      GitHub Pages 备用的自定义域名
```

## Cloudflare Pages（推荐）

1. Cloudflare Dashboard → Workers & Pages → Create → Pages → Connect to Git。
2. 选择 `porcelaintech/parallel-workshop`，生产分支 `main`。
3. Build command 留空；Build output directory 填 `website`；Framework preset 选 `None`。
4. 部署完成后，在 Pages 项目 → Custom domains 添加 `braintrust.chat` 和 `www.braintrust.chat`。
5. DNS：如果域名的 NS 还在阿里云，推荐把 NS 改到 Cloudflare（Cloudflare 会接管 `braintrust.chat` 的解析，Pages 自定义域名可自动创建 CNAME/Flatten）。
   - 如果不想改 NS：在阿里云 DNS 添加 `www` CNAME 到 `<project>.pages.dev`；apex（`braintrust.chat`）用 Cloudflare 的 CNAME Flattening 或按 Pages 提示添加记录。不同 DNS 商对 apex CNAME 支持不同，改 NS 最省事。
6. Cloudflare 会自动签发 HTTPS 证书。等 `braintrust.chat` 的注册局审核/实名通过后再操作 DNS。

`_headers` 会让 `/updates/*` 使用 `Cache-Control: no-store`，避免用户拿到旧版本索引。`_redirects` 提供 `/download`、`/release` 等短链。

## 更新索引

发布时生成 `local-service-update.json`（见 `distribution/scripts/build-release.sh`），放到：

```text
website/updates/local-service-update.json
```

然后重新部署。不要在 Release 发布前提交一个指向不存在资产的 manifest；首页会显示“准备中”，不会给用户坏链接。

索引格式：

```json
{
  "version": "0.6.0",
  "publishedAt": "2026-10-25T00:00:00Z",
  "notes": "智囊本地服务工作台 v0.6.0",
  "artifacts": {
    "darwin-universal": { "url": "https://github.com/.../Braintrust-local-service-macos-0.6.0.zip", "sha256": "..." },
    "win32-x64": { "url": "https://github.com/.../Braintrust-local-service-windows-0.6.0.zip", "sha256": "..." }
  }
}
```

## GitHub Pages（备选）

如果不想用 Cloudflare：

1. 仓库 Settings → Pages → Source 选 `Deploy from a branch`，分支 `main`，目录 `/website`。
2. Custom domain 填 `braintrust.chat`；仓库里的 `CNAME` 已准备好。
3. 在阿里云 DNS 添加 GitHub Pages 的 A 记录（apex）和 `www` CNAME；开启 Enforce HTTPS。
4. 注意 GitHub Pages 不支持自定义 `_headers`，更新索引可能被 CDN 缓存几分钟；下载/更新体验不如 Cloudflare Pages。

## 本地预览

```sh
cd website
python3 -m http.server 48080
# http://127.0.0.1:48080
```

首页的下载按钮会请求 `updates/local-service-update.json`；没有该文件时显示“0.6.0 正在准备中”，这是预期状态。
