---
description: "Update non-live tvbox-lines urls from the 空壳 interface list"
name: "Update TVBox URLs"
argument-hint: "Optional: source website URL or target JSON path"
agent: "agent"
---

Please update [tvbox-lines.json](../../tvbox-lines.json) in the current workspace.

Goal:
Use the interfaces listed in the “空壳 接口（点击复制）” section on https://www.xn--sss604efuw.com/ to update all non-live entries inside the `urls` array.

Requirements:
1. Open https://www.xn--sss604efuw.com/.
2. Find the “空壳 接口（点击复制）” section.
3. Read or click-copy each interface in that section to get its display name and actual URL.
4. Only update the `urls` array in [tvbox-lines.json](../../tvbox-lines.json).
5. Any entry whose `name` contains “直播” or starts with “直播：” must be preserved exactly as-is.
6. Replace or synchronize all non-live entries in the `urls` array with the interfaces from the webpage.
7. Keep the existing live entries in their original relative order.
8. Each new or updated non-live entry must use this format:
   ```json
   {
       "url": "...",
       "name": "..."
   }
   ```
9. If the webpage contains duplicate interfaces, deduplicate by URL and keep the first name found.
10. Do not modify `lives` or `rules` unless a JSON syntax error must be fixed.
11. The final file must be valid JSON with no trailing commas.
12. After editing, verify that [tvbox-lines.json](../../tvbox-lines.json) can be parsed as JSON.
13. If any updated or existing URL contains `raw.githubusercontent.com`, `ghfast`, `gh-proxy`, `ghproxy`, `gitmirror`, or another GitHub proxy, run [scripts/repair-github-proxies.ps1](../../scripts/repair-github-proxies.ps1) before the final validation:
    - Use PowerShell from the workspace root.
    - Run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; ./scripts/repair-github-proxies.ps1 -Path ./tvbox-lines.json -TimeoutSeconds 10 -Apply`.
    - This script validates GitHub raw/proxy URLs with TVBox-like network requests and replaces failed GitHub proxy URLs with the first reachable proxy candidate.
    - Do not use this script to remove non-GitHub entries or preserved live entries.
14. Run [scripts/validate-tvbox-links.ps1](../../scripts/validate-tvbox-links.ps1) to validate the updated links with TVBox-like network requests:
    - Use PowerShell from the workspace root.
    - Run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; ./scripts/validate-tvbox-links.ps1 -Path ./tvbox-lines.json -TimeoutSeconds 10`.
    - Treat `Ok=True` as reachable at the TVBox request layer.
    - Report any `Ok=False` entries, but do not remove preserved live entries solely because they fail validation.

Modify the file directly. Do not only provide instructions.
