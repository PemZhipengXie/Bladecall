import Foundation

struct DailyReportHTMLRenderer {
    let day: Date
    let records: [ActivityRecord]
    let currentSessions: [SessionSnapshot]
    let includeBackground: Bool
    let language: DailyReportLanguage
    let now: Date
    let calendar: Calendar

    private struct ReportRow {
        let tool: ToolKind
        let sessionID: String
        let title: String
        let origin: SessionOrigin
        let segments: [TimelineSegment]

        var sourceCategory: String {
            if origin.isRoutine { return "routine" }
            if origin.isBackground { return "background" }
            return "interactive"
        }
    }

    private var isEnglish: Bool { language == .english }

    func render() -> String {
        let reportRecords = records.filter { includeBackground || $0.origin?.isBackground != true }
        let reportSessions = currentSessions.filter { includeBackground || !$0.isBackground }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let timeline = DailyTimelineBuilder().build(
            for: day,
            records: reportRecords,
            currentSessions: reportSessions,
            now: now,
            calendar: calendar
        )
        let dayRecords = reportRecords.filter { $0.timestamp >= start && $0.timestamp < end }
        let started = dayRecords.filter { $0.kind == .taskStarted }
        let completed = dayRecords.filter { $0.kind == .assistantCompleted }
        let routineCompleted = completed.filter { $0.origin == .scheduled }
        let handled = dayRecords.filter { $0.kind == .handled }
        let pending = pendingTurnIDs(records: reportRecords, before: min(end, now)).count
        let foregroundSeconds = timeline.foreground.reduce(0) { $0 + $1.duration }
        let aiSeconds = timeline.tasks.reduce(0) { $0 + $1.duration }
        let dateText = Self.dayFormatter.string(from: start)
        let nowMinute = max(0, min(1_440, now.timeIntervalSince(start) / 60))
        let rows = makeRows(from: timeline.tasks)

        let toolCounts = Dictionary(grouping: rows, by: \.tool).mapValues(\.count)
        let sourceCounts = Dictionary(grouping: rows, by: \.sourceCategory).mapValues(\.count)
        let sidebar = filterSidebar(
            total: rows.count,
            toolCounts: toolCounts,
            sourceCounts: sourceCounts
        )
        let timelineHTML = timelineGroups(
            timeline: timeline,
            rows: rows,
            start: start,
            nowMinute: nowMinute
        )
        let completionList = completionItems(from: timeline.tasks.filter(\.completed).sorted { $0.end < $1.end })
        let navigation = dateNavigation(for: start, records: reportRecords)
        let backgroundScope = includeBackground
            ? localized("含幕后剑令", "Background included")
            : localized("已隐藏幕后任务", "Background hidden")

        return """
        <!doctype html>
        <html lang="\(isEnglish ? "en" : "zh-CN")">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <meta name="jianling-report-template" content="\(DailyReportGenerator.htmlTemplateVersion)">
          <title>\(localized("剑迹日报", "Bladecall Daily Report")) · \(dateText)</title>
          <style>
          :root{color-scheme:light;--paper:#f8f7f1;--panel:#fcfcf8;--sidebar:#f1f0e9;--ink:#20231f;--muted:#74776f;--faint:#9a9d95;--line:#dedfd8;--line-strong:#c9cbc2;--blue:#347fca;--craft:#8665cf;--claude:#dc6f4b;--codex:#3e7ed8;--newmax:#606663;--workbuddy:#08b98d;--label-width:238px;--timeline-width:1872px;--grid-width:78px;--row-height:36px;--font:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC","Noto Sans",sans-serif}
          *{box-sizing:border-box}html,body{margin:0;min-height:100%;background:var(--paper);color:var(--ink);font:13px var(--font)}button,a,input{font:inherit}.shell{min-height:100vh;display:grid;grid-template-columns:220px minmax(0,1fr)}
          .sidebar{position:sticky;top:0;height:100vh;overflow:auto;background:var(--sidebar);border-right:1px solid var(--line-strong);padding:20px 14px 16px;z-index:20}.brand{display:flex;align-items:center;gap:10px;padding:0 6px 20px}.brand img{width:31px;height:31px;image-rendering:pixelated}.brand strong{display:block;font-family:"Kaiti SC","STKaiti",serif;font-size:21px;letter-spacing:.08em}.brand small{display:block;color:var(--muted);font-size:10px;margin-top:1px}.filter-label{padding:10px 8px 6px;color:var(--faint);font-size:10px;font-weight:700;letter-spacing:.12em;text-transform:uppercase}.filter-nav{display:grid;gap:2px}.filter-item{appearance:none;width:100%;border:0;background:transparent;color:var(--ink);display:grid;grid-template-columns:22px minmax(0,1fr) auto;align-items:center;gap:7px;padding:8px;border-radius:4px;text-align:left;cursor:pointer}.filter-item:hover{background:#e8e7df}.filter-item.active{background:#dedfd7;font-weight:700}.filter-item:disabled{opacity:.45;cursor:default}.filter-item img{width:18px;height:18px;border-radius:4px}.filter-item .glyph{display:grid;place-items:center;width:18px;height:18px;color:var(--muted);font-size:12px}.filter-item .count{color:var(--muted);font-variant-numeric:tabular-nums}.sidebar-note{margin-top:auto;padding:16px 8px 0;border-top:1px solid var(--line);color:var(--muted);font-size:10px;line-height:1.5}.sidebar-inner{min-height:calc(100vh - 36px);display:flex;flex-direction:column}
          .main{min-width:0;padding:20px 22px 22px}.report-top{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;margin-bottom:14px}.report-title h1{margin:0;font-size:21px;font-family:"Kaiti SC","STKaiti",serif;font-weight:700;letter-spacing:.03em}.report-title p{margin:3px 0 0;color:var(--muted);font-size:11px}.date-nav{display:flex;align-items:center;gap:3px}.date-nav a,.date-nav span{display:inline-flex;align-items:center;justify-content:center;min-height:29px;padding:0 9px;border:1px solid var(--line);background:var(--panel);color:var(--ink);text-decoration:none}.date-nav a:hover{border-color:#9ba49a;background:#fff}.date-nav .disabled{color:#b2b4ae;background:transparent}.date-nav .date{min-width:108px;font-variant-numeric:tabular-nums;font-weight:650}.scope{margin-left:6px;color:var(--muted);font-size:10px}
          .metrics{display:grid;grid-template-columns:repeat(4,minmax(110px,1fr));border:1px solid var(--line-strong);background:var(--panel)}.metric{min-height:76px;padding:12px 15px;border:0;border-right:1px solid var(--line);background:transparent;text-align:left;color:var(--ink)}.metric:last-child{border-right:0}.metric b{display:block;font-size:23px;line-height:1.1;font-variant-numeric:tabular-nums;font-weight:680}.metric span{display:block;margin-top:7px;color:var(--muted);font-size:10px;letter-spacing:.03em}.metric.action{cursor:pointer}.metric.action:hover{background:#f2f5f1}.metric.action b{color:#197d72}.secondary{display:flex;gap:18px;align-items:center;min-height:34px;padding:0 12px;border:1px solid var(--line);border-top:0;background:#f5f5ef;color:var(--muted);font-size:11px}.secondary b{color:var(--ink);font-variant-numeric:tabular-nums}.secondary .visible-count{margin-left:auto}
          .workspace{margin-top:14px;border:1px solid var(--line-strong);background:var(--panel);min-width:0}.workspace-head{display:flex;align-items:center;justify-content:space-between;gap:14px;min-height:48px;padding:8px 12px;border-bottom:1px solid var(--line)}.workspace-head h2{font-size:13px;margin:0}.workspace-head p{font-size:10px;color:var(--muted);margin:2px 0 0}.scale-controls{display:flex;align-items:center;gap:4px;flex-wrap:wrap;justify-content:flex-end}.scale-controls button{appearance:none;border:1px solid var(--line);background:#fafaf7;color:var(--ink);padding:5px 8px;min-height:27px;cursor:pointer}.scale-controls button:hover,.scale-controls button.active{border-color:#7296ba;color:#2369a9;background:#f0f5f9}.scale-controls input{width:112px;accent-color:var(--blue)}#scale-value{min-width:66px;text-align:right;color:var(--muted);font-size:10px;font-variant-numeric:tabular-nums}
          .legend{display:flex;gap:13px;align-items:center;padding:7px 12px;border-bottom:1px solid var(--line);color:var(--muted);font-size:10px;overflow-x:auto;white-space:nowrap}.key:before{content:"";display:inline-block;width:12px;height:7px;margin-right:5px;vertical-align:1px;background:var(--ink)}.key.craft:before{background:var(--craft)}.key.claude:before{background:var(--claude)}.key.codex:before{background:var(--codex)}.key.newmax:before{background:var(--newmax)}.key.workbuddy:before{background:var(--workbuddy)}.key.routine:before{background:repeating-linear-gradient(135deg,#9879be 0 3px,#cbbbdc 3px 5px)}.key.background:before{background:#969a98}.key.reply:before{width:7px;height:7px;border-radius:50%;background:#138a78}
          .gantt-scroll{overflow:auto;max-height:calc(100vh - 250px);min-height:330px;scrollbar-gutter:stable}.gantt-content{min-width:calc(var(--label-width) + var(--timeline-width));background:var(--panel)}.ruler-row,.density-row,.tool-heading-row,.gantt-row{display:flex;min-width:max-content}.ruler-row{position:sticky;top:0;z-index:14;height:34px;border-bottom:1px solid var(--line-strong);background:var(--panel)}.ruler-label,.row-label,.density-label,.tool-label{position:sticky;left:0;z-index:8;flex:0 0 var(--label-width);width:var(--label-width);background:var(--panel);border-right:1px solid var(--line-strong)}.ruler-label{display:flex;align-items:center;padding:0 10px;font-size:10px;color:var(--muted);z-index:16}.ruler{position:relative;flex:0 0 var(--timeline-width);width:var(--timeline-width);height:34px}.tick{position:absolute;bottom:0;height:100%;border-left:1px solid var(--line);padding:7px 0 0 4px;color:var(--muted);font-size:9px;font-variant-numeric:tabular-nums;white-space:nowrap}.tick.major{border-left-color:var(--line-strong);color:var(--ink)}
          .density-row{position:sticky;top:34px;z-index:12;height:36px;border-bottom:1px solid var(--line-strong);background:#f7f7f2}.density-label{display:flex;align-items:center;justify-content:space-between;padding:0 10px;z-index:15;background:#f7f7f2;font-size:10px}.density-label small{color:var(--muted)}.density-canvas{position:relative;flex:0 0 var(--timeline-width);width:var(--timeline-width);height:36px;background-color:#f7f7f2;background-image:linear-gradient(to right,var(--line) 1px,transparent 1px);background-size:var(--grid-width) 100%}.density-bar{position:absolute;bottom:4px;min-width:2px;background:#58a6c7;border-top:1px solid #207ba4;opacity:.85}
          .tool-group{border-bottom:1px solid var(--line-strong)}.tool-heading-row{position:sticky;top:70px;z-index:10;height:29px;background:#eeeee8;border-bottom:1px solid var(--line)}.tool-label{display:flex;align-items:center;gap:7px;padding:0 10px;background:#eeeee8;z-index:11}.tool-label img{width:17px;height:17px;border-radius:4px}.tool-label b{font-size:11px}.tool-label small{margin-left:auto;color:var(--muted);font-size:9px;font-weight:400}.tool-canvas{flex:0 0 var(--timeline-width);width:var(--timeline-width);background:#eeeee8}
          .gantt-row{height:var(--row-height);border-bottom:1px solid #ecece6}.row-label{display:flex;align-items:center;gap:8px;padding:0 10px}.row-label img{width:18px;height:18px;border-radius:4px;flex:0 0 auto}.row-copy{min-width:0;line-height:1.15}.row-copy b{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:10.5px}.row-copy small{display:block;margin-top:2px;color:var(--muted);font-size:8.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.canvas{position:relative;flex:0 0 var(--timeline-width);width:var(--timeline-width);height:var(--row-height);background-color:#fbfbf8;background-image:linear-gradient(to right,var(--line) 1px,transparent 1px);background-size:var(--grid-width) 100%}.foreground-row{height:29px}.foreground-row .canvas{height:29px}.foreground-row .row-label{height:29px;background:#f7f6f2}.foreground-bar{position:absolute;top:10px;height:8px;opacity:.26;border-left:2px solid currentColor}.foreground-bar.tool-craft{color:var(--craft);background:var(--craft)}.foreground-bar.tool-claudeCode{color:var(--claude);background:var(--claude)}.foreground-bar.tool-codex{color:var(--codex);background:var(--codex)}.foreground-bar.tool-newMax{color:var(--newmax);background:var(--newmax)}.foreground-bar.tool-workBuddy{color:var(--workbuddy);background:var(--workbuddy)}
          .task-bar{appearance:none;position:absolute;top:8px;height:19px;min-width:7px;border:0;padding:0;cursor:pointer;color:white;background:var(--tool-color);box-shadow:inset 0 0 0 1px rgba(0,0,0,.08)}.task-bar:hover,.task-bar:focus-visible{filter:brightness(1.08);outline:2px solid #1b5f91;outline-offset:1px;z-index:5}.task-bar.tool-craft{--tool-color:var(--craft)}.task-bar.tool-claudeCode{--tool-color:var(--claude)}.task-bar.tool-codex{--tool-color:var(--codex)}.task-bar.tool-newMax{--tool-color:var(--newmax)}.task-bar.tool-workBuddy{--tool-color:var(--workbuddy)}.task-bar.routine{background-color:color-mix(in srgb,var(--tool-color) 76%,#8c6aaa);background-image:repeating-linear-gradient(135deg,transparent 0 4px,rgba(255,255,255,.28) 4px 6px)}.task-bar.background{background:#969a98;opacity:.64}.task-bar.open{background:transparent;border:1px dashed var(--tool-color);opacity:.9}.reply-dot{position:absolute;right:-3px;top:6px;width:7px;height:7px;border-radius:50%;background:#138a78;border:1px solid #fff;box-shadow:0 0 0 1px #138a78}.now-line{position:absolute;top:0;bottom:0;width:1px;background:#b33b37;opacity:.34;pointer-events:none}.gantt-empty{padding:58px 20px;text-align:center;color:var(--muted)}
          .hover-card{position:fixed;display:none;z-index:90;max-width:300px;padding:8px 10px;background:#252823;color:#fff;border:1px solid #111;font-size:10px;line-height:1.45;pointer-events:none}.hover-card b{display:block;font-size:11px;margin-bottom:2px}.hover-card span{color:#d3d6ce}.drawer-scrim{position:fixed;inset:0;background:rgba(27,30,27,.16);z-index:60;opacity:0;pointer-events:none;transition:opacity .15s ease}.drawer{position:fixed;z-index:70;top:0;right:0;width:min(390px,92vw);height:100vh;background:#fbfbf7;border-left:1px solid var(--line-strong);transform:translateX(101%);transition:transform .18s ease;display:flex;flex-direction:column}.drawer.open{transform:translateX(0)}.drawer-scrim.open{opacity:1;pointer-events:auto}.drawer-head{display:flex;align-items:center;justify-content:space-between;min-height:52px;padding:0 16px;border-bottom:1px solid var(--line)}.drawer-head h2{font-size:14px;margin:0}.drawer-close{appearance:none;border:1px solid var(--line);background:transparent;width:29px;height:29px;cursor:pointer}.drawer-body{padding:14px 16px;overflow:auto}.detail-grid{display:grid;grid-template-columns:92px minmax(0,1fr);gap:0;border-top:1px solid var(--line)}.detail-grid dt,.detail-grid dd{margin:0;padding:9px 0;border-bottom:1px solid var(--line);font-size:11px}.detail-grid dt{color:var(--muted)}.detail-grid dd{font-weight:600;overflow-wrap:anywhere}.completion-list{display:grid;gap:0}.completion-entry{appearance:none;display:grid;grid-template-columns:48px 18px minmax(0,1fr);align-items:center;gap:6px;width:100%;padding:9px 2px;border:0;border-bottom:1px solid var(--line);background:transparent;text-align:left;cursor:pointer}.completion-entry:hover{background:#f0f1eb}.completion-entry time{color:var(--muted);font-variant-numeric:tabular-nums}.completion-entry img{width:16px;height:16px;border-radius:4px}.completion-entry b{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:10.5px}.completion-empty{padding:28px 0;color:var(--muted);text-align:center}.footer{padding:10px 2px 0;color:var(--muted);font-size:10px;line-height:1.55}.footer b{color:var(--ink)}
          [hidden]{display:none!important}
          @media(max-width:900px){.shell{display:block}.sidebar{position:relative;height:auto;overflow:visible;padding:10px 12px;border-right:0;border-bottom:1px solid var(--line-strong)}.sidebar-inner{min-height:0}.brand{padding:0 2px 9px}.brand small,.filter-label,.sidebar-note{display:none}.filter-nav{display:flex;overflow-x:auto;gap:3px;padding-bottom:2px}.filter-item{flex:0 0 auto;width:auto;grid-template-columns:18px auto auto;padding:6px 8px;border:1px solid var(--line)}.main{padding:14px 12px 18px}.gantt-scroll{max-height:calc(100vh - 280px)}}
          @media(max-width:680px){:root{--label-width:184px}.report-top{align-items:flex-start;flex-direction:column}.date-nav{width:100%;overflow-x:auto}.metrics{grid-template-columns:repeat(2,1fr)}.metric:nth-child(2){border-right:0}.metric:nth-child(-n+2){border-bottom:1px solid var(--line)}.secondary{gap:10px;flex-wrap:wrap;padding:7px 9px}.secondary .visible-count{margin-left:0}.workspace-head{align-items:flex-start;flex-direction:column}.scale-controls{justify-content:flex-start}.legend{padding-left:8px}.gantt-scroll{max-height:520px}.drawer{top:auto;bottom:0;width:100%;height:min(72vh,620px);border-left:0;border-top:1px solid var(--line-strong);transform:translateY(101%)}.drawer.open{transform:translateY(0)}}
          </style>
        </head>
        <body>
          <div class="shell">
            <aside class="sidebar" aria-label="\(localized("筛选剑迹", "Filter activity"))"><div class="sidebar-inner">
              <div class="brand"><img src="\(Self.sealLogo)" alt=""><div><strong>\(localized("剑令", "Bladecall"))</strong><small>\(localized("人掌令，AI 行剑", "You command. AI executes."))</small></div></div>
              \(sidebar)
              <div class="sidebar-note"><b>\(localized("本地剑迹", "Local activity only"))</b><br>\(localized("只记录状态与时间，不记录消息正文。", "Tracks status and time, never message content."))</div>
            </div></aside>
            <main class="main">
              <header class="report-top"><div class="report-title"><h1>\(localized("剑迹日报", "Bladecall Daily Report"))</h1><p>\(localized("一天的 AI 出剑、复命与等待，一眼看清。", "A clear view of AI work, completions, and waiting.")) <span class="scope">\(backgroundScope)</span></p></div>\(navigation)</header>
              <section class="metrics" aria-label="\(localized("核心指标", "Key metrics"))">
                <div class="metric"><b>\(formatDuration(foregroundSeconds))</b><span>\(localized("前台时间", "Foreground time"))</span></div>
                <div class="metric"><b>\(started.count)</b><span>\(localized("发起轮次", "Turns started"))</span></div>
                <button class="metric action" type="button" data-open-completions><b>\(completed.count)</b><span>\(localized("AI 完成 · 查看节点", "AI completions · View events"))</span></button>
                <div class="metric"><b>\(pending)</b><span>\(localized("日终待处理", "Pending at day end"))</span></div>
              </section>
              <div class="secondary"><span>\(localized("例行", "Routine")) <b>\(routineCompleted.count)</b></span><span>\(localized("人工处理", "Handled")) <b>\(handled.count)</b></span><span>\(localized("AI 累计运行", "AI runtime")) <b>\(formatDuration(aiSeconds))</b> · \(localized("并行会重叠", "parallel work overlaps"))</span><span class="visible-count"><b id="visible-count">\(rows.count)</b> \(localized("条会话", "conversations"))</span></div>

              <section class="workspace">
                <div class="workspace-head"><div><h2>\(localized("一天横向时间轴", "Daily operations timeline"))</h2><p>\(localized("同一会话固定一行；留白表示没有交互。", "Each conversation stays on one row; gaps mean no interaction."))</p></div><div class="scale-controls" role="group" aria-label="\(localized("调整时间尺度", "Adjust timeline scale"))"><button type="button" data-fit>\(localized("适合窗口", "Fit"))</button><button type="button" data-ppm="1.3">\(localized("1 小时", "1 hour"))</button><button type="button" data-ppm="2.6">\(localized("30 分钟", "30 min"))</button><button type="button" data-ppm="5.2">\(localized("15 分钟", "15 min"))</button><input id="zoom" type="range" min="0.5" max="6" step="0.1" value="1.3" aria-label="\(localized("时间轴缩放", "Timeline zoom"))"><span id="scale-value">\(localized("60 分钟/格", "60 min / grid"))</span></div></div>
                <div class="legend"><span class="key craft">Craft</span><span class="key claude">Claude</span><span class="key codex">Codex</span><span class="key newmax">NewMax</span><span class="key workbuddy">WorkBuddy</span><span class="key routine">\(localized("例行剑令", "Routine run"))</span><span class="key background">\(localized("幕后剑令", "Background run"))</span><span class="key reply">\(localized("复命节点", "Completion event"))</span></div>
                <div class="gantt-scroll" id="gantt-scroll"><div class="gantt-content" id="gantt-content">
                  <div class="ruler-row"><div class="ruler-label">\(localized("会话 / 来源", "Conversation / source"))</div><div class="ruler" id="ruler"></div></div>
                  <div class="density-row"><div class="density-label"><b>\(localized("完成密度", "Completion density"))</b><small>30 min</small></div><div class="density-canvas" id="density-canvas"><i class="now-line" data-start="\(formatNumber(nowMinute))"></i></div></div>
                  \(timelineHTML)
                </div></div>
              </section>
              <p class="footer"><b>\(localized("口径：", "Method:"))</b> \(localized("每个时间块在 AI 完成本轮时结束；之后等你查看或继续回复的时间不算工作时长。前台时间只表示当时哪个 App 在最前面。", "Each block ends when AI completes the turn. Waiting for you to review or reply is not counted as work time. Foreground time only shows which app was frontmost."))</p>
            </main>
          </div>
          <div class="hover-card" id="hover-card" role="tooltip"></div>
          <div class="drawer-scrim" id="drawer-scrim"></div>
          <aside class="drawer" id="detail-drawer" aria-hidden="true" aria-label="\(localized("任务详情", "Task details"))"><div class="drawer-head"><h2 id="drawer-title">\(localized("任务详情", "Task details"))</h2><button type="button" class="drawer-close" id="drawer-close" aria-label="\(localized("关闭", "Close"))">×</button></div><div class="drawer-body" id="drawer-body"></div></aside>
          <template id="completion-template"><div class="completion-list">\(completionList)</div></template>
          <script>
          (() => {
            const scroll = document.getElementById('gantt-scroll');
            const ruler = document.getElementById('ruler');
            const zoom = document.getElementById('zoom');
            const scaleValue = document.getElementById('scale-value');
            const density = document.getElementById('density-canvas');
            const drawer = document.getElementById('detail-drawer');
            const scrim = document.getElementById('drawer-scrim');
            const drawerTitle = document.getElementById('drawer-title');
            const drawerBody = document.getElementById('drawer-body');
            const hoverCard = document.getElementById('hover-card');
            const strings = {
              details: '\(localized("任务详情", "Task details"))', completions: '\(localized("全部复命节点", "All completion events"))',
              app: '\(localized("App", "App"))', task: '\(localized("任务", "Task"))', source: '\(localized("来源", "Source"))',
              start: '\(localized("开始", "Start"))', end: '\(localized("结束", "End"))', duration: '\(localized("运行时长", "Runtime"))', status: '\(localized("完成状态", "Status"))',
              density: '\(localized("次完成", "completions"))'
            };
            const labelWidth = () => parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--label-width')) || 238;
            let ppm = 1.3;
            let activeFilter = {kind:'all', value:'all'};

            function gridStep(value) { return value >= 4 ? 15 : value >= 2 ? 30 : 60; }
            function renderRuler(step) {
              ruler.replaceChildren();
              for (let minute = 0; minute <= 1440; minute += step) {
                const tick = document.createElement('span');
                tick.className = 'tick' + (minute % 60 === 0 ? ' major' : '');
                tick.style.left = `${minute * ppm}px`;
                const hour = Math.floor(minute / 60) % 24;
                const minutes = minute % 60;
                tick.textContent = `${String(hour).padStart(2,'0')}:${String(minutes).padStart(2,'0')}`;
                ruler.appendChild(tick);
              }
            }
            function renderDensity() {
              density.querySelectorAll('.density-bar').forEach(el => el.remove());
              const bins = Array(48).fill(0);
              document.querySelectorAll('.task-row:not([hidden]) .task-bar[data-completed="true"]').forEach(el => {
                const bin = Math.min(47, Math.max(0, Math.floor(Number(el.dataset.endMinute || 0) / 30)));
                bins[bin] += 1;
              });
              const max = Math.max(1, ...bins);
              bins.forEach((count, index) => {
                if (!count) return;
                const bar = document.createElement('i');
                bar.className = 'density-bar';
                bar.style.left = `${index * 30 * ppm + 1}px`;
                bar.style.width = `${Math.max(2, 30 * ppm - 2)}px`;
                bar.style.height = `${Math.max(3, count / max * 27)}px`;
                bar.title = `${count} ${strings.density}`;
                density.appendChild(bar);
              });
            }
            function applyScale(next, preserve = true) {
              const previous = ppm;
              const centerMinute = Math.max(0, (scroll.scrollLeft + scroll.clientWidth / 2 - labelWidth()) / previous);
              ppm = Math.max(.5, Math.min(6, Number(next)));
              const step = gridStep(ppm);
              document.documentElement.style.setProperty('--timeline-width', `${1440 * ppm}px`);
              document.documentElement.style.setProperty('--grid-width', `${step * ppm}px`);
              document.querySelectorAll('[data-start]').forEach(el => {
                el.style.left = `${Number(el.dataset.start || 0) * ppm}px`;
                if (el.dataset.duration) el.style.width = `${Math.max(7, Number(el.dataset.duration) * ppm)}px`;
              });
              renderRuler(step);
              renderDensity();
              zoom.value = String(ppm);
              scaleValue.textContent = `${step} \(localized("分钟/格", "min / grid"))`;
              document.querySelectorAll('[data-ppm]').forEach(button => button.classList.toggle('active', Math.abs(Number(button.dataset.ppm) - ppm) < .08));
              if (preserve) scroll.scrollLeft = Math.max(0, labelWidth() + centerMinute * ppm - scroll.clientWidth / 2);
            }
            function fitDay() {
              applyScale(Math.max(.5, (scroll.clientWidth - labelWidth() - 8) / 1440), false);
              scroll.scrollLeft = 0;
            }
            function filterRows(kind, value) {
              activeFilter = {kind, value};
              let visible = 0;
              document.querySelectorAll('.task-row').forEach(row => {
                const match = kind === 'all' || (kind === 'tool' && row.dataset.tool === value) || (kind === 'source' && row.dataset.sourceCategory === value);
                row.hidden = !match;
                if (match) visible += 1;
              });
              document.querySelectorAll('.tool-group').forEach(group => {
                const rows = [...group.querySelectorAll('.task-row')];
                const foreground = group.querySelector('.foreground-row');
                const showForeground = kind === 'all' || (kind === 'tool' && group.dataset.tool === value);
                if (foreground) foreground.hidden = !showForeground;
                group.hidden = !rows.some(row => !row.hidden) && !(foreground && showForeground);
              });
              document.querySelectorAll('.filter-item').forEach(button => button.classList.toggle('active', button.dataset.filterKind === kind && button.dataset.filterValue === value));
              document.getElementById('visible-count').textContent = String(visible);
              renderDensity();
            }
            function openDrawer(title, html) {
              drawerTitle.textContent = title;
              drawerBody.innerHTML = html;
              drawer.classList.add('open'); scrim.classList.add('open'); drawer.setAttribute('aria-hidden','false');
            }
            function closeDrawer() { drawer.classList.remove('open'); scrim.classList.remove('open'); drawer.setAttribute('aria-hidden','true'); }
            function escapeHTML(value) {
              return String(value ?? '').replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
            }
            function detailHTML(el) {
              const fields = [[strings.app,el.dataset.app],[strings.task,el.dataset.title],[strings.source,el.dataset.sourceLabel],[strings.start,el.dataset.startText],[strings.end,el.dataset.endText],[strings.duration,el.dataset.durationText],[strings.status,el.dataset.status]];
              return `<dl class="detail-grid">${fields.map(([key,value]) => `<dt>${escapeHTML(key)}</dt><dd>${escapeHTML(value || '—')}</dd>`).join('')}</dl>`;
            }
            document.querySelectorAll('.filter-item').forEach(button => button.addEventListener('click', () => filterRows(button.dataset.filterKind, button.dataset.filterValue)));
            document.querySelectorAll('.task-bar,.completion-entry').forEach(el => el.addEventListener('click', () => openDrawer(strings.details, detailHTML(el))));
            document.querySelector('[data-open-completions]').addEventListener('click', () => {
              const fragment = document.getElementById('completion-template').content.cloneNode(true);
              drawerTitle.textContent = strings.completions; drawerBody.replaceChildren(fragment);
              drawerBody.querySelectorAll('.completion-entry').forEach(el => el.addEventListener('click', () => openDrawer(strings.details, detailHTML(el))));
              drawer.classList.add('open'); scrim.classList.add('open'); drawer.setAttribute('aria-hidden','false');
            });
            document.querySelectorAll('.task-bar').forEach(el => {
              el.addEventListener('pointerenter', () => { const title = document.createElement('b'); const summary = document.createElement('span'); title.textContent = el.dataset.title; summary.textContent = `${el.dataset.sourceLabel} · ${el.dataset.startText}–${el.dataset.endText} · ${el.dataset.status}`; hoverCard.replaceChildren(title,summary); hoverCard.style.display = 'block'; });
              el.addEventListener('pointermove', event => { hoverCard.style.left = `${Math.min(innerWidth - 315,event.clientX + 14)}px`; hoverCard.style.top = `${Math.min(innerHeight - 70,event.clientY + 14)}px`; });
              el.addEventListener('pointerleave', () => hoverCard.style.display = 'none');
            });
            document.getElementById('drawer-close').addEventListener('click', closeDrawer); scrim.addEventListener('click', closeDrawer);
            document.addEventListener('keydown', event => { if (event.key === 'Escape') closeDrawer(); });
            zoom.addEventListener('input', event => applyScale(event.target.value));
            document.querySelectorAll('[data-ppm]').forEach(button => button.addEventListener('click', () => applyScale(button.dataset.ppm)));
            document.querySelector('[data-fit]').addEventListener('click', fitDay);
            scroll.addEventListener('wheel', event => { if (!(event.metaKey || event.ctrlKey)) return; event.preventDefault(); applyScale(ppm + (event.deltaY < 0 ? .25 : -.25)); }, {passive:false});
            applyScale(ppm, false);
            filterRows('all','all');
            const starts = [...document.querySelectorAll('.task-bar[data-start]')].map(el => Number(el.dataset.start));
            if (starts.length) scroll.scrollLeft = Math.max(0, labelWidth() + Math.min(...starts) * ppm - 100);
          })();
          </script>
        </body></html>
        """
    }

