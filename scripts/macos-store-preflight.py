#!/usr/bin/env python3
"""Validate public release parameters only; never inspect accounts or credentials."""
import os
import re
import sys

RULES = {
    "PWB_STORE_BUNDLE_ID": (r"[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+", "注册到发布主体的反向域名 Bundle ID"),
    "PWB_APPLE_TEAM_ID": (r"[A-Z0-9]{10}", "10 位 Apple Developer Team ID"),
    "PWB_APP_VERSION": (r"[0-9]+\.[0-9]+\.[0-9]+", "三段正式版本号"),
    "PWB_BUILD_NUMBER": (r"[1-9][0-9]*", "递增的正整数构建号"),
    "PWB_APP_STORE_ID": (r"[1-9][0-9]*", "App Store Connect 应用记录的数字 Apple ID"),
    "PWB_COPYRIGHT": (r"\S(?:.*\S)?", "实际权利人的版权声明"),
}

def errors(environment):
    result = []
    for key, (pattern, description) in RULES.items():
        if not re.fullmatch(pattern, environment.get(key, "")):
            result.append(f"{key}: 缺少或无效；需要{description}。")
    bundle_id = environment.get("PWB_STORE_BUNDLE_ID", "").lower()
    if bundle_id.startswith(("local.", "example.", "com.example.", "org.example.")) or "placeholder" in bundle_id:
        result.append("PWB_STORE_BUNDLE_ID: 正式签名不接受本地或示例占位标识。")
    return result

if __name__ == "__main__":
    problems = errors(os.environ)
    if problems:
        print("Mac 商店签名前置检查失败：", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        sys.exit(1)
    print("公开发行参数格式检查通过；账户会员、标识归属和可用签名仍由 Xcode/Apple 验证。")
