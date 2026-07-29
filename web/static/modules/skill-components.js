/** Load signed builtin Skill UI fragments and modules without core knowledge. */

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
    for (const finding of Array.isArray(result.findings) ? result.findings : []) {
      console.warn("Skill Web component disabled", finding);
    }
    for (const component of components) {
      try {
        const lifecycle = await register(component);
        if (typeof lifecycle.onConnect === "function") await lifecycle.onConnect();
      } catch (error) {
        console.error("Skill Web component registration failed", component.name, error);
      }
    }
    return result;
  }

  return { loadSkillWebComponents };
}
