// Visionary feature deck
const pptxgen = require("pptxgenjs");
const React = require("react");
const ReactDOMServer = require("react-dom/server");
const sharp = require("sharp");
const Fi = require("react-icons/fi");

// palette — "night optics": near-black indigo, ice blue, amber accent
const BG = "12141F";      // dark base
const CARD = "1C2030";    // card tint
const ICE = "CADCFC";     // secondary text
const WHITE = "FFFFFF";
const AMBER = "F5A623";   // accent
const MUTED = "8A93B2";

async function icon(name, color, px = 256) {
  const el = React.createElement(Fi[name], { color: "#" + color, size: px, strokeWidth: 2 });
  const svg = ReactDOMServer.renderToStaticMarkup(el);
  const buf = await sharp(Buffer.from(svg)).resize(px, px).png().toBuffer();
  return "image/png;base64," + buf.toString("base64");
}

(async () => {
  const icons = {};
  const need = [
    ["FiBookOpen", BG], ["FiEye", BG], ["FiGlobe", BG], ["FiWifiOff", BG],
    ["FiVolume2", BG], ["FiPower", BG], ["FiMic", BG], ["FiMessageCircle", BG],
    ["FiFileText", BG], ["FiRepeat", BG], ["FiCamera", WHITE], ["FiCpu", WHITE],
    ["FiSpeaker", WHITE], ["FiShield", BG], ["FiSearch", BG], ["FiZap", BG],
    ["FiNavigation", BG], ["FiCalendar", BG], ["FiUsers", BG], ["FiSmartphone", BG],
    ["FiWifi", WHITE],
  ];
  for (const [n, c] of need) icons[n + c] = await icon(n, c);

  const p = new pptxgen();
  p.layout = "LAYOUT_WIDE";
  const W = 13.33, H = 7.5;

  const base = (s) => { s.background = { color: BG }; };

  const chip = (s, x, y, w, txt) => {
    s.addShape("roundRect", { x, y, w, h: 0.5, rectRadius: 0.25, fill: { color: CARD }, line: { color: "2A3048", width: 1 } });
    s.addText(txt, { x, y, w, h: 0.5, align: "center", fontFace: "Calibri", fontSize: 13, bold: true, color: AMBER, margin: 0 });
  };

  const circleIcon = (s, x, y, d, key, bg = AMBER) => {
    s.addShape("ellipse", { x, y, w: d, h: d, fill: { color: bg } });
    const pad = d * 0.22;
    s.addImage({ data: icons[key], x: x + pad, y: y + pad, w: d - 2 * pad, h: d - 2 * pad });
  };

  const footer = (s, n) => {
    s.addText([{ text: "VISIONARY", options: { color: AMBER, bold: true } }, { text: "  ·  Open Sauce 2026", options: { color: MUTED } }],
      { x: 0.6, y: H - 0.45, w: 5, h: 0.3, fontSize: 10, fontFace: "Calibri", margin: 0 });
    s.addText(String(n), { x: W - 1.1, y: H - 0.45, w: 0.5, h: 0.3, fontSize: 10, color: MUTED, align: "right", fontFace: "Calibri", margin: 0 });
  };

  // ---------- 1 · TITLE ----------
  let s = p.addSlide(); base(s);
  s.addShape("ellipse", { x: 9.2, y: -2.4, w: 7, h: 7, fill: { color: CARD } });
  circleIcon(s, 10.35, 0.75, 1.5, "FiEye" + BG);
  s.addText("VISIONARY", { x: 0.8, y: 1.7, w: 9, h: 1.2, fontSize: 60, bold: true, color: WHITE, fontFace: "Arial", charSpacing: 4, margin: 0 });
  s.addText("AI glasses that read the world aloud.", { x: 0.8, y: 2.95, w: 9.6, h: 0.7, fontSize: 26, color: AMBER, italic: true, fontFace: "Cambria", margin: 0 });
  s.addText("Built for visually impaired students. One button. No screen. No subscription.",
    { x: 0.8, y: 3.75, w: 9.4, h: 0.6, fontSize: 16, color: ICE, fontFace: "Calibri", margin: 0 });
  chip(s, 0.8, 4.9, 2.3, "$60 IN PARTS");
  chip(s, 3.3, 4.9, 2.6, "WORKS OFFLINE");
  chip(s, 6.1, 4.9, 2.6, "OPEN SOURCE");
  footer(s, 1);

  // ---------- 2 · PROBLEM ----------
  s = p.addSlide(); base(s);
  s.addText("Reading shouldn't cost $3,000", { x: 0.6, y: 0.55, w: 12, h: 0.8, fontSize: 38, bold: true, color: WHITE, fontFace: "Arial", margin: 0 });
  s.addText("A visually impaired student meets the same wall dozens of times a day: the worksheet being handed out, the page on the board, the paragraph everyone else reads silently. Human help costs independence. Phone apps need aimed screens and busy hands.",
    { x: 0.6, y: 1.6, w: 6.4, h: 2.6, fontSize: 17, color: ICE, fontFace: "Calibri", lineSpacing: 26, margin: 0 });
  s.addText("Assistive wearables exist — priced for clinics, not classrooms. Most schools own zero.",
    { x: 0.6, y: 4.2, w: 6.4, h: 1.4, fontSize: 17, color: ICE, fontFace: "Calibri", lineSpacing: 26, margin: 0 });
  // stat cards
  s.addShape("roundRect", { x: 7.6, y: 1.6, w: 5.1, h: 2.15, rectRadius: 0.12, fill: { color: CARD } });
  s.addText("$2,000–4,000", { x: 7.6, y: 1.85, w: 5.1, h: 0.95, fontSize: 40, bold: true, color: MUTED, align: "center", fontFace: "Arial", margin: 0 });
  s.addText("commercial AI reading glasses (per student)", { x: 7.6, y: 2.85, w: 5.1, h: 0.5, fontSize: 13, color: MUTED, align: "center", fontFace: "Calibri", margin: 0 });
  s.addShape("roundRect", { x: 7.6, y: 4.0, w: 5.1, h: 2.15, rectRadius: 0.12, fill: { color: AMBER } });
  s.addText("$60", { x: 7.6, y: 4.25, w: 5.1, h: 0.95, fontSize: 48, bold: true, color: BG, align: "center", fontFace: "Arial", margin: 0 });
  s.addText("Visionary bill of materials — every classroom can afford a set", { x: 7.6, y: 5.3, w: 5.1, h: 0.6, fontSize: 13, bold: true, color: BG, align: "center", fontFace: "Calibri", margin: 0 });
  footer(s, 2);

  // ---------- 3 · HOW IT WORKS ----------
  s = p.addSlide(); base(s);
  s.addText("How it works", { x: 0.6, y: 0.55, w: 12, h: 0.8, fontSize: 38, bold: true, color: WHITE, fontFace: "Arial", margin: 0 });
  const steps = [
    ["FiCamera" + WHITE, "1 · SEE", "Head-mounted camera captures what you're facing — one button press, never continuous."],
    ["FiCpu" + WHITE, "2 · THINK", "Raspberry Pi sends the image to a frontier vision model — reading-order text or a scene description."],
    ["FiSpeaker" + WHITE, "3 · SPEAK", "Neural text-to-speech through a temple speaker. First words in ~4 seconds."],
    ["FiWifi" + WHITE, "4 · NO WIFI? FINE.", "On-device OCR + on-device voice take over automatically. The glasses never go dumb."],
  ];
  steps.forEach(([ic, t, d], i) => {
    const x = 0.6 + i * 3.22;
    s.addShape("roundRect", { x, y: 1.9, w: 2.92, h: 4.0, rectRadius: 0.12, fill: { color: i === 3 ? "273052" : CARD } });
    s.addShape("ellipse", { x: x + 0.96, y: 2.25, w: 1.0, h: 1.0, fill: { color: i === 3 ? AMBER : "2A3048" } });
    s.addImage({ data: icons[ic], x: x + 1.18, y: 2.47, w: 0.56, h: 0.56 });
    s.addText(t, { x: x + 0.2, y: 3.45, w: 2.52, h: 0.5, fontSize: 16, bold: true, color: i === 3 ? AMBER : WHITE, align: "center", fontFace: "Arial", margin: 0 });
    s.addText(d, { x: x + 0.25, y: 4.0, w: 2.42, h: 1.7, fontSize: 12.5, color: ICE, align: "center", fontFace: "Calibri", lineSpacing: 17, margin: 0 });
  });
  s.addText("Privacy by design: press-to-capture only · nothing stored · open source, so you can check.",
    { x: 0.6, y: 6.25, w: 12.1, h: 0.5, fontSize: 14, italic: true, color: MUTED, align: "center", fontFace: "Cambria", margin: 0 });
  footer(s, 3);

  // ---------- 4 · TIER 1 ----------
  s = p.addSlide(); base(s);
  s.addText("Live today", { x: 0.6, y: 0.5, w: 8, h: 0.75, fontSize: 38, bold: true, color: WHITE, fontFace: "Arial", margin: 0 });
  s.addText("CORE READING · TIER 1", { x: 0.6, y: 1.25, w: 8, h: 0.4, fontSize: 14, bold: true, color: AMBER, charSpacing: 3, fontFace: "Calibri", margin: 0 });
  const t1 = [
    ["FiBookOpen" + BG, "Read anything", "Worksheets, textbooks, handwriting, menus, signs, pill bottles — spoken in natural reading order, cleaned for speech."],
    ["FiEye" + BG, "Describe the scene", "Double press: objects, people, layout, visible text — framed from your point of view."],
    ["FiGlobe" + BG, "Translate on sight", "Foreign text in view, heard in your language. Any language, both directions."],
    ["FiWifiOff" + BG, "Offline mode", "No internet → on-device OCR + voice, automatically. A student's reading never depends on school WiFi."],
    ["FiVolume2" + BG, "Never fails silently", "Spoken status for everything: ready, no text found, battery low."],
    ["FiPower" + BG, "All-day simple", "Boots to ready in 30s, 3–4h battery, charges over USB, safe-shutdown gesture."],
  ];
  t1.forEach(([ic, t, d], i) => {
    const x = 0.6 + (i % 3) * 4.22, y = 1.85 + Math.floor(i / 3) * 2.35;
    s.addShape("roundRect", { x, y, w: 3.92, h: 2.1, rectRadius: 0.1, fill: { color: CARD } });
    circleIcon(s, x + 0.25, y + 0.25, 0.62, ic);
    s.addText(t, { x: x + 1.05, y: y + 0.26, w: 2.75, h: 0.6, fontSize: 16.5, bold: true, color: WHITE, fontFace: "Arial", margin: 0 });
    s.addText(d, { x: x + 0.28, y: y + 0.95, w: 3.4, h: 1.05, fontSize: 11.5, color: ICE, fontFace: "Calibri", lineSpacing: 15, margin: 0 });
  });
  footer(s, 4);

  // ---------- 5 · TIER 2 ----------
  s = p.addSlide(); base(s);
  s.addText("Talk to what you see", { x: 0.6, y: 0.5, w: 10, h: 0.75, fontSize: 38, bold: true, color: WHITE, fontFace: "Arial", margin: 0 });
  s.addText("VOICE · TIER 2", { x: 0.6, y: 1.25, w: 8, h: 0.4, fontSize: 14, bold: true, color: AMBER, charSpacing: 3, fontFace: "Calibri", margin: 0 });
  const t2 = [
    ["FiMessageCircle" + BG, "Ask about what you see", "Hold the button and talk: “which of these is gluten-free?” “what's the homework on the board?” Photo + question → spoken answer."],
    ["FiMic" + BG, "Voice assistant", "General questions, hands-free, with short conversational memory."],
    ["FiFileText" + BG, "Lecture recorder", "Triple press: record → full transcript → AI summary, spoken back and saved."],
    ["FiRepeat" + BG, "Live interpreter", "Two-way conversation mode: their Spanish in your ear as English — your English out loud as Spanish."],
  ];
  t2.forEach(([ic, t, d], i) => {
    const y = 1.9 + i * 1.12;
    circleIcon(s, 0.7, y, 0.72, ic);
    s.addText(t, { x: 1.7, y: y - 0.02, w: 4.3, h: 0.75, fontSize: 18, bold: true, color: WHITE, fontFace: "Arial", margin: 0, valign: "middle" });
    s.addText(d, { x: 6.1, y: y - 0.08, w: 6.6, h: 0.95, fontSize: 13, color: ICE, fontFace: "Calibri", lineSpacing: 17, margin: 0, valign: "middle" });
    if (i < 3) s.addShape("line", { x: 1.7, y: y + 0.98, w: 11.0, h: 0, line: { color: "2A3048", width: 0.75 } });
  });
  s.addText("Powered by one $7 microphone sharing the audio bus — the whole voice stack adds four wires.",
    { x: 0.6, y: 6.5, w: 12.1, h: 0.45, fontSize: 13, italic: true, color: MUTED, fontFace: "Cambria", margin: 0 });
  footer(s, 5);

  // ---------- 6 · ONE BUTTON ----------
  s = p.addSlide(); base(s);
  s.addText("The entire interface is one button", { x: 0.6, y: 0.55, w: 12, h: 0.8, fontSize: 38, bold: true, color: WHITE, fontFace: "Arial", margin: 0 });
  s.addText("No screen. No menus. Muscle memory in a minute — designed to be used without sight.",
    { x: 0.6, y: 1.45, w: 11, h: 0.5, fontSize: 16, color: ICE, fontFace: "Calibri", margin: 0 });
  const g = [
    ["PRESS", "Read what's in front of you"],
    ["PRESS ×2", "Describe the scene"],
    ["HOLD + TALK", "Ask anything about it"],
    ["PRESS ×3", "Record & summarize"],
    ["HOLD 5s", "Power down, spoken goodbye"],
  ];
  g.forEach(([a, b], i) => {
    const y = 2.25 + i * 0.88;
    s.addShape("roundRect", { x: 0.9, y, w: 3.1, h: 0.66, rectRadius: 0.33, fill: { color: i === 2 ? AMBER : CARD }, line: { color: i === 2 ? AMBER : "2A3048", width: 1 } });
    s.addText(a, { x: 0.9, y, w: 3.1, h: 0.66, align: "center", fontSize: 16, bold: true, color: i === 2 ? BG : AMBER, fontFace: "Arial", margin: 0 });
    s.addText(b, { x: 4.4, y, w: 8.2, h: 0.66, fontSize: 17, color: WHITE, fontFace: "Calibri", valign: "middle", margin: 0 });
  });
  footer(s, 6);

  // ---------- 7 · ROADMAP ----------
  s = p.addSlide(); base(s);
  s.addText("Where it's going", { x: 0.6, y: 0.5, w: 10, h: 0.75, fontSize: 38, bold: true, color: WHITE, fontFace: "Arial", margin: 0 });
  s.addText("V2 ROADMAP · TIER 3", { x: 0.6, y: 1.25, w: 8, h: 0.4, fontSize: 14, bold: true, color: AMBER, charSpacing: 3, fontFace: "Calibri", margin: 0 });
  const t3 = [
    ["FiSearch" + BG, "Visual memory", "“What room number was on that door?” — every capture searchable."],
    ["FiZap" + BG, "Wake word", "“Hey Vision” — fully hands-free trigger."],
    ["FiNavigation" + BG, "Navigation assist", "Obstacle and sign callouts as you walk."],
    ["FiCalendar" + BG, "Agent actions", "“Add this flyer's date to my calendar.” Seen → done."],
    ["FiSmartphone" + BG, "Companion app", "History, remote trigger, live view, settings — parents & teachers."],
    ["FiUsers" + BG, "Classroom edition", "Class sets + teacher dashboard, grant-funded distribution."],
  ];
  t3.forEach(([ic, t, d], i) => {
    const x = 0.6 + (i % 3) * 4.22, y = 1.95 + Math.floor(i / 3) * 2.3;
    s.addShape("roundRect", { x, y, w: 3.92, h: 2.05, rectRadius: 0.1, fill: { color: CARD } });
    circleIcon(s, x + 0.25, y + 0.25, 0.6, ic, "3A4468");
    s.addText(t, { x: x + 1.0, y: y + 0.24, w: 2.8, h: 0.6, fontSize: 16, bold: true, color: WHITE, fontFace: "Arial", margin: 0 });
    s.addText(d, { x: x + 0.28, y: y + 0.92, w: 3.4, h: 1.0, fontSize: 11.5, color: ICE, fontFace: "Calibri", lineSpacing: 15, margin: 0 });
  });
  footer(s, 7);

  // ---------- 8 · COMPARISON ----------
  s = p.addSlide(); base(s);
  s.addText("Same magic, 30× cheaper", { x: 0.6, y: 0.5, w: 12, h: 0.8, fontSize: 38, bold: true, color: WHITE, fontFace: "Arial", margin: 0 });
  const rows = [
    ["", "VISIONARY", "OrCam MyEye", "Rabbit R1", "Phone apps"],
    ["Price", "$60 BOM · $99 kit", "$2,000–4,000", "$199", "“free” + $1k phone"],
    ["Hands-free, your POV", "Yes", "Yes", "No", "No"],
    ["Works offline", "Yes", "Partial", "No", "Some"],
    ["Open source", "Yes", "No", "No", "No"],
    ["Built for classrooms", "Yes", "Clinical market", "No", "No"],
  ];
  const colX = [0.6, 3.6, 6.2, 8.7, 11.0], colW = [3.0, 2.6, 2.5, 2.3, 1.73];
  rows.forEach((r, ri) => {
    const y = 1.65 + ri * 0.82;
    if (ri === 0) s.addShape("roundRect", { x: 3.5, y: y - 0.08, w: 2.7, h: 0.82 * rows.length + 0.05, rectRadius: 0.1, fill: { color: CARD }, line: { color: AMBER, width: 1.5 } });
    r.forEach((c, ci) => {
      s.addText(c, {
        x: colX[ci] + (ci > 0 ? 0.1 : 0), y, w: colW[ci], h: 0.7, margin: 0, valign: "middle",
        fontSize: ri === 0 ? 13.5 : 14, bold: ri === 0 || ci === 1,
        color: ri === 0 ? (ci === 1 ? AMBER : MUTED) : ci === 1 ? WHITE : ICE,
        align: ci === 0 ? "left" : "center", fontFace: ri === 0 ? "Arial" : "Calibri",
      });
    });
    if (ri > 0 && ri < rows.length - 1) s.addShape("line", { x: 0.6, y: y + 0.74, w: 12.1, h: 0, line: { color: "2A3048", width: 0.5 } });
  });
  s.addText("The honest trade: they have industrial design and certifications. We have a price every school can say yes to — and a platform anyone can improve.",
    { x: 0.6, y: 6.6, w: 12.1, h: 0.55, fontSize: 13, italic: true, color: MUTED, fontFace: "Cambria", margin: 0 });
  footer(s, 8);

  // ---------- 9 · ASK ----------
  s = p.addSlide(); base(s);
  s.addShape("ellipse", { x: -2.5, y: 4.8, w: 7, h: 7, fill: { color: CARD } });
  s.addText("Try it. Press the button.", { x: 0.8, y: 1.5, w: 11.7, h: 1.0, fontSize: 48, bold: true, color: WHITE, fontFace: "Arial", margin: 0 });
  s.addText("Then take one home.", { x: 0.8, y: 2.6, w: 11.7, h: 0.7, fontSize: 28, color: AMBER, italic: true, fontFace: "Cambria", margin: 0 });
  const offers = [
    ["$79", "KIT — you solder", "all parts + printed frame + preloaded SD + full docs"],
    ["$99", "FOUNDER KIT", "same, with premium frame print & starter cloud credit"],
    ["$149", "ASSEMBLED", "built, tested, focused — ready out of the box"],
  ];
  offers.forEach(([pr, t, d], i) => {
    const x = 0.8 + i * 4.1;
    s.addShape("roundRect", { x, y: 3.7, w: 3.8, h: 2.2, rectRadius: 0.12, fill: { color: i === 1 ? AMBER : CARD } });
    s.addText(pr, { x: x + 0.25, y: 3.9, w: 3.3, h: 0.75, fontSize: 34, bold: true, color: i === 1 ? BG : AMBER, fontFace: "Arial", margin: 0 });
    s.addText(t, { x: x + 0.25, y: 4.62, w: 3.3, h: 0.4, fontSize: 14, bold: true, color: i === 1 ? BG : WHITE, fontFace: "Arial", charSpacing: 1, margin: 0 });
    s.addText(d, { x: x + 0.25, y: 5.05, w: 3.3, h: 0.7, fontSize: 11.5, color: i === 1 ? "3A3320" : ICE, fontFace: "Calibri", lineSpacing: 15, margin: 0 });
  });
  s.addText("30 founder units · ships within 6 weeks · scan the QR at the booth to reserve",
    { x: 0.8, y: 6.3, w: 11.7, h: 0.5, fontSize: 16, bold: true, color: ICE, fontFace: "Calibri", margin: 0 });
  footer(s, 9);

  await p.writeFile({ fileName: "/sessions/jolly-beautiful-franklin/mnt/outputs/visionary/Visionary_Features.pptx" });
  console.log("WROTE DECK");
})();
