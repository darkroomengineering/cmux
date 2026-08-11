import AppKit
import Bonsplit
import Foundation
import WebKit

/// Passkeys (WebAuthn) cannot work inside Programa's `WKWebView`.
///
/// WebKit gates `navigator.credentials` calls that carry a `publicKey` option behind the
/// `com.apple.developer.web-browser.public-key-credential` entitlement, which Apple grants
/// per app and Programa does not hold. Without it the request neither resolves nor rejects:
/// no system sheet appears, the site's own `timeout` is ignored, and the promise stays
/// pending forever. Sign-in pages therefore sit until they give up and show a generic
/// "something went wrong", which reads like a Programa bug rather than a platform limit.
///
/// This bridge trades that hang for an immediate `NotAllowedError` — so the site's own error
/// path runs at once — plus an in-page notice offering to reopen the page in the user's
/// default browser, where passkeys do work.
enum BrowserPasskeyFallback {
    static let messageHandlerName = "programaPasskeyUnsupported"

    /// Copy rendered by the injected script. Resolved natively so the notice is localized;
    /// the script itself never hardcodes user-facing text.
    private static var noticeStrings: [String: String] {
        [
            "message": String(
                localized: "browser.passkey.notice.message",
                defaultValue: "This site asked for a passkey. Programa’s browser can’t use passkeys."
            ),
            "openExternally": String(
                localized: "browser.passkey.notice.openExternally",
                defaultValue: "Open in default browser"
            ),
            "dismiss": String(
                localized: "browser.passkey.notice.dismiss",
                defaultValue: "Dismiss"
            ),
            "error": String(
                localized: "browser.passkey.error",
                defaultValue: "Passkeys are not available in Programa’s built-in browser."
            ),
        ]
    }

    /// JS object literal for `noticeStrings`, safe to embed in the script source.
    private static var noticeStringsLiteral: String {
        guard let data = try? JSONSerialization.data(withJSONObject: noticeStrings),
              let literal = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return literal
    }

