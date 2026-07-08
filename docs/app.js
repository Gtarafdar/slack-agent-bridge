(function () {
  "use strict";

  var REPO = "Gtarafdar/slack-agent-bridge";
  var RELEASES_PAGE = "https://github.com/" + REPO + "/releases/latest";
  var FALLBACK_DMG = "downloads/SlackAgentBridge-1.0.dmg";

  document.documentElement.classList.add("js");

  function setDownloadLinks(url, fullLabel, sidebarMeta) {
    document.querySelectorAll("[data-download]").forEach(function (el) {
      el.setAttribute("href", url);
      if (fullLabel && el.hasAttribute("data-download-label")) {
        el.textContent = fullLabel;
      }
    });
    var meta = document.getElementById("download-meta");
    if (meta && sidebarMeta) {
      meta.textContent = sidebarMeta + " · .dmg from GitHub Releases";
    }
    var sidebarRelease = document.getElementById("sidebar-release-meta");
    if (sidebarRelease && sidebarMeta) {
      sidebarRelease.textContent = sidebarMeta;
    }
  }

  function formatSize(bytes) {
    if (!bytes) return "";
    var mb = bytes / (1024 * 1024);
    return mb < 1 ? Math.round(bytes / 1024) + " KB" : mb.toFixed(1) + " MB";
  }

  function loadLatestRelease() {
    var fallbackLabel = "Download for macOS";
    var fallbackSidebar = "v1.0 · 3.4 MB · macOS 13+";
    setDownloadLinks(FALLBACK_DMG, fallbackLabel, fallbackSidebar);

    fetch("https://api.github.com/repos/" + REPO + "/releases/latest")
      .then(function (res) {
        if (!res.ok) throw new Error("release fetch failed");
        return res.json();
      })
      .then(function (data) {
        var dmg = (data.assets || []).find(function (a) {
          return /\.dmg$/i.test(a.name);
        });
        if (dmg && dmg.browser_download_url) {
          var tag = data.tag_name || "latest";
          var sidebarMeta = tag + " · " + formatSize(dmg.size) + " · macOS 13+";
          var fullLabel = "Download " + tag + " · " + formatSize(dmg.size) + " · .dmg";
          setDownloadLinks(dmg.browser_download_url, fullLabel, sidebarMeta);
        } else if (data.html_url) {
          setDownloadLinks(data.html_url, "Download from Releases", fallbackSidebar);
        }
      })
      .catch(function () {
        setDownloadLinks(RELEASES_PAGE, "Download from GitHub Releases", fallbackSidebar);
      });
  }

  function initReveal() {
    var els = document.querySelectorAll(".reveal");
    if (!("IntersectionObserver" in window)) {
      els.forEach(function (el) {
        el.classList.add("is-in");
      });
      return;
    }
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            e.target.classList.add("is-in");
            io.unobserve(e.target);
          }
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.06 }
    );
    els.forEach(function (el) {
      io.observe(el);
    });
  }

  function initNavHighlight() {
    var links = document.querySelectorAll(".nav-links a[href^='#']");
    if (!links.length || !("IntersectionObserver" in window)) return;

    var sections = [];
    links.forEach(function (link) {
      var id = link.getAttribute("href").slice(1);
      var sec = document.getElementById(id);
      if (sec) sections.push({ link: link, el: sec });
    });

    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            links.forEach(function (l) {
              l.style.color = "";
            });
            var match = sections.find(function (s) {
              return s.el === e.target;
            });
            if (match) {
              match.link.style.color = "var(--color-ink)";
            }
          }
        });
      },
      { rootMargin: "-40% 0px -50% 0px", threshold: 0 }
    );

    sections.forEach(function (s) {
      io.observe(s.el);
    });
  }

  loadLatestRelease();
  initReveal();
  initNavHighlight();
})();
