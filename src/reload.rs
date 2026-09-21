//! 重新加载页面：给页面 JS 调用的 API（`window.__CIRCLECHAT__.reload()`），
//! 并把 F5 / Ctrl+R 接管成「重新加载当前页」（卡住或开发调试时点一下就能刷新）。

pub(crate) const API_SCRIPT: &str = r#"
(function () {
  // 1) 页面可调用的 reload()
  if (!(window.__CIRCLECHAT__ && window.__CIRCLECHAT__.reload)) {
    window.__CIRCLECHAT__ = Object.assign(window.__CIRCLECHAT__ || {}, {
      reload: function () {
        if (window.ipc) {
          try {
            window.ipc.postMessage(JSON.stringify({ action: 'reload' }));
            return;
          } catch (e) { /* 落到下面的原生刷新 */ }
        }
        location.reload();
      }
    });
  }

  // 2) 接管 F5 / Ctrl+R 为「重新加载当前页」
  //    —— 排除带 Shift 的组合（那是 Ctrl+Shift+R 重置配置，已在别处处理），
  //    —— 输入框 / 可编辑区域里不拦截，避免影响正常输入。
  if (window.__circleChatReloadBound) { return; }
  window.__circleChatReloadBound = true;

  window.addEventListener('keydown', function (event) {
    var isMac = /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent);
    var modifier = isMac ? event.metaKey : event.ctrlKey;
    var wantReload = event.key === 'F5' ||
      (modifier && !event.shiftKey && (event.key === 'r' || event.key === 'R'));
    if (!wantReload) { return; }

    var t = event.target;
    var tag = (t && t.tagName) || '';
    if (tag === 'INPUT' || tag === 'TEXTAREA' || (t && t.isContentEditable)) { return; }

    event.preventDefault();
    event.stopPropagation();

    if (window.__CIRCLECHAT__ && window.__CIRCLECHAT__.reload) {
      window.__CIRCLECHAT__.reload();
    } else {
      location.reload();
    }
  }, true);
})();
"#;