    private func makeRows(from tasks: [TimelineSegment]) -> [ReportRow] {
        Dictionary(grouping: tasks, by: { "\($0.tool.rawValue):\($0.sessionID)" }).values.compactMap { segments in
            let sorted = segments.sorted { $0.start < $1.start }
            guard let first = sorted.first else { return nil }
            return ReportRow(tool: first.tool, sessionID: first.sessionID, title: first.title, origin: first.origin, segments: sorted)
        }.sorted {
            let lhs = $0.segments.first?.start ?? .distantPast
            let rhs = $1.segments.first?.start ?? .distantPast
            if $0.tool != $1.tool {
                return ToolKind.allCases.firstIndex(of: $0.tool)! < ToolKind.allCases.firstIndex(of: $1.tool)!
            }
            return lhs < rhs
        }
    }

    private func timelineGroups(
        timeline: DailyTimeline,
        rows: [ReportRow],
        start: Date,
        nowMinute: Double
    ) -> String {
        let groups = ToolKind.allCases.compactMap { tool -> String? in
            let toolRows = rows.filter { $0.tool == tool }
            let foreground = timeline.foreground.filter { $0.tool == tool }
            guard !toolRows.isEmpty || !foreground.isEmpty else { return nil }
            let foregroundBars = foreground.map { segment in
                barData(for: segment, dayStart: start, tool: tool)
            }.joined(separator: "\n")
            let foregroundRow = foreground.isEmpty ? "" : """
            <div class="gantt-row foreground-row"><div class="row-label"><img src="\(logo(for: tool))" alt=""><div class="row-copy"><b>\(localized("App 位于前台", "App in foreground"))</b><small>\(formatDuration(foreground.reduce(0) { $0 + $1.duration }))</small></div></div><div class="canvas">\(foregroundBars)<i class="now-line" data-start="\(formatNumber(nowMinute))"></i></div></div>
            """
            let sessionRows = toolRows.map { row in
                let bars = row.segments.map { segment in taskBar(for: segment, dayStart: start) }.joined(separator: "\n")
                return """
                <div class="gantt-row task-row" data-tool="\(row.tool.rawValue)" data-origin="\(row.origin.rawValue)" data-source-category="\(row.sourceCategory)" data-session="\(htmlEscape(row.sessionID))"><div class="row-label"><img src="\(logo(for: row.tool))" alt=""><div class="row-copy"><b>\(htmlEscape(row.title))</b><small>\(sourceText(row.origin)) · \(row.segments.count) \(localized("轮", row.segments.count == 1 ? "turn" : "turns"))</small></div></div><div class="canvas">\(bars)<i class="now-line" data-start="\(formatNumber(nowMinute))"></i></div></div>
                """
            }.joined(separator: "\n")
            return """
            <section class="tool-group" data-tool="\(tool.rawValue)"><div class="tool-heading-row"><div class="tool-label"><img src="\(logo(for: tool))" alt=""><b>\(htmlEscape(tool.displayName))</b><small>\(toolRows.count) \(localized("条", toolRows.count == 1 ? "conversation" : "conversations"))</small></div><div class="tool-canvas"></div></div>\(foregroundRow)\(sessionRows)</section>
            """
        }.joined(separator: "\n")
        return groups.isEmpty
            ? "<div class=\"gantt-empty\">\(localized("今天还没有捕获到任务区间。新一轮对话会自动出现在这里。", "No task intervals captured yet. New turns will appear here automatically."))</div>"
            : groups
    }

