// Connects the LiveView pages. Phoenix and LiveView are loaded from their
// packages' builds by the root layout; there is no bundler.
(function () {
  var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
  });

  // `data-confirm` asks before a click goes on (removing someone's access).
  // With `data-confirm-if`, a selector of a checkbox, it only asks when that
  // checkbox is checked. A capturing listener runs before LiveView's own
  // click handling, and a form's submit button gets a click for Enter too.
  window.addEventListener(
    "click",
    function (event) {
      var target = event.target.closest && event.target.closest("[data-confirm]");
      if (!target) return;

      var condition = target.getAttribute("data-confirm-if");
      var checkbox = condition && document.querySelector(condition);
      if (condition && !(checkbox && checkbox.checked)) return;

      if (!window.confirm(target.getAttribute("data-confirm"))) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    },
    true
  );

  // `data-copy` copies the text of the element it selects (the Codex code)
  // and says so on the button for a moment.
  window.addEventListener("click", function (event) {
    var button = event.target.closest && event.target.closest("[data-copy]");
    if (!button || !navigator.clipboard) return;

    var source = document.querySelector(button.getAttribute("data-copy"));
    if (!source) return;

    // The label before the first copy, so quick repeated clicks restore it.
    if (!button.hasAttribute("data-label")) button.setAttribute("data-label", button.textContent);

    navigator.clipboard.writeText(source.textContent.trim()).then(
      function () {
        button.textContent = button.getAttribute("data-copied") || "Copied";
        clearTimeout(button.copyTimer);
        button.copyTimer = setTimeout(function () {
          button.textContent = button.getAttribute("data-label");
        }, 1500);
      },
      function () {
        // Not allowed (no permission, or the page not focused): the code
        // stays on the page to copy by hand.
      }
    );
  });

  // The top bar is not rendered again on live navigation, so its current
  // section is marked here: the link whose `data-paths` has a prefix of the
  // path.
  function markCurrentSection() {
    var path = window.location.pathname;
    var links = document.querySelectorAll(".topbar nav [data-paths]");

    links.forEach(function (link) {
      var current = link
        .getAttribute("data-paths")
        .split(" ")
        .some(function (prefix) {
          return path === prefix || path.indexOf(prefix + "/") === 0;
        });

      if (current) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    });
  }

  markCurrentSection();
  window.addEventListener("phx:page-loading-stop", markCurrentSection);

  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
