//! 系统通知：给页面 JS 调用的 API（`window.__CIRCLECHAT__.notify(...)`）。

use crate::app;
use crate::icon;

/// 标题 / 正文长度上限（页面传进来的内容不可全信，截断一下）。
const TITLE_LIMIT: usize = 120;
const BODY_LIMIT: usize = 500;

/// 注入给页面的通知 API。
///
/// 流程：JS 发 IPC（带一个自增 id） → Rust 后台线程调系统通知 → 主线程把结果
/// 通过 `window.__circleChatNotifyResult(id, result)` 回传 → JS 的 Promise resolve。
pub(crate) const API_SCRIPT: &str = r#"
(function () {
  if (window.__CIRCLECHAT__ && window.__CIRCLECHAT__.notify) { return; }

  var pending = new Map();
  var sequence = 0;
  var TIMEOUT_MS = 10000;

  function resolvePending(id, result) {
    var resolve = pending.get(id);
    if (resolve) {
      pending.delete(id);
      resolve(result);
    }
  }

  // Rust 侧回传结果的入口
  window.__circleChatNotifyResult = resolvePending;

  window.__CIRCLECHAT__ = Object.assign(window.__CIRCLECHAT__ || {}, {
    notify: function (options) {
      var input = typeof options === 'string' ? { title: options } : (options || {});
      var id = 'n' + Date.now() + '-' + (++sequence);

      return new Promise(function (resolve) {
        if (!window.ipc) {
          resolve({ ok: false, error: 'ipc-unavailable' });
          return;
        }

        pending.set(id, resolve);

        try {
          window.ipc.postMessage(JSON.stringify({
            action: 'notify',
            id: id,
            title: input.title == null ? '' : String(input.title),
            body: input.body == null ? '' : String(input.body)
          }));
        } catch (error) {
          pending.delete(id);
          resolve({ ok: false, error: String(error) });
          return;
        }

        setTimeout(function () {
          if (pending.has(id)) {
            pending.delete(id);
            resolve({ ok: false, error: 'timeout' });
          }
        }, TIMEOUT_MS);
      });
    }
  });
})();
"#;

/// 发一条系统通知。阻塞式的 D-Bus / WinRT 调用，调用方要放到后台线程跑。
pub(crate) fn show(title: &str, body: &str) -> Result<(), String> {
    let summary = truncate(title.trim(), TITLE_LIMIT);
    let body = truncate(body.trim(), BODY_LIMIT);

    let mut notification = notify_rust::Notification::new();
    notification.appname(app::APP_DISPLAY_NAME);

    // 通知图标：Linux 走文件路径，其它平台由系统决定（尽力而为，失败不影响通知本身）
    if let Some(icon) = icon::notification_icon_path() {
        notification.icon(&icon.to_string_lossy());
    }

    // 标题为空时退回应用名，避免出现空标题的系统通知
    if summary.is_empty() {
        notification.summary(app::APP_DISPLAY_NAME);
    } else {
        notification.summary(&summary);
    }
    if !body.is_empty() {
        notification.body(&body);
    }

    notification
        .show()
        .map(|_| ())
        .map_err(|err| err.to_string())
}

/// 按字符数截断（不会切断多字节字符）。
fn truncate(input: &str, limit: usize) -> String {
    if input.chars().count() <= limit {
        return input.to_string();
    }

    let mut truncated: String = input.chars().take(limit).collect();
    truncated.push('…');
    truncated
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_keeps_multibyte_intact() {
        assert_eq!(truncate("abcdef", 3), "abc…");
        assert_eq!(truncate("中文测试", 2), "中文…");
        assert_eq!(truncate("短", 10), "短");
    }
}