    /// Wraps `navigator.credentials.get`/`create` so a `publicKey` request fails fast instead of
    /// hanging. Non-passkey credential requests (password, federated) pass through untouched.
    ///
    /// Run this via `evaluateJavaScript` after a navigation finishes, not as a `WKUserScript`.
    /// A document-start or document-end user script patches a `CredentialsContainer` that the
    /// loaded page does not end up using — the patch verifiably applies and is then gone by the
    /// time page scripts run. Installation is idempotent (the marker lives on the container, so
    /// a replaced container is re-patched) and also re-runs on `pageshow` for back/forward
    /// restores, which do not fire a fresh navigation.
    static var bootstrapScript: String {
        """
        (() => {
          try {
            const TEXT = \(noticeStringsLiteral);
            const HANDLER_NAME = "\(messageHandlerName)";
            const MARKER = "__programaPasskeyPatched";

            const post = (payload) => {
              try {
                const bridge = window.webkit
                  && window.webkit.messageHandlers
                  && window.webkit.messageHandlers[HANDLER_NAME];
                if (bridge) bridge.postMessage(payload);
              } catch (_) {}
            };

            let host = null;
            const dismiss = () => {
              if (!host) return;
              host.remove();
              host = null;
            };

            const showNotice = () => {
              if (host || !document.documentElement) return;
              host = document.createElement("div");
              host.setAttribute("data-programa-passkey-notice", "");
              host.style.cssText = [
                "position:fixed",
                "left:0",
                "right:0",
                "bottom:0",
                "z-index:2147483647",
                "pointer-events:none"
              ].join(";");

              // Open rather than closed so Programa's own browser automation (and anyone
              // debugging in DevTools) can see and drive the notice.
              const root = host.attachShadow({ mode: "open" });
              const bar = document.createElement("div");
              bar.setAttribute("role", "status");
              bar.style.cssText = [
                "pointer-events:auto",
                "margin:0 auto 16px",
                "max-width:640px",
                "display:flex",
                "align-items:center",
                "gap:12px",
                "padding:12px 14px",
                "border-radius:10px",
                "background:rgba(28,28,30,0.96)",
                "color:#fff",
                "box-shadow:0 6px 24px rgba(0,0,0,0.35)",
                "font:13px/1.4 -apple-system,BlinkMacSystemFont,system-ui,sans-serif"
              ].join(";");

              const label = document.createElement("span");
              label.textContent = TEXT.message || "";
              label.style.cssText = "flex:1";

              const makeButton = (text, primary) => {
                const button = document.createElement("button");
                button.type = "button";
                button.textContent = text || "";
                button.style.cssText = [
                  "flex:none",
                  "border:0",
                  "border-radius:6px",
                  "padding:6px 10px",
                  "cursor:pointer",
                  "font:inherit",
                  "font-weight:500",
                  primary ? "background:#0a84ff" : "background:rgba(255,255,255,0.16)",
                  "color:#fff"
                ].join(";");
                return button;
              };

              const openButton = makeButton(TEXT.openExternally, true);
              openButton.addEventListener("click", () => {
                post({ action: "open-external", url: location.href });
                dismiss();
              });

              const dismissButton = makeButton(TEXT.dismiss, false);
              dismissButton.addEventListener("click", dismiss);

              bar.appendChild(label);
              bar.appendChild(openButton);
              bar.appendChild(dismissButton);
              root.appendChild(bar);
              document.documentElement.appendChild(host);
            };

            const refuse = (kind) => {
              post({ action: "blocked", kind: kind, url: location.href });
              try { showNotice(); } catch (_) {}
              return Promise.reject(
                new DOMException(TEXT.error || "Passkeys are unavailable.", "NotAllowedError")
              );
            };

            const wrap = (creds, name) => {
              const original = creds[name];
              if (typeof original !== "function") return;
              const bound = original.bind(creds);
              const replacement = function (options) {
                if (options && options.publicKey) return refuse(name);
                return bound(options);
              };
              // Plain assignment (creds[name] = ...) silently no-ops here, so define the
              // property explicitly instead.
              Object.defineProperty(creds, name, {
                value: replacement,
                writable: true,
                configurable: true
              });
            };

            const install = () => {
              try {
                const creds = navigator.credentials;
                if (!creds || creds[MARKER]) return;
                wrap(creds, "get");
                wrap(creds, "create");
                Object.defineProperty(creds, MARKER, {
                  value: true,
                  configurable: true
                });
                // Pin the container. Its JS wrapper is collected once nothing references it,
                // and the next `navigator.credentials` read mints a fresh one without these
                // properties — so an unpinned patch silently reverts between calls.
                window.__programaPasskeyContainer = creds;
              } catch (_) {}
            };

            install();
            document.addEventListener("DOMContentLoaded", install, true);
            window.addEventListener("pageshow", install, true);
          } catch (_) {}
        })();
        """
    }
}

/// Receives passkey-blocked notifications from `BrowserPasskeyFallback.bootstrapScript` and
/// forwards an explicit "open in default browser" request to the native layer.
final class BrowserPasskeyMessageHandler: NSObject, WKScriptMessageHandler {
    private let onOpenExternally: (URL) -> Void

    init(onOpenExternally: @escaping (URL) -> Void) {
        self.onOpenExternally = onOpenExternally
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }

        #if DEBUG
        if action == "blocked" {
            let kind = body["kind"] as? String ?? "unknown"
            let url = body["url"] as? String ?? "unknown"
            dlog("browser.passkey.blocked kind=\(kind) url=\(url)")
        }
        #endif

        // "blocked" is telemetry only; the page never gets to steer the user out of the app
        // without an explicit click on the notice.
        guard action == "open-external" else { return }
        guard let raw = body["url"] as? String,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }

        onOpenExternally(url)
    }
}