    private func taskBar(for segment: TimelineSegment, dayStart: Date) -> String {
        let offset = max(0, segment.start.timeIntervalSince(dayStart) / 60)
        let duration = max(0.1, segment.duration / 60)
        let endMinute = max(0, segment.end.timeIntervalSince(dayStart) / 60)
        let status = segment.completed ? localized("AI 已完成", "AI completed") : localized("行剑中", "Running")
        let classes = [
            "task-bar",
            "tool-\(segment.tool.rawValue)",
            segment.isRoutine ? "routine" : "",
            segment.isBackground ? "background" : "",
            segment.completed ? "" : "open"
        ].filter { !$0.isEmpty }.joined(separator: " ")
        let marker = segment.completed ? "<i class=\"reply-dot\"></i>" : ""
        return """
        <button type="button" class="\(classes)" data-start="\(formatNumber(offset))" data-duration="\(formatNumber(duration))" data-end-minute="\(formatNumber(endMinute))" data-tool="\(segment.tool.rawValue)" data-origin="\(segment.origin.rawValue)" data-completed="\(segment.completed)" data-app="\(htmlEscape(segment.tool.displayName))" data-title="\(htmlEscape(segment.title))" data-source-label="\(htmlEscape(sourceText(segment.origin)))" data-start-text="\(timeText(segment.start))" data-end-text="\(timeText(segment.end))" data-duration-text="\(htmlEscape(formatDuration(segment.duration)))" data-status="\(htmlEscape(status))" aria-label="\(htmlEscape(segment.title)) · \(timeRange(segment.start, segment.end)) · \(htmlEscape(status))">\(marker)</button>
        """
    }

