// Connects the LiveView pages (the Codex login). Phoenix and LiveView are
// loaded from their packages' builds by the root layout; there is no bundler.
(function () {
  var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
