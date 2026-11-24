// Courier website: theme toggle, copy buttons, install tabs, OS-aware download button,
// and docs table-of-contents highlighting. Plain JS, no dependencies.
(function () {
  "use strict";

  var REPO = "ranefattesingh/courier";
  var RELEASES = "https://github.com/" + REPO + "/releases/latest";

  // ---------------------------------------------------------------- theme
  function storedTheme() {
    try {
      return localStorage.getItem("courier-theme");
    } catch (e) {
      return null;
    }
  }
  function applyTheme(t) {
    if (t === "light" || t === "dark") document.documentElement.setAttribute("data-theme", t);
    else document.documentElement.removeAttribute("data-theme");
  }
  applyTheme(storedTheme());

  function currentTheme() {
    var t = document.documentElement.getAttribute("data-theme");
    if (t) return t;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  document.addEventListener("DOMContentLoaded", function () {
    var toggle = document.getElementById("theme-toggle");
    if (toggle) {
      toggle.addEventListener("click", function () {
        var next = currentTheme() === "dark" ? "light" : "dark";
        applyTheme(next);
        try {
          localStorage.setItem("courier-theme", next);
        } catch (e) {}
      });
    }

    setupCopyButtons();
    setupTabs();
    setupDownloads();
    setupToc();
  });

  // ---------------------------------------------------------------- copy buttons
  var COPY_ICON =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>';
  var DONE_ICON =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" aria-hidden="true"><path d="M5 12l5 5L20 7"/></svg>';

  function setupCopyButtons() {
    document.querySelectorAll("pre[data-copy]").forEach(function (pre) {
      var box = document.createElement("div");
      box.className = "code";
      pre.parentNode.insertBefore(box, pre);
      box.appendChild(pre);
      var btn = document.createElement("button");
      btn.className = "copy";
      btn.type = "button";
      btn.title = "Copy";
      btn.setAttribute("aria-label", "Copy to clipboard");
      btn.innerHTML = COPY_ICON;
      btn.addEventListener("click", function () {
        // Skip comment lines (marked with class "c") so pasted commands run as-is.
        var clone = pre.cloneNode(true);
        clone.querySelectorAll(".c").forEach(function (c) {
          c.remove();
        });
        var text = clone.textContent.replace(/^\s*\n/gm, "").trim();
        var done = function () {
          btn.innerHTML = DONE_ICON;
          btn.classList.add("done");
          setTimeout(function () {
            btn.innerHTML = COPY_ICON;
            btn.classList.remove("done");
          }, 1400);
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(done, function () {});
        }
      });
      box.appendChild(btn);
    });
  }

  // ---------------------------------------------------------------- tabs
  function setupTabs() {
    document.querySelectorAll("[data-tabs]").forEach(function (root) {
      var buttons = root.querySelectorAll('[role="tab"]');
      function select(id, focus) {
        buttons.forEach(function (b) {
          var on = b.getAttribute("aria-controls") === id;
          b.setAttribute("aria-selected", on ? "true" : "false");
          b.tabIndex = on ? 0 : -1;
          if (on && focus) b.focus();
        });
        root.querySelectorAll('[role="tabpanel"]').forEach(function (p) {
          p.hidden = p.id !== id;
        });
      }
      buttons.forEach(function (b, i) {
        b.addEventListener("click", function () {
          select(b.getAttribute("aria-controls"));
        });
        b.addEventListener("keydown", function (e) {
          var d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
          if (!d) return;
          var n = buttons[(i + d + buttons.length) % buttons.length];
          select(n.getAttribute("aria-controls"), true);
          e.preventDefault();
        });
      });
      root.selectTab = select;
    });
  }

  // ---------------------------------------------------------------- downloads
  function detectOS() {
    var ua = navigator.userAgent || "";
    var p = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    if (/Win/i.test(p) || /Windows/i.test(ua)) return "windows";
    if (/Mac/i.test(p) || /Mac OS X/i.test(ua)) return /iPhone|iPad/i.test(ua) ? null : "macos";
    if (/Android/i.test(ua)) return null;
    if (/Fedora|Red Hat|CentOS|Rocky|Alma/i.test(ua)) return "fedora";
    if (/Linux|X11/i.test(p + ua)) return "debian";
    return null;
  }

  var LABELS = {
    windows: "Download for Windows",
    macos: "Download for macOS",
    debian: "Get it for Linux",
    fedora: "Get it for Linux",
  };

  function setupDownloads() {
    var os = detectOS();
    var main = document.getElementById("download-main");
    var label = document.getElementById("download-label");
    var note = document.getElementById("download-note");
    var tabs = document.querySelector("[data-tabs]");

    if (tabs && tabs.selectTab && os) tabs.selectTab("tab-" + os);

    if (main && label && os) {
      label.textContent = LABELS[os];
      // Linux users install from the package repository, so point them at the instructions.
      if (os === "debian" || os === "fedora") main.setAttribute("href", "#install");
    }

    // Fill in direct links and the version number from the latest GitHub release.
    if (!window.fetch) return;
    fetch("https://api.github.com/repos/" + REPO + "/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
      .then(function (r) {
        return r.ok ? r.json() : null;
      })
      .then(function (rel) {
        if (!rel || !rel.assets) return;
        var version = (rel.tag_name || "").replace(/^v/, "");
        var find = function (re) {
          for (var i = 0; i < rel.assets.length; i++) if (re.test(rel.assets[i].name)) return rel.assets[i].browser_download_url;
          return null;
        };
        var urls = {
          windows: find(/^Courier-Setup-.*\.exe$/),
          "windows-zip": find(/windows.*portable\.zip$/),
          macos: find(/macos.*\.zip$/),
          deb: find(/\.deb$/),
          rpm: find(/\.rpm$/),
          tar: find(/linux.*\.tar\.gz$/),
        };
        document.querySelectorAll("[data-asset]").forEach(function (a) {
          var u = urls[a.getAttribute("data-asset")];
          if (u) a.setAttribute("href", u);
        });
        document.querySelectorAll("[data-version]").forEach(function (el) {
          if (version) el.textContent = version;
        });
        if (main && (os === "windows" || os === "macos") && urls[os]) main.setAttribute("href", urls[os]);
        if (note && version) {
          note.innerHTML =
            "Version " + version + " · Windows, macOS and Linux · " + '<a href="' + RELEASES + '">All downloads</a>';
        }
      })
      .catch(function () {});
  }

  // ---------------------------------------------------------------- docs TOC
  function setupToc() {
    var toc = document.querySelector(".toc nav");
    if (!toc) return;
    // The menu is a collapsible "On this page" box on phones and an always-open sidebar on desktop.
    var details = toc.closest("details");
    var wide = window.matchMedia("(min-width: 980px)");
    var syncOpen = function () {
      if (details) details.open = wide.matches;
    };
    syncOpen();
    if (wide.addEventListener) wide.addEventListener("change", syncOpen);
    var links = Array.prototype.slice.call(toc.querySelectorAll('a[href^="#"]'));
    var map = {};
    links.forEach(function (a) {
      map[a.getAttribute("href").slice(1)] = a;
      a.addEventListener("click", function () {
        if (details && !wide.matches) details.open = false;
      });
    });
    var sections = links
      .map(function (a) {
        return document.getElementById(a.getAttribute("href").slice(1));
      })
      .filter(Boolean);
    if (!("IntersectionObserver" in window) || !sections.length) return;

    var visible = {};
    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (e) {
          visible[e.target.id] = e.isIntersecting;
        });
        var current = null;
        for (var i = 0; i < sections.length; i++) {
          if (visible[sections[i].id]) {
            current = sections[i].id;
            break;
          }
        }
        if (!current) return;
        links.forEach(function (a) {
          a.classList.toggle("active", a === map[current]);
        });
        var active = map[current];
        if (active && window.innerWidth >= 980) {
          var box = toc.closest(".toc");
          var top = active.offsetTop - box.clientHeight / 2;
          if (active.offsetTop < box.scrollTop || active.offsetTop > box.scrollTop + box.clientHeight - 40) box.scrollTop = top;
        }
      },
      { rootMargin: "-70px 0px -55% 0px" }
    );
    sections.forEach(function (s) {
      observer.observe(s);
    });
  }
})();
