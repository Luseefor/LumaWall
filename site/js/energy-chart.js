export const energyData = Object.freeze([
  Object.freeze({ label: "Playing, Full quality", value: 12 }),
  Object.freeze({ label: "Playing, battery tier", value: 7 }),
  Object.freeze({ label: "Paused (covered, locked or asleep)", value: 1 }),
]);

const rowHeight = 64;
const barHeight = 24;
const barTop = 26;
let nextGradientId = 0;

export function layoutBars(data, width) {
  const max = Math.max(0, ...data.map(({ value }) => value));
  return data.map(({ label, value }, index) => ({
    label,
    value,
    x: 0,
    y: index * rowHeight + barTop,
    width: max === 0 ? 0 : (Math.max(0, value) / max) * Math.max(0, width),
    height: barHeight,
  }));
}

function svgNode(name, attributes = {}, label = "") {
  const node = document.createElementNS("http://www.w3.org/2000/svg", name);
  for (const [key, value] of Object.entries(attributes)) {
    node.setAttribute(key, value);
  }
  node.textContent = label;
  return node;
}

function buildTable() {
  const table = document.createElement("table");
  table.className = "visually-hidden";
  table.createCaption().textContent = "Approximate LumaWall power use";
  const headings = table.createTHead().insertRow();
  for (const label of ["State", "Power (mW)"]) {
    const heading = document.createElement("th");
    heading.scope = "col";
    heading.textContent = label;
    headings.append(heading);
  }

  const body = table.createTBody();
  for (const { label, value } of energyData) {
    const row = body.insertRow();
    const heading = document.createElement("th");
    heading.scope = "row";
    heading.textContent = label;
    row.append(heading);
    row.insertCell().textContent = value;
  }
  return table;
}

export function mountEnergyChart(element) {
  const figure = document.createElement("figure");
  figure.className = "energy-figure";
  const summary = energyData.map(({ label, value }) => `${label} uses about ${value} mW`).join(". ");
  const svg = svgNode("svg", {
    role: "img",
    "aria-label": `LumaWall power use. ${summary}.`,
    width: "100%",
  });
  const gradientId = `lw-energy-gradient-${++nextGradientId}`;
  const defs = svgNode("defs");
  const gradient = svgNode("linearGradient", { id: gradientId });
  gradient.append(
    svgNode("stop", { offset: "0%", class: "energy-gradient-start" }),
    svgNode("stop", { offset: "100%", class: "energy-gradient-end" }),
  );
  defs.append(gradient);
  svg.append(defs);

  const rows = layoutBars(energyData, 0).map(({ label, value, x, y, height }) => {
    const track = svgNode("rect", { x, y, height, rx: 5, class: "energy-track" });
    const bar = svgNode("rect", {
      x, y, height, rx: 5, class: "energy-bar", fill: `url(#${gradientId})`,
    });
    const amount = svgNode("text", { y: y + 16, class: "energy-value" }, `≈${value} mW`);
    svg.append(svgNode("text", { x, y: y - 8, class: "energy-label" }, label), track, bar, amount);
    return { track, bar, amount };
  });

  const axisY = rowHeight * energyData.length - 2;
  const ticks = [0, 4, 8, 12].map((value) => {
    const tick = svgNode("g");
    const label = value === 12 ? "12 mW" : String(value);
    tick.append(
      svgNode("line", { x1: 0, x2: 0, y1: axisY - 6, y2: axisY - 2, class: "energy-tick" }),
      svgNode("text", {
        y: axisY + 12,
        class: "energy-scale",
        "text-anchor": value === 0 || value === 12 ? "start" : "middle",
      }, label),
    );
    svg.append(tick);
    return tick;
  });

  const caption = document.createElement("figcaption");
  caption.textContent = "LumaWall's own processes, measured on one M-series MacBook. Your numbers will vary.";
  figure.append(svg, caption, buildTable());
  element.append(figure);

  const height = axisY + 16;
  svg.setAttribute("height", height);

  function resize() {
    const width = svg.clientWidth;
    if (width === 0) return;

    const plotWidth = Math.max(0, width - 44);
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    for (const [index, geometry] of layoutBars(energyData, plotWidth).entries()) {
      const { track, bar, amount } = rows[index];
      const fits = geometry.width >= amount.getComputedTextLength() + 16;
      track.setAttribute("width", plotWidth);
      bar.setAttribute("width", geometry.width);
      amount.setAttribute("x", fits ? 8 : geometry.width + 8);
      amount.classList.toggle("energy-value-inset", fits);
    }
    ticks.forEach((tick, index) => {
      tick.setAttribute("transform", `translate(${(index / (ticks.length - 1)) * plotWidth} 0)`);
    });
  }

  resize();
  const resizeObserver = new ResizeObserver(resize);
  resizeObserver.observe(svg);

  let intersectionObserver;
  if ("IntersectionObserver" in window && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    intersectionObserver = new IntersectionObserver((entries) => {
      if (entries.some(({ isIntersecting }) => isIntersecting)) {
        figure.classList.add("energy-visible");
        intersectionObserver.disconnect();
      }
    });
    figure.classList.add("energy-animate");
    intersectionObserver.observe(svg);
  }

  return function destroy() {
    resizeObserver.disconnect();
    intersectionObserver?.disconnect();
    figure.remove();
  };
}
