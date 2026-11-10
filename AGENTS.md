# UI设计规范

### 文案减法：让状态和控件承担说明，帮助按需出现

页面自解释；只有用户无法从界面推断时提供帮助，并按需披露。

`控件名称 → 当前状态 → 操作结果`

设计原则：

1. Self-explanatory UI: 自解释界面
2. Progressive disclosure: 渐进式披露
3. Recognition over recall: 让用户识别，而不是记忆规则
4. Aesthetic and minimalist design: 审美且极简的界面
5. Content design / UX writing: 内容即交互的一部分

参考范例

- Apple HIG 要求“清晰、直接、简洁”，并明确说：如果需要大量文字解释一个控件，应重新简化界面；帮助提示也应短而按需出现。Apple Design Principles、Offering Help
- Material 的 Tooltip 要求短、临时、不要重复界面上已经可见的文字。Material Tooltips
- GitHub Primer 建议控件标签尽量简洁，只有需要额外上下文时才添加 caption。Primer Forms
- Microsoft 建议谨慎使用补充说明，把只对部分用户有用的信息放进 InfoTip，并且不要重复主界面已经表达的内容。Visual Studio UI Text
- Atlassian 也强调清晰、简洁；频繁出现的成功提示应更短，并避免重复标题内容。Atlassian Success Messages

视觉简化不等于隐藏语义，应该保留文字的情况：

- 有用户无法推断的权限、范围、风险或不可逆后果；
- 错误、失败和恢复方式；
- 新概念、陌生术语或不明显的控件；
- 空状态需要告诉用户下一步；
- 键盘焦点、无障碍名称和状态信息，仍须通过可访问的控件语义与辅助技术可获得。

# 产品参考项目

- https://github.com/wxtsky/CodeIsland
- https://github.com/Louis-CFM/coucou
- https://github.com/sk-ruban/notchi
