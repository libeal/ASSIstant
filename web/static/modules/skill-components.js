/** Load signed builtin Skill UI fragments and modules without core knowledge. */

/**
 * Normalize a `/api/skill-components` finding into the shape the Skill 库
 * warning strip renders. The backend reports manifest-level rejections; the
 * loader itself reports registration failures.
 * @param {Record<string, any>} finding
 * @returns {{component: string, severity: string, stage: string, code: string, message: string}}
 */
export function normalizeComponentFinding(finding) {
  const source = finding && typeof finding === "object" ? finding : {};
  return {
    component: String(source.skill || source.component || source.code || "unknown"),
    severity: source.severity === "error" ? "error" : "warning",
    stage: "manifest",
    code: String(source.code || ""),
    message: String(source.message || "Skill Web 组件被拒绝加载。"),
  };
}

/**
 * @param {string} component
 * @param {unknown} error
 * @returns {{component: string, severity: string, stage: string, code: string, message: string}}
 */
export function normalizeRegistrationFailure(component, error) {
  return {
    component: String(component || "unknown"),
    severity: "error",
    stage: "register",
    code: "SKILL_WEB_COMPONENT_REGISTER_FAILED",
    message: error instanceof Error ? error.message : String(error ?? "组件注册失败。"),
  };
}

/** @param {Record<string, any>} app @returns {{loadSkillWebComponents: Function}} */
export function createSkillComponentLoader(app) {
  const registered = new Map();

  function installNavigation(component) {
    const navigation = component.navigation || {};
    const screen = String(navigation.screen || "");
    const nav = document.getElementById("nav");
    if (!nav || !screen || nav.querySelector(`[data-screen="${CSS.escape(screen)}"]`)) return;
    const button = document.createElement("button");
    button.type = "button";
    button.dataset.screen = screen;
    button.dataset.key = String(navigation.key || "");
    button.dataset.order = String(navigation.order || 500);
    const icon = document.createElement("span");
    icon.className = "icon";
    icon.setAttribute("aria-hidden", "true");
    icon.textContent = String(navigation.icon || "◇");
    const label = document.createElement("span");
    label.className = "label";
    label.textContent = String(navigation.label || screen);
    const key = document.createElement("span");
    key.className = "key";
    key.setAttribute("aria-hidden", "true");
    key.textContent = String(navigation.key || "");
    button.append(icon, label, key);
    const order = Number(navigation.order || 500);
    const following = [...nav.querySelectorAll("button[data-order]")].find(
      (item) => item instanceof HTMLElement && Number(item.dataset.order || 0) > order,
    );
    nav.insertBefore(button, following || null);
    app.titles[screen] = String(navigation.label || screen);
  }

  async function installFragment(component) {
    const screen = String(component.navigation?.screen || "");
    if (document.getElementById(`screen-${screen}`)) return;
    const response = await fetch(component.fragment_url, { cache: "no-store" });
    if (!response.ok) throw new Error(`Skill Web fragment unavailable: ${component.name}`);
    const template = document.createElement("template");
    template.innerHTML = await response.text();
    const section = template.content.firstElementChild;
    if (!(section instanceof HTMLElement) || section.id !== `screen-${screen}`) {
      throw new Error(`Skill Web fragment screen mismatch: ${component.name}`);
    }
    const anchor = document.getElementById("screen-policy");
    if (!anchor?.parentElement) throw new Error("Skill Web fragment anchor is unavailable");
    anchor.parentElement.insertBefore(section, anchor);
  }

  async function register(component) {
    if (registered.has(component.name)) return registered.get(component.name);
    await installFragment(component);
    installNavigation(component);
    const module = await import(component.frontend_url);
    if (typeof module.registerSkillWebComponent !== "function") {
      throw new Error(`Skill Web module has no registration function: ${component.name}`);
    }
    const lifecycle = module.registerSkillWebComponent(app) || {};
    registered.set(component.name, lifecycle);
    return lifecycle;
  }

  async function loadSkillWebComponents() {
    const result = await app.api("/api/skill-components");
    const components = Array.isArray(result.components) ? result.components : [];
    // Rebuilt from scratch on every load so repeated reloads replace the
    // previous verdict instead of accumulating duplicate warnings.
    const findings = (Array.isArray(result.findings) ? result.findings : []).map(normalizeComponentFinding);
    for (const component of components) {
      try {
        const lifecycle = await register(component);
        if (typeof lifecycle.onConnect === "function") await lifecycle.onConnect();
      } catch (error) {
        console.error("Skill Web component registration failed", component.name, error);
        findings.push(normalizeRegistrationFailure(component.name, error));
      }
    }
    app.state.skillComponentFindings = findings;
    if (typeof app.renderSkillComponentFindings === "function") app.renderSkillComponentFindings();
    return result;
  }

  return { loadSkillWebComponents };
}