    private func barData(for segment: ForegroundSegment, dayStart: Date, tool: ToolKind) -> String {
        let offset = max(0, segment.start.timeIntervalSince(dayStart) / 60)
        let duration = max(0.1, segment.duration / 60)
        return "<i class=\"foreground-bar tool-\(tool.rawValue)\" data-start=\"\(formatNumber(offset))\" data-duration=\"\(formatNumber(duration))\" title=\"\(localized("App 位于前台", "App in foreground")) · \(timeRange(segment.start, segment.end))\"></i>"
    }

    private func completionItems(from segments: [TimelineSegment]) -> String {
        guard !segments.isEmpty else {
            return "<div class=\"completion-empty\">\(localized("今天还没有捕获到 AI 最终回复。", "No AI completions captured today."))</div>"
        }
        return segments.map { segment in
            let status = localized("AI 已完成", "AI completed")
            return """
            <button type="button" class="completion-entry" data-app="\(htmlEscape(segment.tool.displayName))" data-title="\(htmlEscape(segment.title))" data-source-label="\(htmlEscape(sourceText(segment.origin)))" data-start-text="\(timeText(segment.start))" data-end-text="\(timeText(segment.end))" data-duration-text="\(htmlEscape(formatDuration(segment.duration)))" data-status="\(htmlEscape(status))"><time>\(timeText(segment.end))</time><img src="\(logo(for: segment.tool))" alt=""><b>\(htmlEscape(segment.title))</b></button>
            """
        }.joined(separator: "\n")
    }

