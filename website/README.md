# braintrust.chat

极简官网：`Braintrust｜智囊`、12 字简介、macOS/Windows 两个直接下载链接、GitHub 仓库。

```text
website/
  index.html     首页（两个下载链接直接指向 OSS 文件，无跳转页）
  styles.css     样式（无卡片、无 logo，直接铺在背景上）
  updates/       应用更新索引（可选）
  _headers       Cloudflare/GitHub Pages 响应头
  _redirects     短链
  CNAME          GitHub Pages 自定义域
```

## 下载文件

安装包托管在阿里云 OSS 香港桶（公开读，HTTPS）：

```text
https://braintrust-downloads-1738978343093082.oss-cn-hongkong.aliyuncs.com/downloads/Braintrust-local-service-macos-0.6.0.zip
https://braintrust-downloads-1738978343093082.oss-cn-hongkong.aliyuncs.com/downloads/Braintrust-local-service-windows-0.6.0.zip
```

GitHub Release 仍保留同一份资产作为备份/溯源。

## 部署

- 当前：GitHub Pages workflow，自定义域 `braintrust.chat`（HTTP 可访问；HTTPS 证书由 GitHub Pages 签发中）。
- 备选：Cloudflare Pages，构建输出目录 `website`；需要 Pages API token。

## 本地预览

```sh
cd website
python3 -m http.server 48080
```
