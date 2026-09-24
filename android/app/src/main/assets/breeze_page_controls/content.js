(() => {
  "use strict";

  const STYLE_ID = "__breeze_page_controls_rules";
  const PICKER_ID = "__breeze_page_controls_picker";
  const HOST_PATTERN = /^[a-z0-9.-]{1,253}$/;
  const SELECTOR_PATTERN = /^[a-z][a-z0-9-]{0,63}(?::nth-of-type\([1-9][0-9]{0,4}\))?(>[a-z][a-z0-9-]{0,63}(?::nth-of-type\([1-9][0-9]{0,4}\))?){0,32}$/;

  let hiddenSelectors = [];
  let originalZoom = null;
  let picker = null;
  let activeCandidate = null;
  let highlight = null;
  const PIP_STYLE_ID = "__breeze_pip_video";
  const PIP_FRAME_CLASS = "__breeze_pip_frame";
  let pipVideo = null;
  let pipFrame = null;
  let lastVideo = null;
  let pipAncestors = [];
  let pipScroll = null;
  let lastVideoState = "";
  let lastVideoScanAt = 0;

  function postVideoState(state) {
    const encoded = JSON.stringify(state);
    if (encoded === lastVideoState) return;
    lastVideoState = encoded;
    try { port.postMessage(state); } catch (_) { /* The page/session has disconnected. */ }
  }

  function activeVideo() {
    return [...document.querySelectorAll("video")]
      .filter((video) => !video.paused && !video.ended)
      .map((video) => ({ video, rect: video.getBoundingClientRect() }))
      .filter(({ rect }) => rect.width > 0 && rect.height > 0)
      .sort((a, b) => (b.rect.width * b.rect.height) - (a.rect.width * a.rect.height))[0]?.video ?? null;
  }

  function sameDocument(a, b) {
    try {
      const left = new URL(a, location.href);
      const right = new URL(b, location.href);
      return left.origin === right.origin && left.pathname === right.pathname;
    } catch (_) {
      return false;
    }
  }

  function sendVideoPlaybackState() {
    const video = activeVideo() || (pipVideo?.isConnected ? pipVideo : null) || (lastVideo?.isConnected ? lastVideo : null);
    if (!video) {
      postVideoState({ type: "videoPlayback", playing: false });
      return;
    }
    lastVideo = video;
    const rect = video.getBoundingClientRect();
    postVideoState({
      type: "videoPlayback", playing: !video.paused && !video.ended,
      videoWidth: video.videoWidth || Math.round(rect.width),
      videoHeight: video.videoHeight || Math.round(rect.height),
      frameUrl: location.href,
      left: rect.left, top: rect.top, width: rect.width, height: rect.height,
      viewportWidth: window.innerWidth, viewportHeight: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio || 1
    });
  }

  function setPipVideoMode(enabled, targetFrameUrl) {
    if (!enabled) {
      document.getElementById(PIP_STYLE_ID)?.remove();
      pipVideo?.classList.remove("__breeze_pip_focus");
      pipFrame?.classList.remove(PIP_FRAME_CLASS);
      pipAncestors.forEach((element) => element.classList.remove("__breeze_pip_ancestor"));
      pipAncestors = [];
      pipVideo = null;
      pipFrame = null;
      if (pipScroll) window.scrollTo(pipScroll.x, pipScroll.y);
      pipScroll = null;
      sendVideoPlaybackState();
      return;
    }
    // Preserve the same media element and source. Moving/recreating YouTube's video interrupts playback.
    const targetUrl = targetFrameUrl || location.href;
    if (sameDocument(location.href, targetUrl)) {
      pipVideo = activeVideo() || (lastVideo?.isConnected ? lastVideo : null);
      pipVideo?.classList.add("__breeze_pip_focus");
    } else {
      pipFrame = [...document.querySelectorAll("iframe")].find((frame) => sameDocument(frame.src, targetUrl)) ?? null;
      pipFrame?.classList.add(PIP_FRAME_CLASS);
    }
    const target = pipVideo || pipFrame;
    if (!target) return;
    if (!pipScroll) pipScroll = { x: window.scrollX, y: window.scrollY };
    // Fixed descendants can otherwise be trapped by transformed/clipped player ancestors.
    for (let parent = target.parentElement; parent; parent = parent.parentElement) {
      if (!pipAncestors.includes(parent)) pipAncestors.push(parent);
      parent.classList.add("__breeze_pip_ancestor");
    }
    let style = document.getElementById(PIP_STYLE_ID);
    if (!style) {
      style = document.createElement("style");
      style.id = PIP_STYLE_ID;
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = `
      html, body { background:#000 !important; margin:0 !important; padding:0 !important; width:100% !important; height:100% !important; overflow:hidden !important; zoom:1 !important; }
      * { visibility:hidden !important; }
      .__breeze_pip_ancestor { display:block !important; position:static !important; transform:none !important; translate:none !important; rotate:none !important; scale:none !important; perspective:none !important; filter:none !important; backdrop-filter:none !important; contain:none !important; content-visibility:visible !important; clip:auto !important; clip-path:none !important; overflow:visible !important; opacity:1 !important; mask:none !important; will-change:auto !important; }
      video.__breeze_pip_focus, iframe.__breeze_pip_frame { visibility:visible !important; display:block !important; position:fixed !important; inset:0 !important; margin:0 !important; padding:0 !important; width:100vw !important; height:100vh !important; min-width:0 !important; min-height:0 !important; max-width:none !important; max-height:none !important; transform:none !important; translate:none !important; rotate:none !important; scale:none !important; clip:auto !important; clip-path:none !important; border:0 !important; border-radius:0 !important; opacity:1 !important; object-fit:contain !important; background:#000 !important; z-index:2147483647 !important; }
    `;
    window.scrollTo(0, 0);
    sendVideoPlaybackState();
  }

  document.addEventListener("playing", (event) => {
    if (event.target instanceof HTMLVideoElement) sendVideoPlaybackState();
  }, true);
  document.addEventListener("play", (event) => {
    if (event.target instanceof HTMLVideoElement) sendVideoPlaybackState();
  }, true);
  document.addEventListener("pause", (event) => {
    if (event.target instanceof HTMLVideoElement) queueMicrotask(sendVideoPlaybackState);
  }, true);
  document.addEventListener("ended", (event) => {
    if (event.target instanceof HTMLVideoElement) queueMicrotask(sendVideoPlaybackState);
  }, true);
  document.addEventListener("loadedmetadata", (event) => {
    if (event.target instanceof HTMLVideoElement && !event.target.paused) sendVideoPlaybackState();
  }, true);
  document.addEventListener("loadeddata", (event) => {
    if (event.target instanceof HTMLVideoElement && !event.target.paused) sendVideoPlaybackState();
  }, true);
  document.addEventListener("canplay", (event) => {
    if (event.target instanceof HTMLVideoElement && !event.target.paused) sendVideoPlaybackState();
  }, true);
  document.addEventListener("timeupdate", (event) => {
    if (event.target instanceof HTMLVideoElement && !event.target.paused) {
      const now = performance.now();
      if (now - lastVideoScanAt >= 1000) {
        lastVideoScanAt = now;
        sendVideoPlaybackState();
      }
    }
  }, true);

  function validSelector(value) {
    return typeof value === "string" && value.length <= 512 && SELECTOR_PATTERN.test(value);
  }

  function applyRules() {
    let style = document.getElementById(STYLE_ID);
    if (!style) {
      style = document.createElement("style");
      style.id = STYLE_ID;
      (document.documentElement || document.head || document.body).appendChild(style);
    }
    style.textContent = hiddenSelectors
      .filter(validSelector)
      .map((selector) => `${selector}{display:none!important;visibility:hidden!important}`)
      .join("\n");
  }

  function applyPageZoom(value) {
    const root = document.documentElement;
    if (!root) return;
    const percent = Number.isInteger(value) && value >= 50 && value <= 200 ? value : 100;
    if (percent === 100) {
      if (originalZoom !== null) {
        if (originalZoom.value) root.style.setProperty("zoom", originalZoom.value, originalZoom.priority);
        else root.style.removeProperty("zoom");
        originalZoom = null;
      }
      return;
    }
    if (originalZoom === null) {
      originalZoom = {
        value: root.style.getPropertyValue("zoom"),
        priority: root.style.getPropertyPriority("zoom")
      };
    }
    root.style.setProperty("zoom", `${percent}%`, "important");
  }

  function selectorFor(element) {
    if (!(element instanceof Element) || element === document.documentElement || element === document.body) return null;
    const parts = [];
    let node = element;
    while (node && node instanceof Element && node !== document.documentElement.parentElement) {
      if (node.id === PICKER_ID || node.closest(`#${PICKER_ID}`)) return null;
      const tag = node.localName;
      if (!/^[a-z][a-z0-9-]{0,63}$/.test(tag)) return null;
      const parent = node.parentElement;
      let part = tag;
      if (parent) {
        let position = 0;
        for (const sibling of parent.children) {
          if (sibling.localName === tag) position++;
          if (sibling === node) break;
        }
        if (position > 0) part += `:nth-of-type(${position})`;
      }
      parts.unshift(part);
      if (node === document.body) break;
      node = parent;
    }
    const selector = parts.join(">");
    return validSelector(selector) ? selector : null;
  }

  function candidateFor(target) {
    if (!(target instanceof Element) || target.closest(`#${PICKER_ID}`)) return null;
    let node = target;
    let fallback = target;
    while (node && node !== document.body && node !== document.documentElement) {
      const rect = node.getBoundingClientRect();
      if (rect.width >= window.innerWidth * 0.48 && rect.height >= 34 && rect.height <= window.innerHeight * 0.48) fallback = node;
      else if (fallback !== target) break;
      node = node.parentElement;
    }
    return fallback;
  }

  function setHighlight(element) {
    activeCandidate = element;
    if (!highlight) {
      highlight = document.createElement("div");
      highlight.setAttribute("aria-hidden", "true");
      Object.assign(highlight.style, {
        position: "fixed", pointerEvents: "none", zIndex: "2147483646",
        border: "2px solid #22c7bd", borderRadius: "5px",
        background: "rgba(34,199,189,.12)", boxSizing: "border-box"
      });
      document.documentElement.appendChild(highlight);
    }
    const rect = element.getBoundingClientRect();
    Object.assign(highlight.style, {
      left: `${Math.max(0, rect.left)}px`, top: `${Math.max(0, rect.top)}px`,
      width: `${Math.max(1, rect.width)}px`, height: `${Math.max(1, rect.height)}px`, display: "block"
    });
  }

  function stopPicker() {
    if (picker) picker.remove();
    picker = null;
    activeCandidate = null;
    if (highlight) highlight.remove();
    highlight = null;
    document.removeEventListener("pointerover", onPointerOver, true);
    document.removeEventListener("pointermove", onPointerMove, true);
    document.removeEventListener("click", onPickClick, true);
  }

  function onPointerOver(event) {
    const next = candidateFor(event.target);
    if (next) setHighlight(next);
  }

  function onPointerMove() {
    if (activeCandidate && activeCandidate.isConnected) setHighlight(activeCandidate);
  }

  function onPickClick(event) {
    const path = typeof event.composedPath === "function" ? event.composedPath() : [];
    if (picker && path.includes(picker)) return;
    const element = candidateFor(event.target);
    if (!element) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    event.stopPropagation();
    const selector = selectorFor(element);
    stopPicker();
    if (selector) port.postMessage({ type: "selected", host: location.hostname.toLowerCase(), selector });
    else port.postMessage({ type: "pickerError", reason: "unsupported" });
  }

  function startPicker() {
    stopPicker();
    const root = document.documentElement;
    if (!root) return;
    picker = document.createElement("div");
    picker.id = PICKER_ID;
    picker.attachShadow({ mode: "open" });
    picker.shadowRoot.innerHTML = `
      <style>
        :host{all:initial;position:fixed;z-index:2147483647;left:50%;top:calc(env(safe-area-inset-top,0px) + 12px);transform:translateX(-50%);font:500 14px/1.2 system-ui,sans-serif;color:#f6ffff}
        .bar{display:flex;align-items:center;gap:14px;padding:11px 13px 11px 16px;border:1px solid rgba(108,245,232,.72);border-radius:22px;background:rgba(5,12,15,.96);box-shadow:0 4px 22px rgba(0,0,0,.45),0 0 18px rgba(34,199,189,.28);white-space:nowrap}
        button{font:600 14px system-ui,sans-serif;color:#101719;background:#77eee3;border:0;border-radius:16px;min-height:34px;padding:0 14px}
      </style>
      <div class="bar"><span>Tap an ad or banner to hide it</span><button type="button">Cancel</button></div>`;
    picker.shadowRoot.querySelector("button").addEventListener("click", (event) => {
      event.preventDefault(); event.stopPropagation(); stopPicker();
      port.postMessage({ type: "pickerCancelled" });
    });
    root.appendChild(picker);
    document.addEventListener("pointerover", onPointerOver, true);
    document.addEventListener("pointermove", onPointerMove, true);
    document.addEventListener("click", onPickClick, true);
  }

  const port = browser.runtime.connectNative("breeze.pageControls");
  port.onMessage.addListener((message) => {
    if (!message || typeof message !== "object") return;
    if (message.type === "sync") {
      const host = String(message.host || "").toLowerCase();
      hiddenSelectors = host === location.hostname.toLowerCase() && HOST_PATTERN.test(host) && Array.isArray(message.selectors)
        ? message.selectors.filter(validSelector).slice(0, 30)
        : [];
      applyRules();
      applyPageZoom(message.zoomPercent);
      if (message.pick === true) startPicker();
    } else if (message.type === "pick") {
      startPicker();
    } else if (message.type === "apply") {
      const host = String(message.host || "").toLowerCase();
      if (host !== location.hostname.toLowerCase() || !Array.isArray(message.selectors)) return;
      hiddenSelectors = message.selectors.filter(validSelector).slice(0, 30);
      applyRules();
      applyPageZoom(message.zoomPercent);
    } else if (message.type === "cancelPick") {
      stopPicker();
    } else if (message.type === "pipVideo") {
      setPipVideoMode(message.enabled === true, String(message.frameUrl || ""));
    } else if (message.type === "pipPlayback" && sameDocument(location.href, String(message.frameUrl || ""))) {
      const video = pipVideo || activeVideo() || (lastVideo?.isConnected ? lastVideo : null);
      if (!video) return;
      if (message.play === true) video.play().then(sendVideoPlaybackState).catch(() => sendVideoPlaybackState());
      else { video.pause(); sendVideoPlaybackState(); }
    }
  });
  port.onDisconnect.addListener(() => { stopPicker(); setPipVideoMode(false, ""); });
  port.postMessage({ type: "ready", host: location.hostname.toLowerCase(), topLevel: window.top === window });
  setTimeout(sendVideoPlaybackState, 0);
})();