    private func filterSidebar(
        total: Int,
        toolCounts: [ToolKind: Int],
        sourceCounts: [String: Int]
    ) -> String {
        func item(kind: String, value: String, title: String, count: Int, icon: String, disabled: Bool = false) -> String {
            "<button type=\"button\" class=\"filter-item\(kind == "all" ? " active" : "")\" data-filter-kind=\"\(kind)\" data-filter-value=\"\(value)\"\(disabled ? " disabled" : "")>\(icon)<span>\(title)</span><span class=\"count\">\(count)</span></button>"
        }
        let all = item(kind: "all", value: "all", title: localized("全部剑迹", "All activity"), count: total, icon: "<span class=\"glyph\">◎</span>")
        let apps = ToolKind.allCases.map { tool in
            item(kind: "tool", value: tool.rawValue, title: tool.displayName, count: toolCounts[tool, default: 0], icon: "<img src=\"\(logo(for: tool))\" alt=\"\">")
        }.joined(separator: "\n")
        let interactive = item(kind: "source", value: "interactive", title: localized("普通对话", "Conversations"), count: sourceCounts["interactive", default: 0], icon: "<span class=\"glyph\">↔</span>")
        let routine = item(kind: "source", value: "routine", title: localized("例行剑令", "Routine runs"), count: sourceCounts["routine", default: 0], icon: "<span class=\"glyph\">◷</span>")
        let backgroundCount = sourceCounts["background", default: 0]
        let background = item(kind: "source", value: "background", title: localized("幕后剑令", "Background runs"), count: backgroundCount, icon: "<span class=\"glyph\">⋯</span>", disabled: backgroundCount == 0)
        return "<div class=\"filter-label\">\(localized("应用", "Apps"))</div><nav class=\"filter-nav\">\(all)\(apps)</nav><div class=\"filter-label\">\(localized("来源", "Source"))</div><nav class=\"filter-nav\">\(interactive)\(routine)\(background)</nav>"
    }

