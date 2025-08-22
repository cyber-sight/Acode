import {
	Decoration,
	EditorView,
	ViewPlugin,
	WidgetType,
} from "@codemirror/view";
import pickColor from "dialogs/color";
import color from "utils/color";
import { colorRegex, HEX } from "utils/color/regex";

// WeakMap to carry state from widget DOM back into handler
const colorState = new WeakMap();

const HEX_RE = new RegExp(HEX, "gi");

const RGBG = new RegExp(colorRegex.anyGlobal);

const enumColorType = { hex: "hex", rgb: "rgb", hsl: "hsl", named: "named" };

class ColorWidget extends WidgetType {
	constructor({ color, colorRaw, ...state }) {
		super();
		this.state = state; // from, to, colorType, alpha
		this.color = color; // hex for input value
		this.colorRaw = colorRaw; // original css color string
	}
	eq(other) {
		return (
			other.state.colorType === this.state.colorType &&
			other.color === this.color &&
			other.state.from === this.state.from &&
			other.state.to === this.state.to &&
			(other.state.alpha || "") === (this.state.alpha || "")
		);
	}
	toDOM() {
		const wrapper = document.createElement("span");
		wrapper.className = "cm-color-chip";
		wrapper.style.display = "inline-block";
		wrapper.style.width = "0.9em";
		wrapper.style.height = "0.9em";
		wrapper.style.borderRadius = "2px";
		wrapper.style.verticalAlign = "middle";
		wrapper.style.margin = "0 2px";
		wrapper.style.boxSizing = "border-box";
		wrapper.style.border = "1px solid rgba(0,0,0,0.2)";
		wrapper.style.backgroundColor = this.colorRaw;
		wrapper.dataset["color"] = this.color;
		wrapper.dataset["colorraw"] = this.colorRaw;
		wrapper.style.cursor = "pointer";
		colorState.set(wrapper, this.state);
		return wrapper;
	}
	ignoreEvent() {
		return false;
	}
}

function colorDecorations(view) {
	const deco = [];
	const ranges = view.visibleRanges;
	for (const { from, to } of ranges) {
		const text = view.state.doc.sliceString(from, to);
		// Any color using global matcher from utils (captures named/rgb/rgba/hsl/hsla/hex)
		RGBG.lastIndex = 0;
		for (let m; (m = RGBG.exec(text)); ) {
			const raw = m[2];
			const start = from + m.index + m[1].length;
			const end = start + raw.length;
			const c = color(raw);
			const colorHex = c.hex.toString(false);
			deco.push(
				Decoration.widget({
					widget: new ColorWidget({
						from: start,
						to: end,
						color: colorHex,
						colorRaw: raw,
						colorType: enumColorType.named,
					}),
					side: -1,
				}).range(start),
			);
		}
	}

	return Decoration.set(deco, { sort: true });
}

export const colorView = (showPicker = true) =>
	ViewPlugin.fromClass(
		class ColorViewPlugin {
			constructor(view) {
				this.decorations = colorDecorations(view);
			}
			update(update) {
				if (update.docChanged || update.viewportChanged) {
					this.decorations = colorDecorations(update.view);
				}
				const readOnly = update.view.contentDOM.ariaReadOnly === "true";
				const editable = update.view.contentDOM.contentEditable === "true";
				const canBeEdited = readOnly === false && editable;
				this.changePicker(update.view, canBeEdited);
			}
			changePicker(view, canBeEdited) {
				const doms = view.contentDOM.querySelectorAll("input[type=color]");
				doms.forEach((inp) => {
					if (!showPicker) {
						inp.setAttribute("disabled", "");
					} else {
						canBeEdited
							? inp.removeAttribute("disabled")
							: inp.setAttribute("disabled", "");
					}
				});
			}
		},
		{
			decorations: (v) => v.decorations,
			eventHandlers: {
				click: async (e, view) => {
					const target = e.target;
					const chip = target?.closest?.(".cm-color-chip");
					if (!chip) return false;
					// Respect read-only and setting toggle
					const readOnly = view.contentDOM.ariaReadOnly === "true";
					const editable = view.contentDOM.contentEditable === "true";
					const canBeEdited = !readOnly && editable;
					if (!canBeEdited) return true;
					const data = colorState.get(chip);
					if (!data) return false;
					try {
						const picked = await pickColor(
							chip.dataset.colorraw || chip.dataset.color,
						);
						if (!picked) return true;
						view.dispatch({
							changes: { from: data.from, to: data.to, insert: picked },
						});
					} catch {
						/* ignore */
					}
					return true;
				},
			},
		},
	);

export default colorView;
