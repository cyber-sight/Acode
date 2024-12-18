import * as lsp from "vscode-languageserver-protocol";
import { CommonConverter } from "../../type-converters/common-converters";
var convertKind = CommonConverter.convertKind;
import { filterDiagnostics } from "../../type-converters/lsp-converters";
export function fromTsDiagnostics(diagnostics, doc, filterErrors) {
	const lspDiagnostics = diagnostics
		.filter(
			(el) => !filterErrors.errorCodesToIgnore.includes(el.code.toString()),
		)
		.map((el) => {
			var _a, _b;
			let start = (_a = el.start) !== null && _a !== void 0 ? _a : 0;
			let length = (_b = el.length) !== null && _b !== void 0 ? _b : 1; //TODO:
			if (
				filterErrors.errorCodesToTreatAsWarning.includes(el.code.toString())
			) {
				el.category = DiagnosticCategory.Warning;
			} else if (
				filterErrors.errorCodesToTreatAsInfo.includes(el.code.toString())
			) {
				el.category = DiagnosticCategory.Message;
			}
			return lsp.Diagnostic.create(
				lsp.Range.create(doc.positionAt(start), doc.positionAt(start + length)),
				parseMessageText(el.messageText, el.code),
				fromTsCategory(el.category),
				el.code,
			);
		});
	return filterDiagnostics(lspDiagnostics, filterErrors);
}
export function toTsOffset(range, doc) {
	return {
		start: doc.offsetAt(range.start) + 1,
		end: doc.offsetAt(range.end) + 1,
	};
}
export function toTextSpan(range, doc) {
	const start = doc.offsetAt(range.start);
	const end = doc.offsetAt(range.end);
	return {
		start: start,
		length: end - start,
	};
}
export function parseMessageText(diagnosticsText, errorCode) {
	if (typeof diagnosticsText === "string") {
		return diagnosticsText + " (" + errorCode.toString() + ")\n";
	} else if (diagnosticsText === undefined) {
		return "";
	}
	let result = "";
	result +=
		diagnosticsText.messageText +
		" (" +
		diagnosticsText.code.toString() +
		")\n";
	if (diagnosticsText.next) {
		for (let next of diagnosticsText.next) {
			result += parseMessageText(next, next.code);
		}
	}
	return result;
}
export function fromTsCategory(category) {
	switch (category) {
		case DiagnosticCategory.Error:
			return 1;
		case DiagnosticCategory.Suggestion:
		case DiagnosticCategory.Message:
		case DiagnosticCategory.Warning:
			return 2;
	}
	return 3;
}
export function toTextEdits(textEdits, doc) {
	return textEdits.map((el) => {
		return {
			range: toRange(el.span, doc),
			newText: el.newText,
		};
	});
}
export function toRange(textSpan, doc) {
	if (!textSpan) {
		return;
	}
	let start = toPosition(textSpan.start, doc);
	let end = toPosition(textSpan.start + textSpan.length, doc);
	return createRangeFromPoints(start, end);
}
export function createRangeFromPoints(start, end) {
	return {
		start: start,
		end: end,
	};
}
export function toPosition(index, doc) {
	return doc.positionAt(index);
}
export function toHover(hover, doc) {
	if (!hover) {
		return null;
	}
	let documentation = hover.documentation
		? hover.documentation.map((displayPart) => displayPart.text).join("")
		: "";
	let tags = hover.tags
		? hover.tags.map((tag) => tagToString(tag)).join("  \n")
		: "";
	let displayParts = hover.displayParts
		? hover.displayParts.map((displayPart) => displayPart.text).join("")
		: "";
	let contents = [
		"```typescript\n" + displayParts + "\n```\n",
		(documentation + (tags ? "\n" + tags : ""))
			.replace(/</g, "&lt;")
			.replace(/>/g, "&gt;"),
	];
	return {
		contents: { kind: "markdown", value: contents.join("\n") },
		range: toRange(hover.textSpan, doc),
	};
}
function tagToString(tag) {
	let tagLabel = `*@${tag.name}*`;
	if (tag.name === "param" && tag.text) {
		const [paramName, ...rest] = tag.text;
		tagLabel += `\`${paramName.text}\``;
		if (rest.length > 0) tagLabel += ` — ${rest.map((r) => r.text).join(" ")}`;
	} else if (Array.isArray(tag.text)) {
		tagLabel += ` — ${tag.text.map((r) => r.text).join(" ")}`;
	} else if (tag.text) {
		tagLabel += ` — ${tag.text}`;
	}
	return tagLabel;
}
export function toCompletions(completionInfo, doc, position) {
	return completionInfo.entries.map((entry) => {
		let completion = {
			label: entry.name,
			insertText: entry.name,
			sortText: entry.sortText,
			kind: convertKind(entry.kind),
			position: position,
			entry: entry.name,
		};
		if (entry.replacementSpan) {
			const p1 = toPosition(entry.replacementSpan.start, doc);
			const p2 = toPosition(
				entry.replacementSpan.start + entry.replacementSpan.length,
				doc,
			);
			completion["range"] = createRangeFromPoints(p1, p2);
		}
		return completion;
	});
}
export function toResolvedCompletion(entry) {
	return {
		label: entry.name,
		kind: convertKind(entry.kind),
		documentation: entry.displayParts
			.map((displayPart) => displayPart.text)
			.join(""),
	};
}
export function toSignatureHelp(signatureItems) {
	if (!signatureItems) {
		return null;
	}
	let signatureHelp = {
		signatures: [],
		activeSignature: signatureItems.selectedItemIndex,
		activeParameter: signatureItems.argumentIndex,
	};
	signatureItems.items.forEach((item) => {
		let signature = {
			label: "",
			parameters: [],
			documentation: displayPartsToString(item.documentation),
		};
		signature.label += displayPartsToString(item.prefixDisplayParts);
		item.parameters.forEach((p, i, a) => {
			const label = displayPartsToString(p.displayParts);
			const parameter = {
				label: label,
				documentation: {
					value: displayPartsToString(p.documentation),
				},
			};
			signature.label += label;
			// @ts-ignore
			signature.parameters.push(parameter);
			if (i < a.length - 1) {
				signature.label += displayPartsToString(item.separatorDisplayParts);
			}
		});
		signature.label += displayPartsToString(item.suffixDisplayParts);
		signatureHelp.signatures.push(signature);
	});
	return signatureHelp;
}
function displayPartsToString(displayParts) {
	if (displayParts) {
		return displayParts.map((displayPart) => displayPart.text).join("");
	}
	return "";
}
export function toDocumentHighlights(highlights, doc) {
	if (!highlights) return [];
	return highlights.flatMap((highlight) =>
		highlight.highlightSpans.map((highlightSpans) => {
			return {
				range: toRange(highlightSpans.textSpan, doc),
				kind:
					highlightSpans.kind === "writtenReference"
						? lsp.DocumentHighlightKind.Write
						: lsp.DocumentHighlightKind.Text,
			};
		}),
	);
}
export function getTokenTypeFromClassification(tsClassification) {
	if (tsClassification > TokenEncodingConsts.modifierMask) {
		return (tsClassification >> TokenEncodingConsts.typeOffset) - 1;
	}
	return undefined;
}
export function getTokenModifierFromClassification(tsClassification) {
	return tsClassification & TokenEncodingConsts.modifierMask;
}
export function diagnosticsToErrorCodes(diagnostics) {
	return diagnostics
		.map((el) => {
			return Number(el.code);
		})
		.filter((code) => !isNaN(code));
}
export function toCodeActions(codeFixes, doc) {
	return codeFixes
		.filter((fix) => {
			// Removes any 'make a new file'-type code fix
			return fix.changes.filter((change) => change.isNewFile).length === 0;
		})
		.map((fix) => {
			const edit = {
				changes: {},
			};
			edit.changes[doc.uri] = [];
			for (const change of fix.changes) {
				if (change.fileName == doc.uri) {
				}
				for (const textChange of change.textChanges) {
					edit.changes[doc.uri].push({
						range: toRange(textChange.span, doc),
						newText: textChange.newText,
					});
				}
			}
			return {
				title: fix.description,
				edit,
				kind: "quickfix",
			};
		});
}
export var SemanticClassificationFormat;
(function (SemanticClassificationFormat) {
	SemanticClassificationFormat["Original"] = "original";
	SemanticClassificationFormat["TwentyTwenty"] = "2020";
})(SemanticClassificationFormat || (SemanticClassificationFormat = {}));
var TokenEncodingConsts;
(function (TokenEncodingConsts) {
	TokenEncodingConsts[(TokenEncodingConsts["typeOffset"] = 8)] = "typeOffset";
	TokenEncodingConsts[(TokenEncodingConsts["modifierMask"] = 255)] =
		"modifierMask";
})(TokenEncodingConsts || (TokenEncodingConsts = {}));
export var ScriptKind;
(function (ScriptKind) {
	ScriptKind[(ScriptKind["Unknown"] = 0)] = "Unknown";
	ScriptKind[(ScriptKind["JS"] = 1)] = "JS";
	ScriptKind[(ScriptKind["JSX"] = 2)] = "JSX";
	ScriptKind[(ScriptKind["TS"] = 3)] = "TS";
	ScriptKind[(ScriptKind["TSX"] = 4)] = "TSX";
	ScriptKind[(ScriptKind["External"] = 5)] = "External";
	ScriptKind[(ScriptKind["JSON"] = 6)] = "JSON";
	/**
	 * Used on extensions that doesn't define the ScriptKind but the content defines it.
	 * Deferred extensions are going to be included in all project contexts.
	 */
	ScriptKind[(ScriptKind["Deferred"] = 7)] = "Deferred";
})(ScriptKind || (ScriptKind = {}));
export var ScriptTarget;
(function (ScriptTarget) {
	ScriptTarget[(ScriptTarget["ES3"] = 0)] = "ES3";
	ScriptTarget[(ScriptTarget["ES5"] = 1)] = "ES5";
	ScriptTarget[(ScriptTarget["ES2015"] = 2)] = "ES2015";
	ScriptTarget[(ScriptTarget["ES2016"] = 3)] = "ES2016";
	ScriptTarget[(ScriptTarget["ES2017"] = 4)] = "ES2017";
	ScriptTarget[(ScriptTarget["ES2018"] = 5)] = "ES2018";
	ScriptTarget[(ScriptTarget["ES2019"] = 6)] = "ES2019";
	ScriptTarget[(ScriptTarget["ES2020"] = 7)] = "ES2020";
	ScriptTarget[(ScriptTarget["ES2021"] = 8)] = "ES2021";
	ScriptTarget[(ScriptTarget["ES2022"] = 9)] = "ES2022";
	ScriptTarget[(ScriptTarget["ESNext"] = 99)] = "ESNext";
	ScriptTarget[(ScriptTarget["JSON"] = 100)] = "JSON";
	ScriptTarget[(ScriptTarget["Latest"] = 99)] = "Latest";
})(ScriptTarget || (ScriptTarget = {}));
export var DiagnosticCategory;
(function (DiagnosticCategory) {
	DiagnosticCategory[(DiagnosticCategory["Warning"] = 0)] = "Warning";
	DiagnosticCategory[(DiagnosticCategory["Error"] = 1)] = "Error";
	DiagnosticCategory[(DiagnosticCategory["Suggestion"] = 2)] = "Suggestion";
	DiagnosticCategory[(DiagnosticCategory["Message"] = 3)] = "Message";
})(DiagnosticCategory || (DiagnosticCategory = {}));
export var JsxEmit;
(function (JsxEmit) {
	JsxEmit[(JsxEmit["None"] = 0)] = "None";
	JsxEmit[(JsxEmit["Preserve"] = 1)] = "Preserve";
	JsxEmit[(JsxEmit["React"] = 2)] = "React";
	JsxEmit[(JsxEmit["ReactNative"] = 3)] = "ReactNative";
	JsxEmit[(JsxEmit["ReactJSX"] = 4)] = "ReactJSX";
	JsxEmit[(JsxEmit["ReactJSXDev"] = 5)] = "ReactJSXDev";
})(JsxEmit || (JsxEmit = {}));
//# sourceMappingURL=typescript-converters.js.map
