const LONG_PRESS_TIMEOUT = 550;
const MOVE_THRESHOLD = 10;
const NATIVE_CALLOUT_SELECTOR = [
	".cm-editor",
	".ace_editor",
	".editor-container",
	".xterm",
	".terminal-container",
	".terminal",
].join(",");

function shouldIgnore(target) {
	if (!(target instanceof Element)) return true;
	return !!target.closest(
		[
			"#quick-tools",
			"input",
			"textarea",
			"select",
			"[contenteditable='true']",
		].join(","),
	);
}

function shouldSuppressNativeCallout(target) {
	return target instanceof Element && !!target.closest(NATIVE_CALLOUT_SELECTOR);
}

export default function initIosContextMenu() {
	if (typeof cordova === "undefined" || cordova.platformId !== "ios") return;

	let timer = null;
	let target = null;
	let startX = 0;
	let startY = 0;

	const clear = () => {
		clearTimeout(timer);
		timer = null;
		target = null;
	};

	document.addEventListener(
		"touchstart",
		(event) => {
			if (event.touches.length !== 1 || shouldIgnore(event.target)) return;

			const touch = event.touches[0];
			target = event.target;
			startX = touch.clientX;
			startY = touch.clientY;

			clearTimeout(timer);
			timer = setTimeout(() => {
				if (!target) return;

				const contextEvent = new MouseEvent("contextmenu", {
					bubbles: true,
					cancelable: true,
					clientX: startX,
					clientY: startY,
					button: 2,
					buttons: 0,
					view: window,
				});
				target.dispatchEvent(contextEvent);
				if (contextEvent.defaultPrevented && event.cancelable) {
					event.preventDefault();
				}
				clear();
			}, LONG_PRESS_TIMEOUT);
		},
		{ capture: true, passive: false },
	);

	document.addEventListener(
		"touchmove",
		(event) => {
			if (!timer || event.touches.length !== 1) return;

			const touch = event.touches[0];
			if (
				Math.abs(touch.clientX - startX) > MOVE_THRESHOLD ||
				Math.abs(touch.clientY - startY) > MOVE_THRESHOLD
			) {
				clear();
			}
		},
		{ capture: true, passive: true },
	);

	document.addEventListener("touchend", clear, { capture: true });
	document.addEventListener("touchcancel", clear, { capture: true });

	document.addEventListener(
		"contextmenu",
		(event) => {
			if (!shouldSuppressNativeCallout(event.target)) return;
			if (event.target?.closest?.(".context-menu, .terminal-context-menu")) return;
			event.preventDefault();
		},
		{ capture: true },
	);
}
