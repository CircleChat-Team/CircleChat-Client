//! 抖动窗口：给页面 JS 调用的 API（`window.__CIRCLECHAT__.shakeWindow()`）。
//!
//! 流程：JS 发 IPC（action=shake） → Rust 把窗口置顶到前台并左右抖动几下。

/// 注入给页面的「抖动窗口」API。shakeWindow() 把请求发给宿主后立刻 resolve，
/// done:true 表示已触发；无 IPC（非客户端环境）时 done:false。
pub(crate) const API_SCRIPT: &str = r#"
(function () {
  if (window.__CIRCLECHAT__ && window.__CIRCLECHAT__.shakeWindow) { return; }

  window.__CIRCLECHAT__ = Object.assign(window.__CIRCLECHAT__ || {}, {
    shakeWindow: function () {
      return new Promise(function (resolve) {
        if (!window.ipc) {
          resolve({ done: false, error: 'ipc-unavailable' });
          return;
        }
        try {
          window.ipc.postMessage(JSON.stringify({ action: 'shake' }));
          resolve({ done: true });
        } catch (error) {
          resolve({ done: false, error: String(error) });
        }
      });
    }
  });
})();
"#;
