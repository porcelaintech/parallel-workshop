# 更新索引

发布时由 `distribution/scripts/build-release.sh` 生成 `local-service-update.json`，复制到这里并部署。

- `local-service-update.json` 是应用真正拉取的索引；没有它时首页显示“准备中”。
- `local-service-update.example.json` 只是格式示例，不要部署成正式文件。
- Cloudflare Pages 的 `_headers` 已给 `/updates/*` 设置 `no-store`，避免缓存旧版本。
