import { $, showToast } from "./dom.js";
import { LAYOUT_STORAGE_PREFIX, SIDEBAR_STORAGE_KEY } from "./constants.js";

/** @param {Element} element @returns {element is HTMLElement} */
function isHtmlElement(element) {
  return element instanceof HTMLElement;
}

/** @param {ParentNode} root @param {string} selector @returns {HTMLElement[]} */
function queryHtmlElements(root, selector) {
  return [...root.querySelectorAll(selector)].filter(isHtmlElement);
}

/** @param {Event} event @returns {Element|null} */
function eventTargetElement(event) {
  return event.target instanceof Element ? event.target : null;
}

function setSidebarCollapsed(collapsed, persist = true) {
  const app = document.querySelector(".app");
  const toggle = $("sidebarToggle");
  if (!app || !toggle) return;
  const next = Boolean(collapsed);
  app.classList.toggle("sidebar-collapsed", next);
  toggle.setAttribute("aria-expanded", next ? "false" : "true");
  toggle.setAttribute("aria-label", next ? "展开主侧栏" : "收起主侧栏");
  toggle.title = next ? "展开主侧栏" : "收起主侧栏";
  const icon = toggle.querySelector(".sidebar-toggle-icon");
  if (icon) icon.textContent = next ? "›" : "‹";
  if (persist) {
    try {
      localStorage.setItem(SIDEBAR_STORAGE_KEY, next ? "1" : "0");
    } catch {
      // localStorage 受限时仍保留本次页面内的交互状态。
    }
  }
}

/** @returns {void} */
export function initSidebarToggle() {
  const toggle = $("sidebarToggle");
  if (!toggle) return;
  let collapsed = false;
  try {
    collapsed = localStorage.getItem(SIDEBAR_STORAGE_KEY) === "1";
  } catch {
    collapsed = false;
  }
  setSidebarCollapsed(collapsed, false);
  toggle.addEventListener("click", () => setSidebarCollapsed(!document.querySelector(".app")?.classList.contains("sidebar-collapsed")));
}

/**
 * Build the per-process panel layout controller around the shared app state.
 * @param {import("./types.js").AppState} state
 * @returns {{initPanelLayout: () => void, setLayoutRunId: (runId: string) => void, bindPanelDrag: () => void}}
 */
