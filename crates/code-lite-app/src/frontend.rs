pub const INDEX_HTML: &str = r#"<!DOCTYPE html>
<html lang="zh-CN" class="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>CodeLiteX - IntelliJ IDEA New UI</title>
  <script src="https://www.gstatic.com/antigravity/web/dev/tailwindcss.min.js"></script>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Inter:wght@400;500;600;700&display=swap');

    :root {
      --ij-bg-header: #1e1f22;
      --ij-bg-stripe: #1e1f22;
      --ij-bg-panel: #2b2d30;
      --ij-bg-editor: #1e1f22;
      --ij-bg-tab-active: #1e1f22;
      --ij-bg-tab-inactive: #2b2d30;
      --ij-border: #393b40;
      --ij-border-subtle: #2e3035;
      --ij-text-primary: #bcbec4;
      --ij-text-muted: #707278;
      --ij-accent-blue: #3574f0;
      --ij-git-green: #59a869;
      --ij-git-blue: #3574f0;
      --ij-git-red: #db5860;
      --ij-git-yellow: #e5a84b;
    }

    body {
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background-color: #141416;
      color: var(--ij-text-primary);
      user-select: none;
    }

    .code-font {
      font-family: 'JetBrains Mono', monospace;
    }

    ::-webkit-scrollbar { width: 6px; height: 6px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: #43454a; border-radius: 3px; }
    ::-webkit-scrollbar-thumb:hover { background: #5a5d63; }

    .tab-active {
      background-color: var(--ij-bg-tab-active) !important;
      color: #dfe1e5 !important;
      border-bottom: 2px solid var(--ij-accent-blue) !important;
    }

    .stripe-btn-active {
      background-color: #3574f0 !important;
      color: #ffffff !important;
    }
    .stripe-btn-active svg { stroke: #ffffff !important; }
  </style>
</head>
<body class="p-2 h-screen flex flex-col justify-center items-center overflow-hidden">

  <!-- Main Window -->
  <div class="w-full h-full flex flex-col rounded-lg overflow-hidden border border-[#393b40] shadow-2xl bg-[var(--ij-bg-editor)]">
    
    <!-- Top Header -->
    <header class="h-10 bg-[var(--ij-bg-header)] border-b border-[var(--ij-border-subtle)] flex items-center justify-between px-3 shrink-0">
      <div class="flex items-center space-x-3">
        <!-- Traffic lights -->
        <div class="flex items-center space-x-2 mr-2">
          <div class="w-3 h-3 rounded-full bg-[#ec6a5e] border border-[#d15246]"></div>
          <div class="w-3 h-3 rounded-full bg-[#f4bf4f] border border-[#d7a13c]"></div>
          <div class="w-3 h-3 rounded-full bg-[#62c554] border border-[#48a93c]"></div>
        </div>

        <!-- Project Dropdown Badge -->
        <div class="flex items-center space-x-1.5 px-2 py-0.5 rounded bg-[#2b2d30] border border-[#393b40] text-xs font-medium cursor-pointer">
          <span class="w-3.5 h-3.5 rounded bg-[#3574f0] text-white flex items-center justify-center font-bold text-[9px]">CL</span>
          <span class="text-[#dfe1e5] font-semibold" id="header-project-name">code-lite-x</span>
          <span class="text-[var(--ij-text-muted)] text-[11px]">[Rust Core]</span>
        </div>

        <!-- Branch Badge -->
        <div class="flex items-center space-x-1 px-2 py-0.5 rounded hover:bg-[#2b2d30] text-xs text-[var(--ij-text-muted)]">
          <svg class="w-3.5 h-3.5 text-[#59a869]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4"/></svg>
          <span class="text-[#dfe1e5] font-mono text-[11px]">main</span>
        </div>

        <!-- Breadcrumbs -->
        <div class="hidden lg:flex items-center space-x-1 text-xs text-[var(--ij-text-muted)]" id="breadcrumbs">
          <span>crates</span> <span>/</span> <span class="text-[#dfe1e5]" id="breadcrumb-file">crates/code-lite-core/src/buffer.rs</span>
        </div>
      </div>

      <!-- Center Search Everywhere -->
      <div class="flex items-center">
        <div class="flex items-center space-x-2 bg-[#2b2d30] border border-[#393b40] rounded-md px-3 py-1 text-xs text-[var(--ij-text-muted)] w-64 justify-between">
          <div class="flex items-center space-x-2">
            <svg class="w-3.5 h-3.5 text-[#707278]" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/></svg>
            <span>Search Everywhere</span>
          </div>
          <span class="text-[10px] bg-[#1e1f22] px-1.5 py-0.5 rounded border border-[#393b40]">⇧ ⇧</span>
        </div>
      </div>

      <!-- Right Controls -->
      <div class="flex items-center space-x-2">
        <button onclick="undo()" class="p-1 rounded hover:bg-[#2b2d30] text-[var(--ij-text-muted)] hover:text-[#dfe1e5]" title="Undo (Cmd+Z)">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 10h10a8 8 0 018 8v2M3 10l6 6m-6-6l6-6"/></svg>
        </button>
        <button onclick="redo()" class="p-1 rounded hover:bg-[#2b2d30] text-[var(--ij-text-muted)] hover:text-[#dfe1e5]" title="Redo (Cmd+Shift+Z)">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 10h-10a8 8 0 00-8 8v2m18-10l-6 6m6-6l-6-6"/></svg>
        </button>
      </div>
    </header>

    <!-- Main Workspace Area -->
    <div class="flex-1 flex overflow-hidden">
      <!-- Left Activity Stripe -->
      <aside class="w-11 bg-[var(--ij-bg-stripe)] border-r border-[var(--ij-border-subtle)] flex flex-col justify-between items-center py-2 shrink-0">
        <div class="flex flex-col space-y-2">
          <button id="btn-stripe-project" onclick="switchLeftTab('project')" class="w-8 h-8 rounded-lg flex items-center justify-center text-[#dfe1e5] stripe-btn-active" title="Project">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"/></svg>
          </button>
        </div>
        <div>
          <button onclick="switchBottomTab('terminal')" class="w-8 h-8 rounded-lg flex items-center justify-center text-[var(--ij-text-muted)] hover:text-[#dfe1e5]" title="Terminal">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"/></svg>
          </button>
        </div>
      </aside>

      <!-- Left Tool Window -->
      <section class="w-64 bg-[var(--ij-bg-panel)] border-r border-[var(--ij-border-subtle)] flex flex-col shrink-0">
        <div class="h-8 border-b border-[var(--ij-border-subtle)] flex items-center justify-between px-3 text-xs font-semibold text-[#dfe1e5]">
          <span id="left-title">Project</span>
          <span class="text-[10px] text-[var(--ij-text-muted)] font-normal">Real FS Tree</span>
        </div>
        <div id="tree-container" class="flex-1 overflow-y-auto p-1 text-xs code-font">
          <!-- Populated dynamically via /api/workspace -->
          <div class="p-2 text-[var(--ij-text-muted)]">Scanning workspace...</div>
        </div>
      </section>

      <!-- Center Editor Area -->
      <main class="flex-1 flex flex-col min-w-0 bg-[var(--ij-bg-editor)]">
        <!-- Tabs -->
        <div class="h-8 bg-[var(--ij-bg-tab-inactive)] border-b border-[var(--ij-border-subtle)] flex items-center px-1 overflow-x-auto shrink-0" id="tabs-bar">
          <!-- Dynamic tabs -->
        </div>

        <!-- Editor Content -->
        <div class="flex-1 flex overflow-hidden relative">
          <!-- Line Numbers Gutter -->
          <div id="gutter" class="w-12 bg-[var(--ij-bg-editor)] border-r border-[#2e3035] p-2 text-right text-[11px] code-font text-[#606366] select-none shrink-0 leading-5">
            1
          </div>

          <!-- Code Textarea (Connected to Rust Editor Core) -->
          <div class="flex-1 flex flex-col relative overflow-hidden">
            <textarea id="code-editor" spellcheck="false" class="w-full h-full bg-[var(--ij-bg-editor)] text-[#dfe1e5] p-2 code-font text-xs leading-5 resize-none focus:outline-none border-none"></textarea>
          </div>
        </div>

        <!-- Bottom Tool Window (Terminal) -->
        <section class="h-56 bg-[var(--ij-bg-panel)] border-t border-[var(--ij-border-subtle)] flex flex-col shrink-0">
          <div class="h-7 bg-[#232428] border-b border-[var(--ij-border-subtle)] flex items-center justify-between px-2 text-xs">
            <div class="flex items-center space-x-1">
              <button id="btab-terminal" onclick="switchBottomTab('terminal')" class="px-3 py-0.5 font-semibold text-[#dfe1e5] bg-[var(--ij-bg-panel)] rounded-t border-t-2 border-[var(--ij-accent-blue)]">
                Terminal Log
              </button>
            </div>
          </div>

          <!-- Terminal Content -->
          <div id="bview-terminal" class="flex-1 p-2 bg-[#1e1f22] text-xs code-font overflow-y-auto text-[#bcbec4]">
            <div class="text-[#59a869]">CodeLiteX Embedded Server Active</div>
            <div class="text-[var(--ij-text-muted)]">Listening on http://127.0.0.1:4096</div>
            <div class="text-[#dfe1e5] mt-1">Rust Core: code-lite-core (Ropey + Multi-cursor)</div>
          </div>
        </section>
      </main>
    </div>

    <!-- Status Bar -->
    <footer class="h-5 bg-[#1e1f22] border-t border-[var(--ij-border-subtle)] flex items-center justify-between px-3 text-[10px] text-[var(--ij-text-muted)] shrink-0">
      <div class="flex items-center space-x-2">
        <span class="text-[#59a869]">● Connected</span>
      </div>
      <div class="flex items-center space-x-2">
        <span id="status-cursor">Line: 1, Col: 1</span>
        <span>•</span>
        <span>UTF-8</span>
      </div>
    </footer>
  </div>

  <script>
    let activeFile = 'crates/code-lite-core/src/buffer.rs';
    let openTabs = ['crates/code-lite-core/src/buffer.rs'];

    async function init() {
      await loadWorkspace();
      await openFile(activeFile);
      setupEditorListeners();
    }

    async function loadWorkspace() {
      try {
        const res = await fetch('/api/workspace');
        const data = await res.json();
        const container = document.getElementById('tree-container');
        container.innerHTML = renderTree(data, '');
      } catch (err) {
        console.error(err);
      }
    }

    function renderTree(node, prefix) {
      if (!node) return '';
      let html = '';
      const isDir = node.is_dir;
      const relPath = node.path ? (prefix ? prefix + '/' + node.name : node.name) : '';
      
      if (isDir) {
        html += `<div class="py-0.5 cursor-pointer hover:bg-[#35373c] px-1 text-[#dfe1e5] flex items-center">
          <span class="mr-1 text-[10px]">📁</span> <span class="font-medium">${node.name}</span>
        </div>`;
        if (node.children) {
          html += '<div class="pl-3 border-l border-[#35373c]/50 ml-1.5">';
          for (const child of node.children) {
            html += renderTree(child, relPath);
          }
          html += '</div>';
        }
      } else {
        const icon = node.name.endsWith('.rs') ? '⚙' : (node.name.endsWith('.toml') ? '📄' : '📘');
        const color = node.name.endsWith('.rs') ? 'text-[#d87642]' : 'text-[#56a8f5]';
        html += `<div onclick="openFile('${node.path}')" class="py-0.5 cursor-pointer hover:bg-[#35373c] px-1 text-[#bcbec4] hover:text-[#dfe1e5] flex items-center">
          <span class="${color} mr-1 text-[10px]">${icon}</span> <span>${node.name}</span>
        </div>`;
      }
      return html;
    }

    async function openFile(path) {
      try {
        const res = await fetch(`/api/file?path=${encodeURIComponent(path)}`);
        const data = await res.json();
        activeFile = path;
        document.getElementById('code-editor').value = data.content || '';
        document.getElementById('breadcrumb-file').innerText = path;

        if (!openTabs.includes(path)) openTabs.push(path);
        renderTabs();
        updateGutter();
      } catch (err) {
        console.error(err);
      }
    }

    function renderTabs() {
      const bar = document.getElementById('tabs-bar');
      bar.innerHTML = openTabs.map(p => {
        const name = p.split('/').pop();
        const isActive = p === activeFile;
        return `<div onclick="openFile('${p}')" class="h-full px-2.5 flex items-center space-x-1.5 text-xs cursor-pointer ${isActive ? 'tab-active' : 'text-[var(--ij-text-muted)] hover:text-[#dfe1e5]'}">
          <span class="text-[#d87642] text-[10px]">⚙</span>
          <span>${name}</span>
        </div>`;
      }).join('');
    }

    function updateGutter() {
      const content = document.getElementById('code-editor').value;
      const count = content.split('\n').length;
      let gutterHtml = '';
      for (let i = 1; i <= count; i++) {
        gutterHtml += `<div>${i}</div>`;
      }
      document.getElementById('gutter').innerHTML = gutterHtml;
    }

    function setupEditorListeners() {
      const editor = document.getElementById('code-editor');
      editor.addEventListener('input', () => {
        updateGutter();
      });
      editor.addEventListener('keydown', (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === 'z') {
          e.preventDefault();
          if (e.shiftKey) redo(); else undo();
        }
      });
    }

    async function undo() {
      try {
        const res = await fetch('/api/undo', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ path: activeFile })
        });
        const data = await res.json();
        if (data.content !== undefined) {
          document.getElementById('code-editor').value = data.content;
          updateGutter();
        }
      } catch (e) { console.error(e); }
    }

    async function redo() {
      try {
        const res = await fetch('/api/redo', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ path: activeFile })
        });
        const data = await res.json();
        if (data.content !== undefined) {
          document.getElementById('code-editor').value = data.content;
          updateGutter();
        }
      } catch (e) { console.error(e); }
    }

    function switchBottomTab(tab) {
      ['terminal'].forEach(t => {
        document.getElementById('bview-' + t).classList.add('hidden');
        document.getElementById('btab-' + t).className = 'px-3 py-0.5 font-medium text-[var(--ij-text-muted)] hover:text-[#dfe1e5]';
      });
      document.getElementById('bview-' + tab).classList.remove('hidden');
      document.getElementById('btab-' + tab).className = 'px-3 py-0.5 font-semibold text-[#dfe1e5] bg-[var(--ij-bg-panel)] rounded-t border-t-2 border-[var(--ij-accent-blue)]';
    }

    window.onload = init;
  </script>
</body>
</html>
"#;
