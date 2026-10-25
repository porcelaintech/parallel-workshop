# braintrust.chat

极简官网：品牌、>20 字以内简介、macOS/Windows 两个下载入口、GitHub 仓库。

```text
website/
  index.html                    首页
  styles.css                    样式
  assets/mark.svg               品牌 mark
  download/macos/index.html     macOS 下载入口 → 更新索引 → GitHub Release
  download/windows/index.html   Windows 下载入口
  updates/                      更新索引（发布时生成）
  _headers / _redirects         Cloudflare Pages 配置
  CNAME                         GitHub Pages 备用
```

## 本地预览

```sh
cd website
python3 -m http.server 48080
# http://127.0.0.1:48080/
```

没有 `updates/local-service-update.json` 时，两个下载页会显示“安装包尚未发布”，这是预期。

## Cloudflare Pages

1. Pages → Connect to Git → `porcelaintech/parallel-workshop`，生产分支 `main`。
2. Build command 留空；Build output directory 填 `website`。
3. Custom domains 添加 `braintrust.chat` / `www.braintrust.chat`。
4. DNS 在阿里云：改 NS 到 Cloudflare（推荐），或按 Pages 提示加 CNAME；apex 用 CNAME Flattening。
5. `_headers` 让 `/updates/*` 不缓存；`_redirects` 提供短链。

## GitHub Pages（备用）

仓库 Settings → Pages → Deploy from branch `main` / `/website`；自定义域名 `braintrust.chat`。`CNAME` 已写好。GitHub Pages 不支持 `_headers`，更新索引可能缓存几分钟。

## 更新索引

发布时把 `build/local-service-release/<version>/artifacts/local-service-update.json` 复制到 `website/updates/local-service-update.json` 并重新部署。格式见 `updates/local-service-update.example.json`。
