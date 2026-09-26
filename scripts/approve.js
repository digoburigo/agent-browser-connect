// Press "Allow" on Chrome's "Allow remote debugging?" sheet, through the macOS
// Accessibility API (osascript -l JavaScript). Opt-in via connect.sh
// --auto-approve, and started by connect.sh ONLY around its own attach.
//
//   osascript -l JavaScript approve.js count   <app> <title> <button>
//   osascript -l JavaScript approve.js approve <app> <title> <button> <seconds>
//
// `count` prints how many matching sheets are open right now; connect.sh refuses
// to auto-approve when one was already open before its attach started, because
// that dialog belongs to some other client. `approve` waits for a sheet, presses
// its button ONCE, prints "approved" and exits; it prints "timeout" otherwise.
//
// The sheet carries nothing that identifies the connecting client (recorded
// 2026-09-25, Chrome on macOS: AXSheet "Allow remote debugging?" > buttons
// "Turn off in settings", "Cancel", "Allow"), so the time window is the only
// scoping there is. Never run this outside an attach.

function attr(element, name) {
  try {
    const value = element.attributes.byName(name).value();
    return value === null || value === undefined ? "" : String(value);
  } catch {
    return "";
  }
}

function findButton(element, label, depth) {
  if (depth > 8) {
    return null;
  }
  if (
    attr(element, "AXRole") === "AXButton" &&
    attr(element, "AXTitle") === label
  ) {
    return element;
  }
  let children = [];
  try {
    children = element.uiElements();
  } catch {
    return null;
  }
  for (const child of children) {
    const found = findButton(child, label, depth + 1);
    if (found) {
      return found;
    }
  }
  return null;
}

function matchingSheets(process, title) {
  const sheets = [];
  let windows = [];
  try {
    windows = process.windows();
  } catch {
    return sheets;
  }
  for (const window of windows) {
    let windowSheets = [];
    try {
      windowSheets = window.sheets();
    } catch {
      continue;
    }
    for (const sheet of windowSheets) {
      if (attr(sheet, "AXTitle") === title) {
        sheets.push(sheet);
      }
    }
  }
  return sheets;
}

function run(argv) {
  const [mode, app, title, label, seconds] = argv;
  if (!mode || !app || !title || !label) {
    return "usage: approve.js count|approve <app> <title> <button> [seconds]";
  }
  const systemEvents = Application("System Events");
  // Fails with -1719 / -25211 when this terminal lacks the Accessibility
  // permission; osascript exits non-zero and connect.sh falls back to manual.
  const process = systemEvents.processes.byName(app);
  process.windows();

  if (mode === "count") {
    return String(matchingSheets(process, title).length);
  }
  if (mode !== "approve") {
    return `unknown mode: ${mode}`;
  }

  const deadline = Date.now() + Math.max(1, Number(seconds) || 60) * 1000;
  while (Date.now() < deadline) {
    for (const sheet of matchingSheets(process, title)) {
      const button = findButton(sheet, label, 0);
      if (button) {
        // AXPress acts on the element without focusing Chrome or moving the
        // pointer. One press, then exit: never a second dialog.
        button.actions.byName("AXPress").perform();
        return "approved";
      }
    }
    delay(0.25);
  }
  return "timeout";
}
