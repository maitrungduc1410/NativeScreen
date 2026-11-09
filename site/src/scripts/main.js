// Small enhancements only: the page reads fine without this file.
(() => {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Demo videos play only while on screen. With Reduce Motion they wait for the viewer to press play.
  const autoVideos = [...document.querySelectorAll("video[data-autoplay], video[data-ratio-video]")];
  if (reduceMotion) {
    autoVideos.forEach((v) => { v.removeAttribute("autoplay"); v.pause(); v.controls = true; v.preload = "metadata"; });
  } else if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        const v = e.target;
        if (e.isIntersecting && !v.hidden) v.play().catch(() => {}); else v.pause();
      });
    }, { threshold: 0.35 });
    autoVideos.forEach((v) => io.observe(v));
  }

  // Radio-like button groups: click and arrow keys.
  function radioGroup(group, onChange) {
    const buttons = [...group.querySelectorAll('[role="radio"]')];
    const select = (button, focus) => {
      buttons.forEach((b) => {
        const on = b === button;
        b.setAttribute("aria-checked", String(on));
        b.tabIndex = on ? 0 : -1;
      });
      if (focus) button.focus();
      onChange(button);
    };
    buttons.forEach((b, i) => {
      b.tabIndex = b.getAttribute("aria-checked") === "true" ? 0 : -1;
      b.addEventListener("click", () => select(b, false));
      b.addEventListener("keydown", (e) => {
        const step = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 0;
        if (!step) return;
        e.preventDefault();
        select(buttons[(i + step + buttons.length) % buttons.length], true);
      });
    });
    return (value, attr) => {
      const b = buttons.find((x) => x.getAttribute(attr) === value);
      if (b) {
        buttons.forEach((x) => { x.setAttribute("aria-checked", String(x === b)); x.tabIndex = x === b ? 0 : -1; });
      }
    };
  }

  // Theme: Auto follows the system; Light and Dark are remembered on this device.
  const themeGroup = document.querySelector(".theme-switch");
  if (themeGroup) {
    const mark = radioGroup(themeGroup, (b) => {
      const choice = b.dataset.themeChoice;
      if (choice === "system") delete document.documentElement.dataset.theme;
      else document.documentElement.dataset.theme = choice;
      try { choice === "system" ? localStorage.removeItem("ns-theme") : localStorage.setItem("ns-theme", choice); } catch (e) {}
    });
    mark(document.documentElement.dataset.theme || "system", "data-theme-choice");
  }

  // Language menu: a click is an explicit choice, so the automatic redirect stops applying.
  document.querySelectorAll("[data-lang-link]").forEach((link) => {
    link.addEventListener("click", () => {
      try { localStorage.setItem("ns-lang", link.dataset.langLink); } catch (e) {}
    });
  });
  const langMenu = document.querySelector(".lang-menu");
  if (langMenu) {
    document.addEventListener("click", (e) => { if (!langMenu.contains(e.target)) langMenu.open = false; });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") langMenu.open = false; });
  }

  // Primary download button matches the visitor's system.
  const isWindows = /Windows/i.test(navigator.userAgent);
  if (isWindows) {
    const primary = document.querySelector("[data-download]");
    const alt = document.querySelector("[data-download-alt]");
    if (primary && alt) {
      [primary.href, alt.href] = [alt.href, primary.href];
      primary.textContent = primary.dataset.windowsLabel;
      alt.textContent = "macOS";
    }
  }

  // Before / after switches: one large video, the buttons pick which take plays, at the same moment.
  document.querySelectorAll(".swap[data-swap-for]").forEach((group) => {
    const frame = document.getElementById(group.dataset.swapFor);
    if (!frame) return;
    const videos = [...frame.querySelectorAll("video[data-swap-video]")];
    radioGroup(group, (b) => {
      const t = videos.find((v) => !v.hidden)?.currentTime || 0;
      videos.forEach((v) => {
        const on = v.dataset.swapVideo === b.dataset.swap;
        v.hidden = !on;
        if (on) {
          // A take that has not loaded yet ignores the seek, so it waits for its metadata.
          const seek = () => { try { v.currentTime = t; } catch (e) {} };
          if (v.readyState >= 1) seek(); else v.addEventListener("loadedmetadata", seek, { once: true });
          if (!reduceMotion) v.play().catch(() => {});
        } else v.pause();
      });
    });
  });

  // Aspect ratio switcher.
  const ratioGroup = document.querySelector("[data-ratio-group]");
  const frame = document.getElementById("ratio-frame");
  if (ratioGroup && frame) {
    const stage = frame.parentElement;
    let current = "16 / 9";
    // Fits the shape inside the stage with explicit sizes, so width and height can animate.
    const apply = (ratio) => {
      current = ratio;
      const [w, h] = ratio.split("/").map(Number);
      const maxW = stage.clientWidth, maxH = stage.clientHeight;
      const width = Math.min(maxW, maxH * (w / h));
      frame.style.aspectRatio = "auto";
      frame.style.width = `${width}px`;
      frame.style.height = `${width * (h / w)}px`;
    };
    apply(current);
    new ResizeObserver(() => apply(current)).observe(stage);
    const videos = [...frame.querySelectorAll("video[data-ratio-video]")];
    radioGroup(ratioGroup, (b) => {
      const t = videos.find((v) => !v.hidden)?.currentTime || 0;
      apply(b.dataset.ratio);
      videos.forEach((v) => {
        const on = v.dataset.ratioVideo === b.dataset.ratio;
        v.hidden = !on;
        if (on) {
          // A take that has not loaded yet ignores the seek, so it waits for its metadata.
          const seek = () => { try { v.currentTime = t; } catch (e) {} };
          if (v.readyState >= 1) seek(); else v.addEventListener("loadedmetadata", seek, { once: true });
          if (!reduceMotion) v.play().catch(() => {});
        } else v.pause();
      });
    });
  }

})();
