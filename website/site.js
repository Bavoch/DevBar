const stage = document.querySelector("[data-stage]");
const viewControls = stage.querySelector(".view-controls");
const buttons = viewControls.querySelectorAll("[data-view]");

for (const button of buttons) {
  button.addEventListener("click", () => {
    stage.toggleAttribute("data-detail", button.dataset.view === "detail");
    for (const option of buttons) {
      option.setAttribute("aria-pressed", String(option === button));
    }
  });
}

viewControls.hidden = false;