    private func dateNavigation(for start: Date, records: [ActivityRecord]) -> String {
        var dates = Set(records.map { calendar.startOfDay(for: $0.startedAt ?? $0.timestamp) })
        dates.insert(start)
        let sorted = dates.sorted()
        let previous = sorted.last { $0 < start }
        let next = sorted.first { $0 > start }
        let today = calendar.startOfDay(for: now)
        let hasToday = dates.contains(today)
        func control(_ target: Date?, label: String, css: String = "") -> String {
            guard let target else { return "<span class=\"disabled \(css)\">\(label)</span>" }
            return "<a class=\"\(css)\" href=\"\(htmlEscape(reportFilename(for: target)))\">\(label)</a>"
        }
        let todayControl = hasToday ? control(today, label: localized("今天", "Today")) : "<span class=\"disabled\">\(localized("今天", "Today"))</span>"
        return "<nav class=\"date-nav\" aria-label=\"\(localized("日报日期", "Report date"))\">\(control(previous, label: "‹", css: "arrow"))<span class=\"date\">\(Self.dayFormatter.string(from: start))</span>\(control(next, label: "›", css: "arrow"))\(todayControl)</nav>"
    }

    private func reportFilename(for date: Date) -> String {
        let value = Self.dayFormatter.string(from: date)
        return isEnglish ? "\(value)_Bladecall_Daily_Report_EN.html" : "\(value)_剑令日报.html"
    }

