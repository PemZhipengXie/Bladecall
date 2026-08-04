# Licensing · 授权说明

Bladecall (剑令) is **source-available**, not open source, because commercial use is
restricted. This document explains exactly what each license covers.

剑令是「**源码公开（source-available）**」而非「开源软件」，因为商业使用受限。
本文说明每一部分的授权边界。

---

## 1. macOS app and reusable core · macOS App 与通用核心

Everything in this repository — the macOS app, the `CompletionBellCore` library, the
shared models, the CLI, tests, and build scripts — is licensed under the
**[PolyForm Noncommercial License 1.0.0](./LICENSE)**.

本仓库内的全部代码（macOS App、`CompletionBellCore` 库、共享模型、CLI、测试、构建脚本）
采用 **[PolyForm Noncommercial License 1.0.0](./LICENSE)**。

**You may**, for any noncommercial purpose · 你可以（用于任何非商业目的）:

- Inspect, build, run, and modify the code · 查看、构建、运行、修改代码
- Use it for personal projects, study, research, and hobby work · 个人项目、学习、研究、业余用途
- Use it inside charities, schools, public research, and government bodies · 慈善 / 教育 / 公共研究 / 政府机构内部使用

**You may not**, without a separate written license · 未取得单独书面授权，你不可以:

- Sell it, or any product or service built on it · 出售本软件，或基于它的任何产品/服务
- Use it in a commercial product or a for-profit company's internal tooling · 用于商业产品，或营利公司的内部工具
- Redistribute it under a different license · 以其他 License 再分发

This is a source-available model, not open source: the Open Source Definition does not
allow a license to prohibit commercial use. For a commercial license, open an issue or
contact the maintainer.

这是 source-available 而非开源模型（开源定义不允许禁止商业使用）。如需商业授权，
请提交 issue 或联系维护者。

## 2. iPhone app and widgets · iPhone App 与 Widget

**Proprietary. Not in this repository.** The iPhone companion and its Widget live in a
separate private repository and are distributed only through the App Store as a paid
product (target **US$0.99** or the regional equivalent). No license to their source is
granted here.

**闭源，不在本仓库。** iPhone 伴侣应用及其 Widget 位于独立私有仓库，仅通过 App Store
作为付费产品分发（目标 **US$0.99** 或对应地区价格）。本仓库不授予其源码的任何授权。

## 3. Names, logo, sounds, and brand assets · 名称、Logo、音效与品牌资产

**All rights reserved.** The names *Bladecall* and *剑令*, the seal logo, the
sword-inspired sound effects, and the visual brand assets are **not** covered by the
software license above. A code license does not grant any right to use the branding.
Public forks and modifications must not present themselves as official *Bladecall* /
*剑令* releases or reuse reserved brand assets without permission.

**保留全部权利。** *Bladecall* / *剑令* 名称、朱印 Logo、剑鸣音效及视觉品牌资产**不**在
上述软件 License 范围内。代码授权不等于品牌使用许可。公开的 fork 与修改版本不得冒充官方
*Bladecall* / *剑令* 发布，也不得擅自复用保留的品牌资产。

## 4. Third-party runtime logos · 第三方运行时 Logo

The runtime icons under `Sources/CompletionBell/Resources/Runtimes/` (Codex, Claude Code,
Craft, NewMax, WorkBuddy, and others) are trademarks of their respective owners, included
only to identify the tools Bladecall integrates with. They are not part of the licensed
work and remain the property of those owners.

`Sources/CompletionBell/Resources/Runtimes/` 下的运行时图标是各自所有者的商标，仅用于标识
剑令所对接的工具，不属于被授权作品，版权归各自所有者。

---

## Public-release checklist · 开源前检查清单

State as of the current preparation pass. **The repository must stay private until every
item is checked.** 仓库在全部勾选前必须保持私有。

1. ✅ Move the iPhone and proprietary Widget source into a separate private repository.
2. ✅ Remove those paths from the public working tree.
3. ⬜ **Remove proprietary mobile source from the public Git history** — deleting only the
   latest files is not sufficient. History still contains `Apps/JianlingiOS/` and
   `Apps/JianlingWidget/`. **This is the current blocker.**
4. ⬜ Audit third-party runtime logos and redistribute only assets that may legally ship.
5. ✅ Add the unmodified PolyForm Noncommercial License 1.0.0 text as the root `LICENSE`
   file, with the copyright notice.
6. ✅ Fold the commercial-license contact and trademark terms into this document
   (sections 1 and 3 above).
7. ✅ Update the public Xcode project so it does not reference private targets.
8. ⬜ Re-run the privacy scan over Markdown, screenshots, fixtures, build artifacts, and
   Git history (part of the history-cleanup step).

> **Summary · 一句话**: free for noncommercial use, ask first for commercial use, and the
> *Bladecall / 剑令* brand stays with the original author.
> 非商业免费，商业先问，*Bladecall / 剑令* 品牌归原作者。

*This is a product-licensing summary, not legal advice. Have a lawyer review the final
source split, brand terms, and App Store agreements before public launch.*