export function createLayoutController(state) {
  function currentLayoutStorageKey() {
    return state.layoutStorageKey || "";
  }

  function readCurrentLayout() {
    const containers = {};
    const children = {};
    queryHtmlElements(document, "[data-layout-container]").forEach((container) => {
      const containerId = container.dataset.layoutContainer;
      const childElements = [...container.children].filter(isHtmlElement);
      containers[containerId] = childElements
        .filter((child) => child.dataset?.layoutPanel)
        .map((child) => child.dataset.layoutPanel);
      children[containerId] = childElements
        .map(layoutChildToken)
        .filter(Boolean);
    });
    return { containers, children };
  }

  function loadSavedLayout() {
    const key = currentLayoutStorageKey();
    if (!key) return {};
    try {
      return JSON.parse(localStorage.getItem(key) || "{}");
    } catch {
      return {};
    }
  }

  function saveLayout() {
    const key = currentLayoutStorageKey();
    if (!key) return false;
    localStorage.setItem(key, JSON.stringify(readCurrentLayout()));
    return true;
  }

  function initPanelLayout() {
    let panelIndex = 0;
    queryHtmlElements(document, ".screen").forEach((screen) => {
      const containers = [screen, ...queryHtmlElements(screen, ".stack, .split, .split-wide")]
        .filter((container) => hasDirectLayoutPanel(container));
      containers.forEach((container, index) => {
        container.dataset.layoutContainer = `${screen.id}:container-${index}`;
        container.classList.add("layout-container");
        let staticIndex = 0;
        getDirectLayoutPanels(container).forEach((panel) => {
          if (!panel.dataset.layoutPanel) {
            panel.dataset.layoutPanel = `${screen.id}:panel-${panelIndex}`;
            panelIndex += 1;
          }
          panel.classList.add("layout-panel");
          addDragHandle(panel);
        });
        [...container.children].filter(isHtmlElement).forEach((child) => {
          if (child.dataset.layoutPanel || child.dataset.layoutStatic) return;
          child.dataset.layoutStatic = `${container.dataset.layoutContainer}:static-${staticIndex}`;
          staticIndex += 1;
        });
      });
    });
    state.defaultLayout = readCurrentLayout();
  }

  function hasDirectLayoutPanel(container) {
    return getDirectLayoutPanels(container).length > 0;
  }

  function getDirectLayoutPanels(container) {
    return [...container.children].filter((child) => child.classList?.contains("panel") || child.classList?.contains("terminal"));
  }

  function addDragHandle(panel) {
    const header = panel.querySelector(":scope > .panel-header, :scope > .terminal-head");
    if (!header || header.querySelector(":scope > .drag-handle")) return;
    const handle = document.createElement("span");
    handle.className = "drag-handle";
    handle.draggable = true;
    handle.setAttribute("role", "button");
    handle.setAttribute("tabindex", "0");
    handle.setAttribute("aria-label", "拖动调整窗口位置");
    handle.setAttribute("title", "拖动调整窗口位置");
    handle.textContent = "⠿";
    header.appendChild(handle);
  }

  function layoutChildToken(child) {
    if (child.dataset?.layoutPanel) return `panel:${child.dataset.layoutPanel}`;
    if (child.dataset?.layoutStatic) return `static:${child.dataset.layoutStatic}`;
    return "";
  }

  function applyPanelLayout(layout) {
    const containers = layout.containers || layout;
    const children = layout.children || {};
    for (const [containerId, childTokens] of Object.entries(children)) {
      const container = findLayoutContainer(containerId);
      if (!container || !Array.isArray(childTokens)) continue;
      applyContainerChildLayout(container, childTokens);
    }
    for (const [containerId, panelIds] of Object.entries(containers)) {
      if (children[containerId]) continue;
      const container = findLayoutContainer(containerId);
      if (!container || !Array.isArray(panelIds)) continue;
      applyContainerPanelLayout(container, panelIds);
    }
  }

  function applyContainerChildLayout(container, childTokens) {
    for (const token of childTokens) {
      const child = findLayoutChild(token);
      if (child && child.closest(".screen") === container.closest(".screen")) {
        container.appendChild(child);
      }
    }
  }

  function applyContainerPanelLayout(container, panelIds) {
    const anchor = findPanelBlockAnchor(container);
    for (const panelId of panelIds) {
      const panel = findLayoutPanel(panelId);
      if (panel && panel.closest(".screen") === container.closest(".screen")) {
        if (anchor && anchor.parentElement === container) container.insertBefore(panel, anchor);
        else container.appendChild(panel);
      }
    }
  }

  function findPanelBlockAnchor(container) {
    const children = [...container.children];
    const firstPanelIndex = children.findIndex((child) => child.dataset?.layoutPanel);
    if (firstPanelIndex < 0) return null;
    return children.slice(firstPanelIndex).find((child) => !child.dataset?.layoutPanel) || null;
  }

  function applySavedLayout() {
    const saved = loadSavedLayout();
    applyPanelLayout(state.defaultLayout);
    if (saved.containers) applyPanelLayout(saved);
  }

  function setLayoutRunId(runId) {
    if (!runId) {
      state.webRunId = "";
      state.layoutStorageKey = "";
      applyPanelLayout(state.defaultLayout);
      return;
    }
    const nextRunId = String(runId);
    const nextKey = `${LAYOUT_STORAGE_PREFIX}:${nextRunId}`;
    if (state.layoutStorageKey === nextKey) return;
    state.webRunId = nextRunId;
    state.layoutStorageKey = nextKey;
    applySavedLayout();
  }

  function bindPanelDrag() {
    document.addEventListener("dragstart", (event) => {
      const handle = eventTargetElement(event)?.closest(".drag-handle");
      if (!handle) return;
      const panel = handle.closest("[data-layout-panel]");
      if (!(panel instanceof HTMLElement) || !event.dataTransfer) return;
      state.draggedPanelId = panel.dataset.layoutPanel || "";
      panel.classList.add("layout-dragging");
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", state.draggedPanelId);
    });

    document.addEventListener("dragover", (event) => {
      const container = eventTargetElement(event)?.closest("[data-layout-container]");
      const panel = getDraggedPanel();
      if (!container || !panel || container.closest(".screen") !== panel.closest(".screen")) return;
      event.preventDefault();
      container.classList.add("layout-drop-active");
      const after = getDragAfterElement(container, event.clientY);
      if (after) container.insertBefore(panel, after);
      else container.appendChild(panel);
    });

    document.addEventListener("dragleave", (event) => {
      const container = eventTargetElement(event)?.closest("[data-layout-container]");
      const relatedNode = event.relatedTarget instanceof Node ? event.relatedTarget : null;
      if (container && !container.contains(relatedNode)) {
        container.classList.remove("layout-drop-active");
      }
    });

    document.addEventListener("drop", (event) => {
      const container = eventTargetElement(event)?.closest("[data-layout-container]");
      const panel = getDraggedPanel();
      if (!container || !panel || container.closest(".screen") !== panel.closest(".screen")) return;
      event.preventDefault();
      container.classList.remove("layout-drop-active");
      panel.classList.remove("layout-dragging");
      state.draggedPanelId = "";
      showToast(saveLayout() ? "布局已保存于本次进程" : "连接后可保存布局");
    });

    document.addEventListener("dragend", () => {
      document.querySelectorAll(".layout-dragging").forEach((panel) => panel.classList.remove("layout-dragging"));
      document.querySelectorAll(".layout-drop-active").forEach((container) => container.classList.remove("layout-drop-active"));
      if (state.draggedPanelId) saveLayout();
      state.draggedPanelId = "";
    });
  }

  function getDraggedPanel() {
    if (!state.draggedPanelId) return null;
    return findLayoutPanel(state.draggedPanelId);
  }

  function findLayoutContainer(id) {
    return queryHtmlElements(document, "[data-layout-container]").find((container) => container.dataset.layoutContainer === id) || null;
  }

  function findLayoutPanel(id) {
    return queryHtmlElements(document, "[data-layout-panel]").find((panel) => panel.dataset.layoutPanel === id) || null;
  }

  function findLayoutStatic(id) {
    return queryHtmlElements(document, "[data-layout-static]").find((child) => child.dataset.layoutStatic === id) || null;
  }

  function findLayoutChild(token) {
    if (!token.includes(":")) return null;
    const separator = token.indexOf(":");
    const type = token.slice(0, separator);
    const id = token.slice(separator + 1);
    if (type === "panel") return findLayoutPanel(id);
    if (type === "static") return findLayoutStatic(id);
    return null;
  }

  function getDragAfterElement(container, y) {
    const elements = [...container.children].filter((child) => child.dataset?.layoutPanel && !child.classList.contains("layout-dragging"));
    return elements.reduce((closest, child) => {
      const box = child.getBoundingClientRect();
      const offset = y - box.top - box.height / 2;
      if (offset < 0 && offset > closest.offset) {
        return { offset, element: child };
      }
      return closest;
    }, { offset: Number.NEGATIVE_INFINITY, element: null }).element;
  }

  return { initPanelLayout, setLayoutRunId, bindPanelDrag };
}