    private func pendingTurnIDs(records: [ActivityRecord], before end: Date) -> Set<String> {
        var pending: Set<String> = []
        for record in records.filter({ $0.timestamp < end }).sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let turnID = record.turnID else { continue }
            if record.kind == .assistantCompleted { pending.insert(turnID) }
            if record.kind == .handled { pending.remove(turnID) }
        }
        return pending
    }

    private func sourceText(_ origin: SessionOrigin) -> String {
        switch origin {
        case .interactive: return localized("普通对话", "Conversation")
        case .scheduled: return localized("例行剑令", "Routine run")
        case .subagent: return localized("子 Agent", "Subagent")
        case .externalRuntime: return localized("外部运行", "External runtime")
        case .detached: return localized("宿主不可见", "Detached session")
        }
    }

    private func localized(_ chinese: String, _ english: String) -> String { isEnglish ? english : chinese }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds.rounded() / 60))
        if isEnglish {
            if minutes < 60 { return "\(minutes) min" }
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
        }
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    private func timeRange(_ start: Date, _ end: Date) -> String { "\(timeText(start))–\(timeText(end))" }
    private func timeText(_ date: Date) -> String { Self.timeFormatter.string(from: date) }
    private func formatNumber(_ value: Double) -> String { String(format: "%.1f", value) }
    private func htmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func logo(for tool: ToolKind) -> String {
        switch tool {
        case .craft: return Self.craftLogo
        case .claudeCode: return Self.claudeLogo
        case .codex: return Self.codexLogo
        case .newMax: return Self.newMaxLogo
        case .workBuddy: return Self.workBuddyLogo
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; return formatter
    }()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "HH:mm"; return formatter
    }()

    private static let newMaxLogo = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 40 40'%3E%3Crect x='1' y='1' width='38' height='38' rx='9' fill='%23f4f3ef' stroke='%23deddd8'/%3E%3Cpath d='M10 27V12l10 8 10-8v15' fill='none' stroke='%232a2b2a' stroke-width='4.2' stroke-linecap='round' stroke-linejoin='round'/%3E%3Cpath d='M15 29v-8l10 8v-8' fill='none' stroke='%23828582' stroke-width='4.2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E"
    private static let workBuddyLogo = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 40 40'%3E%3Ccircle cx='20' cy='20' r='20' fill='%2308c99b'/%3E%3Cpath d='M9 15l7 14 4-8 4 8 7-14-5 3-6-9-6 9z' fill='white'/%3E%3C/svg%3E"
    private static let sealLogo = "data:image/svg+xml;base64,PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciCiAgICAgd2lkdGg9IjMyIgogICAgIGhlaWdodD0iMzIiCiAgICAgdmlld0JveD0iMCAwIDMyIDMyIgogICAgIGZpbGw9Im5vbmUiCiAgICAgc2hhcGUtcmVuZGVyaW5nPSJjcmlzcEVkZ2VzIgogICAgIHJvbGU9ImltZyIKICAgICBhcmlhLWxhYmVsbGVkYnk9InRpdGxlIGRlc2MiPgogIDx0aXRsZSBpZD0idGl0bGUiPuWJkeS7pOWDj+e0oOagh+W/lzwvdGl0bGU+CiAgPGRlc2MgaWQ9ImRlc2MiPuWFq+inkuacseegguS7pOeJjOS4reeri+edgOS4gOafhOmHkeeZveiJsuS7pOWJke+8jOixoeW+geWPkeS7pOOAgeWkjeWRveS4juW9kumemOOAgjwvZGVzYz4KCiAgPCEtLSDlhavop5Lku6TniYzvvJrmiYDmnInovazmipjokL3lnKggMnB4IOe9keagvOS4iu+8jOe8qeiHsyAxNnB4IOS7jeS4jeWPkeiZmuOAgiAtLT4KICA8cGF0aCBmaWxsPSIjMjExOTE0IiBkPSJNOCAyaDE2djJoNHY0aDJ2MTZoLTJ2NGgtNHYySDh2LTJINHYtNEgyVjhoMlY0aDRWMloiLz4KICA8cGF0aCBmaWxsPSIjQTYyODJBIiBkPSJNOCA0aDE2djJoMnYyaDJ2MTZoLTJ2MmgtMnYySDh2LTJINnYtMkg0VjhoMlY2aDJWNFoiLz4KICA8cGF0aCBmaWxsPSIjQzYzQTM3IiBkPSJNOCA0aDE2djJoMnYySDhWNkg2VjRoMloiLz4KCiAgPCEtLSDku6TliZHvvJrliZHlsJblkIzml7blg4/jgIzlj5Hlh7rjgI3mjIfku6TlhYnmoIfvvIzlrr3liZHouqvpgb/lhY3lsI/lsLrlr7jkuKLlpLHjgIIgLS0+CiAgPHBhdGggZmlsbD0iI0ZGRjhFOCIgZD0ibTE2IDYgNiA4aC0ydjRoLTJ2MmgtNHYtMmgtMnYtNGgtMmw2LThaIi8+CiAgPHBhdGggZmlsbD0iI0UyQUQ2MiIgZD0iTTggMThoNnYyaDR2LTJoNnY0aC02djRoLTR2LTRIOHYtNFoiLz4KICA8cGF0aCBmaWxsPSIjRkZGOEU4IiBkPSJNMTQgMjZoNHYyaC00di0yWiIvPgo8L3N2Zz4K"
    private static let craftLogo = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAMAAAC7IEhfAAAAY1BMVEVHcEz19fX8/Pz+/v739/f6+vr6+vr////7+/v////29vb+/v7z8/OVcL79/v35+fn8/Pz08/T////19fX39/eTbb2pi8qbeMKkhMfu6vKRarzWyeSXcr/p4vDl3u3b0Oe2ndFHuWo5AAAADXRSTlMAwcHBvUWsBOQriYkrEKHZOgAAARxJREFUOMvV1Nl2gyAUQNFAEY3DZUxL2sTk/7+yiIYxmDy255G1lygCh8P/qW0Gij+yMB2aNnVHLCvhY+I6CZVkF8kWS15N4jB7I6EOQTYeDjsPtI8cPKQPyO6fcWc3kaQeEg/N9yk0XVdIPMQBnqbQZYM4gmxJa5VBvgznEG7GmMv0Bvyx7ze9BxM22Y95Cb/WnkCtNY/g7ezSrj04w7YMGUQF5DFEAcLzqZWDsAMfH8MKqJTi5fLMzI6rHLJywSuw/IUl5MuAsKWbYtbLOM+hUvoVJBtUIt24Gwwbl4JwKXE38VG4uteBcBR6KXaSfTiubA+ycFxbBHUHKLp+xq4qeTfGl89INKw7JomDJmN+7fWUoCxC+/za+9P9AlmFPVLFzyRpAAAAAElFTkSuQmCC"
    private static let claudeLogo = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAMAAAC7IEhfAAAA+VBMVEVHcEwAAADJYT/ZeFjTbUvTcE/XbEjXdVbUakgAAADFXz7MakvaeFjSc1PGcVDbelmNRS3HYD/OZkW2WDnYd1fRaEbceVnadlbScVFbLhtsOyemVDrOY0HabEjaa0faakbZc1LZd1fZdVT//PvZcE3ZbUr++fjYdlbYaETYcU/ibUfge1rZdlb78O3ab0zaclDWb0zhdVL99vPlb0nick7cgWLvxLb88u/ieVb77unjfVvxy77oqZTeh2vXZUD33tf44tzkm4PehWfqsJ712c/55uD01crnpY/suqnilHr66uXgjHDrtaPmoYvbdFPz0MXXakbaelruv7D0buHuAAAAHXRSTlMACsKzubf9lLcEonSqKg1rQbecgrmt9PesHBo1xLFZ/gYAAALNSURBVDjL1ZR7e5owFMZ3K1bbrVu3tesl4RpIVoEUBERAQBAVtWq//4dZ4vZUsPsA2/uEAOf8znvyT86bN/+RPl50zs/ft3R+3rn4eIR96lyNRqOHI40eRledTy3u20j+o75h8L3fl2WDr9G3JtkZyb8TRJLlnSFzuL/fGdlpnO+aWRhs7eJcMQxD8mTFUBhoKEZfvj6c82yoKCyjkDgIl0SRltOC9PvKHz2cHToPFYmHyMw0n6lCC/2Z4bIsKZweHnr/YI6SIknSrjSnHqFzPaY0KSN5Xz788QKeDDk2YUhuBitKfX0heGkQJoQVK8OTJijZXpqtKY2c2qMb0zOqIIikvY5AIldBOJcSU5/TNJWenSD1uKH09NgAH21Ger7pVN5cDZPan+lOuKS/HdugTSRC4lqvi1D16zJ0nFgglFJi248f2iCxiTDZqE6gB46q6xGm8iTP+4QcgRpFgoC3s1DVGaY7RbHJTKeeaE3HD4+ator8+aqYLRipclJVzdSPl0QjbRDlfrQp02yaBXsw9NeJzDpoGhm0HRFEVCOUrE3up0/TLEuraE00rQVamqVplrBNIjUNOVku1n4aOmGCrGbrgWZZGtru5oFTzIPScRy9ksa2ly+IZTUcTwcWE1qkTjVZ6Cu/2uhRlnoYbSGLD04bILIQzs1pjHZ1icrnJJguqmyyZdUItUGmSTzBWlV7dl2MV3qk+NkSInTkCBgI8RbOg3ycmLPxUxmscezzcNPxuwsQYAuvwxiP82CB8bJOn7ANuNzvL+ClCwCEAOBVIUK8CpcY4Dh64iEIoHt5uFwcBPzBEGK/9jDgXxCxcggGh8t1J0AeASIUmWMys9hLhJziYeHuBez2XAhELigCiMciy+9/RBGIbq97mAC39y4U/yro3t82h89NT3Ddn6/lir2b9jjrfv7a+/LuSF96Xz93X0/I7ttX6v4To/sXQFOhRSBTG1cAAAAASUVORK5CYII="
    private static let codexLogo = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAMAAAC7IEhfAAACMVBMVEVHcEwzMzMgICA5OTk5OTksLCxQUFBKSkozMzMfHx88PDw8PDxeXFySkpJWVVZiYmIbGxs3NzdeXl5EREQhICAhISEZGRlKSkpHR0c7OztlZWUuLi4uLi4gICAZGRkoKChXV1f///9aWlpAQEBBQUE1NTV2dnYzMzNycHJSUlKJiYQ/Pz8UFBMxMTEWFhYVFRQbGxoYGRcwMDA0NDQdHBsvLy8sLCwrKyonJyUtLS0lJSV1kfkpKiqTjfkfHx8jIyNvhfdqffhCRfcaGhohIR8SEg9+nPhmefhidfhecvg5N/V/hPd0jvdwifdwgfkoKCgQEAu1o/o0LPUzMjLAuP2tnvo3MfWnmvl0i/hqgvh7l/re5v15lPm7qvksIvfAsvwwJ/YyNkxxfvg9PPR5gvdHTPVNWfZYavfn7v7Azvw3Nziklvi0qPc5M/44QGtebvdRXfeAlfmHh/eImvlKVPZTYfXt8v4+Pj8xNmSdove6uvZPXawnLEVMT1qRlbFDRei2rPrJyP+9r/k+QliInvpxhv8/QPl4h/qTpfyOn/lIVqRdb/9GSVArLTs/RJ6oqf6Ul/iupfqtr+PJy/87Psc1Lf5ba7+fk/hDR7BTVnVkdNclKEU9OvshIjZpf/CJjfh8mv+Ekvm0wfuBn/zS3fzK1vytvPucsfpncrdGStN7i+oxMkE8P1NVZc4jJkOnqtOhpL1qbXqPnfRnaXQ7QLFme8+Kg8w/RnSHisyAiu+yxPtOQHiWAAAALHRSTlMAsrKosrKysuMkiCQkJLKgqJ2psoid9vZfX4g4qV/j9uMBspyp9F/3YDg4stb3hC8AAAM2SURBVDjL1ZQHV9NQGIbFIksEBBU3uFfNKKFJ05iUDrtboBbaMkqtUGTKkr23ylCG7D3ce/867205SRD/AM/JOUnePHnPzTk334ED+4kjV0/HJ168GBcXFxERGRmZlHT5Usypw3u1+OTGsrI0HofDAU9XJP+oN1PL0mWy23tJizqzqy/VsWOlM4ycIWViU9R5IRH2Qciyzx2fOr6mkQq5IpTIHBJRYbI8PQjT/qK7u3ti4mP7s/ZGkgyF14TK641yBYTprbjnvQdpaWl50fHMHkxvn+LF02lyCMn88Bb09Hi93p6uroqxseZZCsbpMbwYLyMBFDnrzMrKqiiAVDx/3jz05R0FcsVRXkxUMAxD9f5y5gKcTqhnOXObh4de0eCB/CwvxskZhu79fWf5DuTly/Ly3PLy8fG6vjcjFMOQYbwYQdop+dyg2WxerjXX1tYG/eXV1RqLj7bbGZHI0NzPfpXKtpq3ZnsAAK+YHwy6XKq3HEXZBTHSTmtblRaXtSavtM5ms90HZED0Pi1NUyKR4rTTK578fOXW44cqgC1Dr9cbDEbje5rjaEFMojm2df0uYH2jdMhqsVjdoM1grA48rWJ3iRxHVK1A8e5m6bYFNLusKjdQq58+IThOEG9xWpb77lEqldulm8p8Tz64UlqAqze0EiwXzovhHMsSviW327WZN6xSetYeAv54LC6V7QnOagUxjAXiYkMgYNvYMma4wbcD8vpAaX8VzrJikSCI+fr6kpLqhoaA0TBYU9c3XGe1qvrnWIwQiYeAiC12qtXqAXVxfcmjRw2BaqPRYNAv+RBCLJ4lMAzDv6n9JoB/QA1toBunfagGwwhhix8nNBoNPl+8kJMNyckx+UF7cRUuxcEDQthmxzAcgDYVVxYVFRYWFhVl55hMC5MoAmOcFTbuOQzBEQSRts10+v0mYILSys4PUiQYa0/yYvQJJIgOpUeYtsnKqanKgddtmaEQTYkVfsMEBA0h1el0WNPozGgTkbmTaCQXBDH6PCoVyMzUgWPnBo2KFY+KM+cR6f/Q4VE3dg+f6ASwTpQntDycTZHE7pln0eeOHU84CDkECQuTHI05GbuvJvdf76IS5yEI9J0AAAAASUVORK5CYII="
}
