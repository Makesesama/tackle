// Connects the LiveView pages. Phoenix and LiveView are loaded from their
// packages' builds by the root layout; there is no bundler.
(function () {
  var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
  });

  // `data-confirm` asks before a click goes on (removing someone's access).
  // A capturing listener runs before LiveView's own click handling.
  window.addEventListener(
    "click",
    function (event) {
      var target = event.target.closest && event.target.closest("[data-confirm]");

      if (target && !window.confirm(target.getAttribute("data-confirm"))) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    },
    true
  );

  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
